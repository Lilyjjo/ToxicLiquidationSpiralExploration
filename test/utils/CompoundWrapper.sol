// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";

import "../../src/CTokenInterfaces.sol";
import "../../src/ComptrollerInterface.sol";

import "../../src/Comptroller.sol";
import "../../src/CToken.sol";
import "../../src/CErc20Immutable.sol";
import "../../src/JumpRateModelV2.sol";
import "../../src/SimplePriceOracle.sol";
import "../../src/MockTokens/MockERC20.sol";
import "../../src/ErrorReporter.sol";

/**
 * @title Instrumented Compound v2 for Exploring Toxic Liquidation Spirals
 * @author Lilyjjo
 * @notice This testing contract is setup to allow users to simulate different trading and price scenarios on Compound v2.
 * The function `findToxicLTVExternalLosses()` allows users to run toxic liquidation spirals with different setup
 * configurations and to compare the relative impacts of the configuration changes.
 * The file has three main sections:
 * - Functions to make interacting with the Compound setup easier
 * - Insight functions to print out the current state of the Compound setup
 * - Testing scenarios to show the behavior of Compound during different scenarios
 */
contract CompoundWrapper is Test {
    SimplePriceOracle public oracle;
    Comptroller public comptroller;
    CErc20Immutable public cBorrowedToken;
    CErc20Immutable public cUSDC;
    BaseJumpRateModelV2 public interestModel;

    // BaseJumpRateModelV2 Params, taken from: https://etherscan.io/address/0xD8EC56013EA119E7181d231E5048f90fBbe753c0
    uint baseRatePerYear = 0;
    uint multiplierPerYear = 40000000000000000;
    uint jumpMultiplierPerYear = 1090000000000000000;
    uint kink = 800000000000000000;

    // Comptroller Params, taken from: // https://etherscan.io/address/0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B and https://etherscan.io/address/0x39AA39c021dfbaE8faC545936693aC917d5E7563
    uint initialExchangeRateMantissa = 200000000000000;
    uint8 cTokenDecimals = 8;

    // Using 18 for all Mock ERC20s for simplicity
    uint ERC20Decimals = 18;

    // admin address of protocol
    address admin;

    uint256 uscdCollateralFactor; // lending token (TODO: rename?)
    uint256 borrowTokenCollateralFactor;
    uint256 liquidationIncentive;
    uint256 closeFactor;

    mapping(address => string) names;

    MockERC20 usdc;
    MockERC20 borrowToken;

    /*****************************************
     *  Functions to interact with Compound: *
     *****************************************/

    /**
     * @notice Sets needed comptroller variables
     * @dev Prices for tokens in Oracle need to be set beforehand
     */
    function setUpComptroller() public {
        assert(oracle.getUnderlyingPrice(cUSDC) != 0);
        assert(oracle.getUnderlyingPrice(cBorrowedToken) != 0);

        vm.startPrank(admin);
        uint success;
        success = comptroller._setCloseFactor(closeFactor);
        assert(success == 0);
        success = comptroller._setCollateralFactor(cUSDC, uscdCollateralFactor);
        assert(success == 0);
        success = comptroller._setCollateralFactor(
            cBorrowedToken,
            borrowTokenCollateralFactor
        );
        assert(success == 0);
        success = comptroller._setLiquidationIncentive(liquidationIncentive);
        assert(success == 0);
        vm.stopPrank();
    }

    /**
     * @notice Adds user to both borrow and collateral token markets
     * @param user The address of user
     */
    function addToMarkets(address user) public {
        vm.prank(user);
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(cUSDC);
        cTokens[1] = address(cBorrowedToken);
        uint[] memory success = comptroller.enterMarkets(cTokens);
        assert(success[0] == 0);
        assert(success[1] == 0);
    }

    /**
     * @notice Mints ERC20 for user
     * @param user The address of user
     * @param coin The target ERC20
     * @param amount The amount to mint
     */
    function giveUserFunds(
        address user,
        MockERC20 coin,
        uint256 amount
    ) public {
        vm.prank(admin);
        coin.mint(user, amount);
    }

    /**
     * @notice Mints ERC20 and supplies it as collateral in associated CToken contract for user
     * @param user The user to mint and supply for\
     * @param coin The underlying ERC20
     * @param cToken The associated CToken for the ERC20
     * @param amount The amound of token to mint/supply
     */
    function mintFundsAndCollateral(
        address user,
        MockERC20 coin,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        giveUserFunds(user, coin, amount);
        vm.prank(user);
        coin.approve(address(cToken), amount);
        vm.prank(user);
        uint success = cToken.mint(amount);
        assert(success == 0);
    }

    /**
     * @notice Borrows cToken from the Compound setup for user
     * @param user The user who is borrowing
     * @param coin Unused
     * @param cToken The target token to borrow
     * @param amount How much token to borrow
     */
    function borrow(
        address user,
        MockERC20 coin,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.prank(user);
        uint success = cToken.borrow(amount);
        assert(success == 0);
    }

    /**
     * @notice Swaps value of one ERC20 for the same value of another ERC20
     * @dev Make sure you set the asset prices in the oracles
     * @param user The user holding the tokens
     * @param inToken The token to be swapped in
     * @param outToken The token to be swapped out
     * @param amountIn How many inTokens to be swapped
     */
    function swapAssets(
        address user,
        MockERC20 inToken,
        MockERC20 outToken,
        uint256 amountIn
    ) public {
        require(
            inToken.balanceOf(user) >= amountIn,
            "not enough balance to swap"
        );
        uint256 amountOut = (amountIn * oracle.assetPrices(address(inToken))) /
            oracle.assetPrices(address(outToken));
        vm.startPrank(admin);
        inToken.burn(user, amountIn);
        outToken.mint(user, amountOut);
        vm.stopPrank();
    }

    /**
     * @notice Repays a user's borrow
     * @param user The user who is repaying
     * @param coin The ERC20 token being repaid
     * @param cToken The associated cToken to the ERC20
     * @param amount How much of borrow to repay
     */
    function repayBorrow(
        address user,
        MockERC20 coin,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.startPrank(user);
        coin.approve(address(cToken), amount);
        uint success = cToken.repayBorrow(amount);
        assert(success == 0);
        vm.stopPrank();
    }

    /**
     * @notice Removes a user's collateral from Compound Pool
     * @param user The user's account
     * @param cToken The cToken pool of the asset to reclaim
     * @param amount How much of asset to remove
     */
    function removeCollateral(
        address user,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.prank(user);
        uint success = cToken.redeemUnderlying(amount);
        assert(success == 0);
    }

    /**
     * @notice Has liquidator liquidate target (pays borrow token to receive cToken of collateral)
     * @param liquidator Account performing liquidation, needs to hold borrowToken
     * @param target Account being liquidated, needs to be liquidatable
     * @param cTokenCollateral The cToken that the liquidator will receive for performing the liquidation
     * @param cTokenBorrow The cToken that the target has borrowed
     * @param borrowCoin The ERC20 of the cTokenBorrow
     * @param repayAmount How much of borrowCoin to use in liquidation
     */
    function liquidate(
        address liquidator,
        address target,
        CErc20Immutable cTokenCollateral,
        CErc20Immutable cTokenBorrow,
        MockERC20 borrowCoin,
        uint256 repayAmount
    ) public {
        // paying borrowToken to get collateralToken
        vm.startPrank(liquidator);
        borrowCoin.approve(address(cTokenBorrow), repayAmount);
        uint success = cTokenBorrow.liquidateBorrow(
            target,
            repayAmount,
            cTokenCollateral
        );
        assert(success == 0);
        vm.stopPrank();
    }

    /**
     *  @notice Returns the loan-to-value ratio for user.
     *  @param user address of user to get LTV for
     *  @return LTV scaled to 100_00 == 100%
     */
    function getLTV(address user) public returns (uint256 LTV) {
        uint256 cUSDCBalance = cUSDC.balanceOfUnderlying(user);
        uint256 cUSDCBorrowedBalance = cUSDC.borrowBalanceCurrent(user);

        uint256 cBorrowedTokenBalance = cBorrowedToken.balanceOfUnderlying(
            user
        );
        uint256 cBorrowedTokenBorrowedBalance = cBorrowedToken
            .borrowBalanceCurrent(user);

        uint256 denominator = (cUSDCBalance *
            oracle.getUnderlyingPrice(cUSDC) *
            uscdCollateralFactor) / 1 ether;
        denominator +=
            (cBorrowedTokenBalance *
                oracle.getUnderlyingPrice(cBorrowedToken) *
                borrowTokenCollateralFactor) /
            1 ether;
        uint256 numerator = cBorrowedTokenBorrowedBalance *
            oracle.getUnderlyingPrice(cBorrowedToken);
        numerator += cUSDCBorrowedBalance * oracle.getUnderlyingPrice(cUSDC);
        if (denominator != 0) {
            LTV = (numerator * 10000) / denominator;
        } else {
            LTV = 0;
        }
    }

    /****************************************
     *          Insight Functions:          *
     ****************************************/

    function printPoolBalances() public view {
        console.log("Pool balances: ");
        console.log("  USCD reserves  : ", cUSDC.getCash());
        console.log("  CRV reserves : ", cBorrowedToken.getCash());
        console.log("  USCD borrows   : ", cUSDC.totalBorrows());
        console.log("  CRV borrows    : ", cBorrowedToken.totalBorrows());
    }

    function printBalances(address user, string memory name) public {
        console.log("%s account snapshot:", name);
        (uint err, uint liquidity, uint shortfall) = comptroller
            .getAccountLiquidity(user);

        uint256 usdcBalance = usdc.balanceOf(user);
        uint256 cUSDCBalance = cUSDC.balanceOfUnderlying(user);
        uint256 cBorrowedTokenBalance = cBorrowedToken.balanceOfUnderlying(
            user
        );
        uint256 borrowTokenBalance = borrowToken.balanceOf(user);
        uint256 cBorrowedTokenBorrowedBalance = cBorrowedToken
            .borrowBalanceCurrent(user);

        uint256 denominator = (cBorrowedTokenBorrowedBalance *
            oracle.getUnderlyingPrice(cUSDC) *
            uscdCollateralFactor) / 1 ether;
        uint256 numerator = cBorrowedTokenBalance *
            oracle.getUnderlyingPrice(cBorrowedToken);
        uint256 LTV;
        if (denominator != 0) {
            LTV = (numerator * 10000) / denominator;
        } else {
            LTV = 0;
        }

        console.log("  USDC : ", usdcBalance);
        console.log("  CRV  : ", borrowTokenBalance);
        console.log("  cUSDC: ", cUSDCBalance);
        console.log("  cBorrowedToken : ", cBorrowedTokenBalance);
        console.log("  borrowed CRV     : ", cBorrowedTokenBorrowedBalance);
        console.log("  borrow value     : ", numerator / 1 ether);
        console.log("  collateral value : ", denominator / 1 ether);
        console.log("  liquidity: ", liquidity);
        console.log("  shortfall: ", shortfall);
        console.log("  LTV              : ", LTV);
    }
}
