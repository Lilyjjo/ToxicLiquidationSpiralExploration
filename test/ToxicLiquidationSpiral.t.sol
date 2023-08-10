// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "../src/CTokenInterfaces.sol";
import "../src/ComptrollerInterface.sol";

import "../src/Comptroller.sol";
import "../src/CToken.sol";
import "../src/CErc20Immutable.sol";
import "../src/JumpRateModelV2.sol";
import "../src/SimplePriceOracle.sol";
import "../src/MockTokens/MockERC20.sol";
import "../src/ErrorReporter.sol";

struct BaseJumpRateModelV2Params {
    uint baseRatePerYear;
    uint multiplierPerYear;
    uint jumpMultiplierPerYear;
    uint kink;
}

struct ComptrollerParams {
    uint initialExchangeRateMantissa;
    uint8 cTokenDecimals;
    uint USDCCollateralFactor;
    uint borrowTokenCollateralFactor;
    uint liquidationIncentive;
    uint closeFactor;
}

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
contract ToxicLiquidityExploration is Test {
    SimplePriceOracle public oracle;
    Comptroller public comptroller; // https://etherscan.io/address/0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B
    CErc20Immutable public cUSDC; // https://etherscan.io/address/0x39AA39c021dfbaE8faC545936693aC917d5E7563
    CErc20Immutable public cBorrowedToken; // made up parameters
    BaseJumpRateModelV2 public interestModel; // https://etherscan.io/address/0xD8EC56013EA119E7181d231E5048f90fBbe753c0

    // BaseJumpRateModelV2 Params:
    uint baseRatePerYear = 0;
    uint multiplierPerYear = 40000000000000000;
    uint jumpMultiplierPerYear = 1090000000000000000;
    uint kink = 800000000000000000;

    // Comptroller Params:
    uint initialExchangeRateMantissa = 200000000000000;
    uint8 cTokenDecimals = 8;

    // token Decimals:
    uint ERC20Decimals = 18;

    address admin;
    address userA;
    address userB;
    address userC;
    address whale;

    uint256 uscdCollateralFactor; // lending token (TODO: rename?)
    uint256 borrowTokenCollateralFactor;
    uint256 liquidationIncentive;
    uint256 closeFactor;

    mapping(address => string) names;

    MockERC20 usdc;
    MockERC20 borrowToken;

    /**
     * @notice Sets up instrumentation. Includes: creating test accounts, creating
     * ERC20s/cTokens/Comptroller/Oralce contracts, and gluing everything together
     * @dev Currently uses global variables for initialization // TODO: fix this
     */
    function setUp() public {
        oracle = new SimplePriceOracle();

        admin = vm.addr(1000);
        names[admin] = "Admin";
        userA = vm.addr(1001);
        names[userA] = "UserA";
        userB = vm.addr(1002);
        names[userB] = "UserB";
        userC = vm.addr(1003);
        names[userC] = "UserC";
        whale = vm.addr(1004);
        names[whale] = "Whale";

        interestModel = new JumpRateModelV2(
            baseRatePerYear,
            multiplierPerYear,
            jumpMultiplierPerYear,
            kink,
            admin
        );

        vm.startPrank(admin);

        usdc = new MockERC20("USDC", "USDC", ERC20Decimals);
        borrowToken = new MockERC20("CRV", "CRV", ERC20Decimals);

        comptroller = new Comptroller();
        comptroller._setPriceOracle(oracle);

        cUSDC = new CErc20Immutable(
            address(usdc),
            comptroller,
            interestModel,
            initialExchangeRateMantissa,
            "Compound USD Coin",
            "cUSCD",
            cTokenDecimals,
            payable(admin)
        );

        cBorrowedToken = new CErc20Immutable(
            address(borrowToken),
            comptroller,
            interestModel,
            initialExchangeRateMantissa,
            "Compound Borrow Coin",
            "cBorrowedToken",
            cTokenDecimals,
            payable(admin)
        );

        comptroller._supportMarket(cUSDC);
        comptroller._supportMarket(cBorrowedToken);

        vm.stopPrank();

        addToMarkets(userA);
        addToMarkets(userB);
        addToMarkets(whale);
    }

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

    function interpretGains(
        int[4] memory gains,
        int priceUSDC,
        int priceBorrow
    ) public {
        printPoolBalances();
        printBalances(whale);
        printBalances(userA);
        printBalances(userB);
        console.log("Gains/Loss of target: ");
        console.logInt(gains[0]);
        console.log("Gains/Loss of attacker: ");
        console.logInt(gains[1]);
        console.log("Gains/Loss of combined attacker/target:");
        console.logInt(gains[0] + gains[1]);
        console.log("Gains/Loss of whale's USDC: ");
        console.logInt(gains[2]);
        console.log("Gains/Loss of whale's BorrowedToken: ");
        console.logInt(gains[3]);
        console.log("Gains/Loss of whale combined in terms of USDC:");
        console.logInt(gains[2] + ((gains[3] * priceUSDC) / priceBorrow));
    }

    function printBalances(address user) public {
        console.log("User %s account snapshot:", names[user]);
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
        uint256 toxicLTV = (1 ether * 1 ether * 10000) /
            (liquidationIncentive * uscdCollateralFactor);

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
        console.log("  Toxic LTV        : ", toxicLTV);
        console.log("  LTV is toxic     : ", LTV > toxicLTV);
    }

    /****************************************
     *                 Tests:                *
     *****************************************/

    /**
     * @notice Performs simple short on Compound setup to see that everything is working as intended.
     */
    function testSimpleShort() public {
        // set up protocol
        uscdCollateralFactor = 855000000000000000;
        borrowTokenCollateralFactor = 550000000000000000;
        closeFactor = 500000000000000000;
        liquidationIncentive = 1080000000000000000;

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, 1 ether);
        oracle.setUnderlyingPrice(cBorrowedToken, 1 ether);

        // set comptroller variables
        setUpComptroller();

        // set up whale reserves
        mintFundsAndCollateral(whale, usdc, cUSDC, 10_000);
        mintFundsAndCollateral(whale, borrowToken, cBorrowedToken, 10_000);

        // start test: userA wants to short (aka borrow asset then swap it for
        // the collateral because they think the price of the borrow will drop)
        uint256 userAStartUSDC = 1000;
        mintFundsAndCollateral(userA, usdc, cUSDC, userAStartUSDC);
        borrow(userA, borrowToken, cBorrowedToken, 500);
        swapAssets(userA, borrowToken, usdc, 500);

        // price does drop!
        // drop by 50% to make math easy
        oracle.setUnderlyingPrice(cBorrowedToken, 0.5 ether);

        // repay loan
        swapAssets(userA, usdc, borrowToken, 250);
        repayBorrow(userA, borrowToken, cBorrowedToken, 500);
        removeCollateral(userA, cUSDC, 1000);

        // see userA made money
        assert(usdc.balanceOf(userA) == 1250);
        assert(usdc.balanceOf(userA) > userAStartUSDC);

        // see the whale can still withdraw all of his assets
        // (meaning the whale didn't lose money from userA's gain)
        removeCollateral(whale, cUSDC, 10000);
        removeCollateral(whale, cBorrowedToken, 10000);

        //printAll();
    }

    /**
     * @notice Runs an attack on the Compound pool similar to that of the 0VIX protocol attack (https://0vixprotocol.medium.com/0vix-exploit-post-mortem-15c882dcf479).
     * In this scenario there are three different accounts created:
     * - 'target' account: an account that has borrowed and will be induced into the TLTV range and be liquidated on a loop
     * - 'attacker' account: the account performing the liquidations
     * - 'whale' account: account representing other users who are not involved in the attack
     * note: the 'target' and 'attacker' can be the same off-chain entity but this isn't required
     * @param targetTLTV The target toxic loan to value ratio (used python modeling to determine equation)
     * @param liquidationIncentive_ The liquidation incentive to use in the Compound setup (affects TLTV ratio)
     * @param closeFactor_ The perecnt of an account that is able to be liquidated in a single liquidation call (Compound setup var)
     * @param uscdCollateralFactor_ The collateral factor applied to the collateral asset (USDC in this case). Affects the TLTV ratio
     //* @ param borrowTokenCollateralFactor_ The collateral factor applied to the borrowed asset (has no affect in this scenario)
     * @param usdcPrice The price of the USDC asset (held steady)
     * @param borrowTokenStartPrice The starting price of the borrowed token asset (is changed in scenario to affect target TLTV)
     * @param startUSDCAmountTarget How much USDC to have the target start with
     * @param startUSDCAmountAttacker How much USDC to have the attacker start with
     * @param startUSDCAmountWhale How much USDC to have the whale start with
     * @param startBorrowAmountWhale How much borrow token to have the whale start with
     * @return accountGains The gains/losses that occured to the above accounts relative to their starting usdc balances
     */
    function findToxicLTVExternalLosses(
        uint targetTLTV,
        uint liquidationIncentive_,
        uint closeFactor_,
        uint uscdCollateralFactor_,
        //uint borrowTokenCollateralFactor_,
        uint usdcPrice,
        uint borrowTokenStartPrice,
        uint startUSDCAmountTarget,
        uint startUSDCAmountAttacker,
        uint startUSDCAmountWhale,
        uint startBorrowAmountWhale
    ) public returns (int256[4] memory accountGains) {
        // require targetTLTV to actually be toxic
        require(
            targetTLTV >=
                (1 * 10000 * 1 ether * 1 ether) /
                    (liquidationIncentive_ * uscdCollateralFactor_),
            "targetTLTV need to be toxic"
        );

        // set up protocol
        liquidationIncentive = liquidationIncentive_;
        closeFactor = closeFactor_;
        uscdCollateralFactor = uscdCollateralFactor_;
        borrowTokenCollateralFactor = uscdCollateralFactor_; // should be different but having stack too deep errors

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, usdcPrice);
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenStartPrice);

        setUpComptroller();

        // set up whale reserves, buying 20_000 usdc's worth of both usdc and borrowed asset
        mintFundsAndCollateral(whale, usdc, cUSDC, startUSDCAmountWhale);
        mintFundsAndCollateral(
            whale,
            borrowToken,
            cBorrowedToken,
            startBorrowAmountWhale
        );

        // setup target account with initial LTV at .8 (non liquidatable level)
        mintFundsAndCollateral(userA, usdc, cUSDC, startUSDCAmountTarget);
        uint256 borrowAmount = ((startUSDCAmountTarget) *
            uscdCollateralFactor *
            8) / (borrowTokenStartPrice * 10);

        borrow(userA, borrowToken, cBorrowedToken, borrowAmount);
        require(
            getLTV(userA) < 8010 && getLTV(userA) > 7090,
            "inital LTV of target user is outside target range"
        );

        // setup attacker account with initial funds
        giveUserFunds(userB, usdc, startUSDCAmountAttacker);
        swapAssets(userB, usdc, borrowToken, startUSDCAmountAttacker);

        // figure out price of borrowed asset to hit targetTLTV for target account
        // attacker would manipulate an oracle somehow to achieve (or price would just drop here -- sad!)
        uint256 borrowTokenNewPrice = (targetTLTV *
            cUSDC.balanceOfUnderlying(userA) *
            uscdCollateralFactor_) / (borrowToken.balanceOf(userA) * 10000);
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenNewPrice);

        // see target TLTV is hit for target account with .001 wiggle room
        require(
            getLTV(userA) < targetTLTV + 10 && getLTV(userA) > targetTLTV - 10,
            "realized target TLTV wrong"
        );

        // loop with maximum closing factor to liquidate
        uint256 closingAmount = (closeFactor_ *
            cBorrowedToken.borrowBalanceCurrent(userA)) / 1 ether;
        uint256 liquidationLoops = 0;
        while (closingAmount > 0 && getLTV(userA) > 0) {
            liquidate(
                userB,
                userA,
                cUSDC,
                cBorrowedToken,
                borrowToken,
                closingAmount
            );
            closingAmount =
                (closeFactor_ * cBorrowedToken.borrowBalanceCurrent(userA)) /
                1 ether; // amount of borrow tokens
            liquidationLoops++;
            uint256 neededRemainingCollateral = (closingAmount *
                borrowTokenNewPrice *
                liquidationIncentive) / (usdcPrice * 1 ether);
            if (cUSDC.balanceOfUnderlying(userA) < neededRemainingCollateral) {
                if (cUSDC.balanceOfUnderlying(userA) < 10) {
                    // too small to try to claim
                    break;
                }
                // set to actual remaining amount of claimable collateral
                closingAmount =
                    (closeFactor_ * (cUSDC.balanceOfUnderlying(userA))) /
                    (borrowTokenNewPrice);
            }
        }
        console.log("loops: ", liquidationLoops);

        // replace actual price to reflect gains/losses more clearly on open market
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenStartPrice);

        // have userB transfer his funds out of the protocol
        removeCollateral(userB, cUSDC, cUSDC.balanceOfUnderlying(userB));
        swapAssets(userB, borrowToken, usdc, borrowToken.balanceOf(userB));

        // have userA swap borrowed funds for usdc
        swapAssets(userA, borrowToken, usdc, borrowToken.balanceOf(userA));

        // have whale withdraw all assets they can from pool
        removeCollateral(whale, cUSDC, cUSDC.balanceOfUnderlying(whale));
        // note: balance of whale's borrowed token is less than what is contained in the pool
        assert(
            borrowToken.balanceOf(address(cBorrowedToken)) <
                cBorrowedToken.balanceOf(whale)
        );
        removeCollateral(
            whale,
            cBorrowedToken,
            borrowToken.balanceOf(address(cBorrowedToken)) // this is max available in pool for withdrawl, note is SMALLER than whale's reserves
        );

        accountGains[0] =
            int256(usdc.balanceOf(userA)) -
            int256(startUSDCAmountTarget);
        accountGains[1] =
            int256(usdc.balanceOf(userB)) -
            int256(startUSDCAmountAttacker);
        accountGains[2] =
            int256(usdc.balanceOf(whale)) -
            int256(startUSDCAmountWhale);
        accountGains[3] =
            int256(borrowToken.balanceOf(whale)) -
            int256(startBorrowAmountWhale);

        interpretGains(
            accountGains,
            int(usdcPrice),
            int(borrowTokenStartPrice)
        );
    }

    /**
     * @notice Test to show behavior of Toxic Liquidity Spiral when prices are initially equal
     */
    function testTLTVEqualPrice() public {
        findToxicLTVExternalLosses(
            13500,
            1100000000000000000,
            500000000000000000,
            855000000000000000,
            // 550000000000000000,
            1 ether,
            1 ether,
            10_000,
            10_000,
            20_000,
            20_000
        );
    }
}
