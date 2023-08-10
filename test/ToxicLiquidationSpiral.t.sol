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

/*

Goal:
- create simulator to poke at the toxic liquidation spiral with
- things to poke:
    - changing parameters to see range of behavior 
    - seeing if the % of loss is wiggable 
    - 
 

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

    function setUpComptroller() public {
        assert(oracle.getUnderlyingPrice(cUSDC) != 0);
        assert(oracle.getUnderlyingPrice(cBorrowedToken) != 0);

        vm.startPrank(admin);
        comptroller._setCloseFactor(closeFactor);
        comptroller._setCollateralFactor(cUSDC, uscdCollateralFactor);
        comptroller._setCollateralFactor(
            cBorrowedToken,
            borrowTokenCollateralFactor
        );
        comptroller._setLiquidationIncentive(liquidationIncentive);
        vm.stopPrank();
    }

    function addToMarkets(address user) public {
        vm.prank(user);
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(cUSDC);
        cTokens[1] = address(cBorrowedToken);
        comptroller.enterMarkets(cTokens);
    }

    function giveUserFunds(
        address user,
        MockERC20 coin,
        uint256 amount
    ) public {
        vm.prank(admin);
        coin.mint(user, amount);
    }

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
        cToken.mint(amount);
    }

    function borrow(
        address user,
        MockERC20 coin,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.prank(user);
        cToken.borrow(amount);
    }

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

    function repayBorrow(
        address user,
        MockERC20 coin,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.startPrank(user);
        coin.approve(address(cToken), amount);
        cToken.repayBorrow(amount);
        vm.stopPrank();
    }

    function removeCollateral(
        address user,
        CErc20Immutable cToken,
        uint256 amount
    ) public {
        vm.prank(user);
        cToken.redeemUnderlying(amount);
    }

    function liquidate(
        address liquidator,
        address target,
        CErc20Immutable cTokenCollateral,
        CErc20Immutable cTokenBorrow,
        MockERC20 borrowCoin,
        uint256 repayAmount
    ) public {
        // liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral)
        // paying borrowToken to get usdc
        vm.startPrank(liquidator);
        borrowCoin.approve(address(cTokenBorrow), repayAmount);
        cTokenBorrow.liquidateBorrow(target, repayAmount, cTokenCollateral);
        vm.stopPrank();
    }

    function getLTV(address user) public returns (uint256 LTV) {
        uint256 cBorrowedTokenBorrowBalance = cBorrowedToken
            .borrowBalanceCurrent(user);
        uint256 cUSDCBalance = cUSDC.balanceOfUnderlying(user);

        uint256 cUSDCBorrowBalance = cUSDC.borrowBalanceCurrent(user);
        uint256 cBorrowedTokenBalance = cBorrowedToken.balanceOfUnderlying(
            user
        );

        uint256 denominator = (cUSDCBalance *
            oracle.getUnderlyingPrice(cUSDC) *
            uscdCollateralFactor) / 1 ether;
        denominator +=
            (cBorrowedTokenBalance *
                oracle.getUnderlyingPrice(cBorrowedToken) *
                borrowTokenCollateralFactor) /
            1 ether;
        uint256 numerator = cBorrowedTokenBorrowBalance *
            oracle.getUnderlyingPrice(cBorrowedToken);
        numerator += cUSDCBorrowBalance * oracle.getUnderlyingPrice(cUSDC);
        if (denominator != 0) {
            LTV = (numerator * 10000) / denominator;
        } else {
            LTV = 0;
        }
    }

    /*  
      Creates:
        - Users to interact with protocol
        - Compound setup (Comptroller with interest rate model and CTokens)
        - Underlying ERC20s for CTokens
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

    function testSimpleShort() public {
        // set up protocol
        uscdCollateralFactor = 855000000000000000;
        borrowTokenCollateralFactor = 550000000000000000;
        closeFactor = 500000000000000000;
        liquidationIncentive = 1080000000000000000;

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, 1 ether);
        oracle.setUnderlyingPrice(cBorrowedToken, 1 ether);

        setUpComptroller();
        // set up whale reserves
        mintFundsAndCollateral(whale, usdc, cUSDC, 10_000);
        mintFundsAndCollateral(whale, borrowToken, cBorrowedToken, 10_000);

        // start test: userA wants to short
        uint256 userAStartUSDC = 1000;
        mintFundsAndCollateral(userA, usdc, cUSDC, userAStartUSDC);
        borrow(userA, borrowToken, cBorrowedToken, 500);
        swapAssets(userA, borrowToken, usdc, 500);

        // price does drop!
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

    function findToxicLTVExternalLosses(
        uint targetTLTV,
        uint liquidationIncentive_,
        uint closeFactor_,
        uint uscdCollateralFactor_,
        uint borrowTokenCollateralFactor_,
        uint usdcPrice,
        uint borrowTokenStartPrice,
        uint startUSDCAmount
    ) public {
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
        borrowTokenCollateralFactor = borrowTokenCollateralFactor_;

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, usdcPrice);
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenStartPrice);

        setUpComptroller();

        // set up whale reserves
        mintFundsAndCollateral(whale, usdc, cUSDC, 20_000);
        mintFundsAndCollateral(whale, borrowToken, cBorrowedToken, 20_000);

        // setup attacker account with same initial funds
        giveUserFunds(userB, usdc, startUSDCAmount);
        swapAssets(userB, usdc, borrowToken, startUSDCAmount);

        // setup target account with initial LTV at .8 (non liquidatable level)
        mintFundsAndCollateral(userA, usdc, cUSDC, startUSDCAmount);
        // uint256 borrowAmount = (startUSDCAmount - (startUSDCAmount * 28 / 100)) * uscdCollateralFactor * 8 / (borrowTokenStartPrice * 10);
        uint256 borrowAmount = ((startUSDCAmount) * uscdCollateralFactor * 8) /
            (borrowTokenStartPrice * 10);
        borrow(userA, borrowToken, cBorrowedToken, borrowAmount);
        // borrow(userA, usdc, cUSDC, startUSDCAmount * 28 / 100);
        //console.log(getLTV(userA));
        printBalances(userA);
        require(
            getLTV(userA) < 8010 && getLTV(userA) > 7090,
            "realized inital LTV wrong"
        );

        // figure out price to hit targetTLTV
        // attacker would manipulate an oracle somehow to achieve
        uint256 borrowTokenNewPrice = (targetTLTV *
            cUSDC.balanceOfUnderlying(userA) *
            uscdCollateralFactor_) / (borrowToken.balanceOf(userA) * 10000);

        // see target TLTV hit
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenNewPrice);
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

        // have userB transfer his funds out of the protocol
        removeCollateral(userB, cUSDC, cUSDC.balanceOfUnderlying(userB));
        // replace actual price to reflect userB's gains more clearly
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenStartPrice);
        swapAssets(userB, borrowToken, usdc, borrowToken.balanceOf(userB));

        // if userB and userA are same person, add userA's losses
        swapAssets(userA, borrowToken, usdc, borrowToken.balanceOf(userA));

        // remove userC's portion too
        //repayBorrow(userC, usdc, cUSDC, cUSDC.borrowBalanceCurrent(userC));
        //removeCollateral(userC, cUSDC, cUSDC.balanceOfUndpwderlying(userC));

        uint256 startValue = 2 * startUSDCAmount;
        uint256 endValue = usdc.balanceOf(userA) + usdc.balanceOf(userB);

        printAll();
        console.log("start value: ", startValue);
        console.log("end value  : ", endValue);
    }

    function testTLTVEqualPrice() public {
        findToxicLTVExternalLosses(
            13500,
            1100000000000000000,
            500000000000000000,
            855000000000000000,
            550000000000000000,
            1 ether,
            1 ether,
            10000
        );
    }

    function testTLTVHigherBorrowPrice() public {
        //findToxicLTVExternalLosses(13500, 1100000000000000000, 500000000000000000, 855000000000000000, 550000000000000000, 1 ether, 1.5 ether, 10000);
    }

    function testTLTVLowerBorrowPrice() public {
        //findToxicLTVExternalLosses(13500, 1100000000000000000, 500000000000000000, 855000000000000000, 550000000000000000, 1 ether, 0.5 ether, 10000);
    }

    function printPoolBalances() public {
        console.log("Pool balances: ");
        console.log("  USCD reserves  : ", cUSDC.getCash());
        console.log("  CRV collateral : ", cBorrowedToken.getCash());
        console.log("  USCD borrows   : ", cUSDC.totalBorrows());
        console.log("  CRV borrows    : ", cBorrowedToken.totalBorrows());
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
        uint256 cBorrowedTokenBorrowBalance = cBorrowedToken
            .borrowBalanceCurrent(user);

        uint256 denominator = (cBorrowedTokenBorrowBalance *
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
        console.log("  borrowed CRV     : ", cBorrowedTokenBorrowBalance);
        console.log("  borrow value     : ", numerator / 1 ether);
        console.log("  collateral value : ", denominator / 1 ether);
        console.log("  liquidity: ", liquidity);
        console.log("  shortfall: ", shortfall);
        console.log("  LTV              : ", LTV);
        console.log("  Toxic LTV        : ", toxicLTV);
        console.log("  LTV is toxic     : ", LTV > toxicLTV);
    }

    function printAll() public {
        printPoolBalances();
        printBalances(whale);
        printBalances(userA);
        printBalances(userB);
        printBalances(userC);
    }
}

/*

cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "balanceOf(address)(uint256)" 0x...



/*

Foundry Testing Codes:

sender = vm.addr(1001);
receiver = vm.addr(1002);

vm.deal(user, 100_000 ether);

vm.startPrank(address);        
vm.stopPrank();

vm.warp(block.timestamp + time);

*/
