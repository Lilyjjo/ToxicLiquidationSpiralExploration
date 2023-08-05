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

contract ToxicLiquidityExploration is Test {
    SimplePriceOracle public oracle;
    Comptroller public comptroller; // https://etherscan.io/address/0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B
    CErc20Immutable public cUSDC; // https://etherscan.io/address/0x39AA39c021dfbaE8faC545936693aC917d5E7563
    CErc20Immutable public cCRV; // made up parameters
    BaseJumpRateModelV2 public interestModel; // https://etherscan.io/address/0xD8EC56013EA119E7181d231E5048f90fBbe753c0
    address admin;
    address avi;
    address michael;
    address bob_the_whale;
    address stacy;

    uint256 uscdCollateralFactor;
    uint256 crvCollateralFactor;
    uint256 liquidationIncentive;
    uint256 closeFactor;

    mapping(address => string) names;

    MockERC20 usdc;
    MockERC20 crv;

    function setUpComptroller() public {
        vm.startPrank(admin);
        comptroller._setCloseFactor(closeFactor);
        comptroller._setCollateralFactor(cUSDC, uscdCollateralFactor);
        comptroller._setCollateralFactor(cCRV, crvCollateralFactor);
        comptroller._setLiquidationIncentive(liquidationIncentive);
        vm.stopPrank();
    }

    function addToMarkets(address user) public {
        vm.prank(user);
        address[] memory addys = new address[](2);
        addys[0] = address(cUSDC);
        addys[1] = address(cCRV);
        comptroller.enterMarkets(addys);
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
        // paying crv to get usdc
        vm.startPrank(liquidator);
        borrowCoin.approve(address(cTokenBorrow), repayAmount);
        cTokenBorrow.liquidateBorrow(target, repayAmount, cTokenCollateral);
        vm.stopPrank();
    }

    function getLTV(address user) public returns (uint256 LTV) {
        uint256 cCRVBorrowBalance = cCRV.borrowBalanceCurrent(user);
        uint256 cUSDCBalance = cUSDC.balanceOfUnderlying(user);

        uint256 cUSDCBorrowBalance = cUSDC.borrowBalanceCurrent(user);
        uint256 cCRVBalance = cCRV.balanceOfUnderlying(user);

        uint256 denominator = (cUSDCBalance *
            oracle.getUnderlyingPrice(cUSDC) *
            uscdCollateralFactor) / 1 ether;
        denominator +=
            (cCRVBalance *
                oracle.getUnderlyingPrice(cCRV) *
                crvCollateralFactor) /
            1 ether;
        uint256 numerator = cCRVBorrowBalance * oracle.getUnderlyingPrice(cCRV);
        numerator += cUSDCBorrowBalance * oracle.getUnderlyingPrice(cUSDC);
        if (denominator != 0) {
            LTV = (numerator * 10000) / denominator;
        } else {
            LTV = 0;
        }
    }

    function setUp() public {
        oracle = new SimplePriceOracle();

        admin = vm.addr(1000);
        names[admin] = "Admin";
        avi = vm.addr(1001);
        names[avi] = "Avi";
        michael = vm.addr(1002);
        names[michael] = "Michael";
        bob_the_whale = vm.addr(1003);
        names[bob_the_whale] = "Bob the Whale";
        stacy = vm.addr(1004);
        names[stacy] = "Stacy";
        interestModel = new JumpRateModelV2(
            0,
            40000000000000000,
            1090000000000000000,
            800000000000000000,
            admin
        );

        vm.startPrank(admin);

        usdc = new MockERC20("USDC", "USDC", 18);
        crv = new MockERC20("CRV", "CRV", 18);

        comptroller = new Comptroller();
        comptroller._setPriceOracle(oracle);

        cUSDC = new CErc20Immutable(
            address(usdc),
            comptroller,
            interestModel,
            200000000000000,
            "Compound USD Coin",
            "cUSCD",
            8,
            payable(admin)
        );
        cCRV = new CErc20Immutable(
            address(crv),
            comptroller,
            interestModel,
            200000000000000,
            "Compound CRV Coin",
            "cCRV",
            8,
            payable(admin)
        );

        comptroller._supportMarket(cUSDC);
        comptroller._supportMarket(cCRV);

        oracle.setUnderlyingPrice(cUSDC, 1 ether);
        vm.stopPrank();

        addToMarkets(avi);
        addToMarkets(michael);
        addToMarkets(bob_the_whale);
    }

    function testSimpleShort() public {
        // set up protocol
        uscdCollateralFactor = 855000000000000000;
        crvCollateralFactor = 550000000000000000;
        closeFactor = 500000000000000000;
        liquidationIncentive = 1080000000000000000;
        setUpComptroller();

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, 1 ether);
        oracle.setUnderlyingPrice(cCRV, 1 ether);

        // set up whale reserves
        mintFundsAndCollateral(bob_the_whale, usdc, cUSDC, 10_000);
        mintFundsAndCollateral(bob_the_whale, crv, cCRV, 10_000);

        // start test: avi wants to short
        uint256 aviStartUSDC = 1000;
        mintFundsAndCollateral(avi, usdc, cUSDC, aviStartUSDC);
        borrow(avi, crv, cCRV, 500);
        swapAssets(avi, crv, usdc, 500);

        // price does drop!
        oracle.setUnderlyingPrice(cCRV, 0.5 ether);

        // repay loan
        swapAssets(avi, usdc, crv, 250);
        repayBorrow(avi, crv, cCRV, 500);
        removeCollateral(avi, cUSDC, 1000);

        // see avi made money
        assert(usdc.balanceOf(avi) == 1250);
        assert(usdc.balanceOf(avi) > aviStartUSDC);

        // see bob the whale can still withdraw all of his assets
        // (meaning bob the whale didn't lose money from avi's gain)
        removeCollateral(bob_the_whale, cUSDC, 10000);
        removeCollateral(bob_the_whale, cCRV, 10000);

        //printAll();
    }

    function findToxicLTVExternalLosses(
        uint targetTLTV,
        uint liquidationIncentive_,
        uint closeFactor_,
        uint uscdCollateralFactor_,
        uint crvCollateralFactor_,
        uint usdcPrice,
        uint crvStartPrice,
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
        crvCollateralFactor = crvCollateralFactor_;
        setUpComptroller();

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, usdcPrice);
        oracle.setUnderlyingPrice(cCRV, crvStartPrice);

        // set up whale reserves
        mintFundsAndCollateral(bob_the_whale, usdc, cUSDC, 20_000);
        mintFundsAndCollateral(bob_the_whale, crv, cCRV, 20_000);

        // setup attacker account with same initial funds
        giveUserFunds(michael, usdc, startUSDCAmount);
        swapAssets(michael, usdc, crv, startUSDCAmount);

        // setup target account with initial LTV at .8 (non liquidatable level)
        mintFundsAndCollateral(avi, usdc, cUSDC, startUSDCAmount);
        // uint256 borrowAmount = (startUSDCAmount - (startUSDCAmount * 28 / 100)) * uscdCollateralFactor * 8 / (crvStartPrice * 10);
        uint256 borrowAmount = ((startUSDCAmount) * uscdCollateralFactor * 8) /
            (crvStartPrice * 10);
        borrow(avi, crv, cCRV, borrowAmount);
        // borrow(avi, usdc, cUSDC, startUSDCAmount * 28 / 100);
        //console.log(getLTV(avi));
        printBalances(avi);
        require(
            getLTV(avi) < 8010 && getLTV(avi) > 7090,
            "realized inital LTV wrong"
        );

        // figure out price to hit targetTLTV
        // attacker would manipulate an oracle somehow to achieve
        uint256 crvNewPrice = (targetTLTV *
            cUSDC.balanceOfUnderlying(avi) *
            uscdCollateralFactor_) / (crv.balanceOf(avi) * 10000);

        // see target TLTV hit
        oracle.setUnderlyingPrice(cCRV, crvNewPrice);
        require(
            getLTV(avi) < targetTLTV + 10 && getLTV(avi) > targetTLTV - 10,
            "realized target TLTV wrong"
        );

        // loop with maximum closing factor to liquidate
        uint256 closingAmount = (closeFactor_ *
            cCRV.borrowBalanceCurrent(avi)) / 1 ether;
        uint256 liquidationLoops = 0;
        while (closingAmount > 0 && getLTV(avi) > 0) {
            liquidate(michael, avi, cUSDC, cCRV, crv, closingAmount);
            closingAmount =
                (closeFactor_ * cCRV.borrowBalanceCurrent(avi)) /
                1 ether; // amount of borrow tokens
            liquidationLoops++;
            uint256 neededRemainingCollateral = (closingAmount *
                crvNewPrice *
                liquidationIncentive) / (usdcPrice * 1 ether);
            if (cUSDC.balanceOfUnderlying(avi) < neededRemainingCollateral) {
                if (cUSDC.balanceOfUnderlying(avi) < 10) {
                    // too small to try to claim
                    break;
                }
                // set to actual remaining amount of claimable collateral
                closingAmount =
                    (closeFactor_ * (cUSDC.balanceOfUnderlying(avi))) /
                    (crvNewPrice);
            }
        }
        console.log("loops: ", liquidationLoops);

        // have michael transfer his funds out of the protocol
        removeCollateral(michael, cUSDC, cUSDC.balanceOfUnderlying(michael));
        // replace actual price to reflect michael's gains more clearly
        oracle.setUnderlyingPrice(cCRV, crvStartPrice);
        swapAssets(michael, crv, usdc, crv.balanceOf(michael));

        // if michael and avi are same person, add avi's losses
        swapAssets(avi, crv, usdc, crv.balanceOf(avi));

        // remove stacy's portion too
        //repayBorrow(stacy, usdc, cUSDC, cUSDC.borrowBalanceCurrent(stacy));
        //removeCollateral(stacy, cUSDC, cUSDC.balanceOfUnderlying(stacy));

        uint256 startValue = 2 * startUSDCAmount;
        uint256 endValue = usdc.balanceOf(avi) + usdc.balanceOf(michael);

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
        console.log("  CRV collateral : ", cCRV.getCash());
        console.log("  USCD borrows   : ", cUSDC.totalBorrows());
        console.log("  CRV borrows    : ", cCRV.totalBorrows());
    }

    function printBalances(address user) public {
        console.log("User %s account snapshot:", names[user]);
        (uint err, uint liquidity, uint shortfall) = comptroller
            .getAccountLiquidity(user);

        uint256 usdcBalance = usdc.balanceOf(user);
        uint256 cUSDCBalance = cUSDC.balanceOfUnderlying(user);
        uint256 cCRVBalance = cCRV.balanceOfUnderlying(user);
        uint256 crvBalance = crv.balanceOf(user);
        uint256 cCRVBorrowBalance = cCRV.borrowBalanceCurrent(user);

        uint256 denominator = (cCRVBorrowBalance *
            oracle.getUnderlyingPrice(cUSDC) *
            uscdCollateralFactor) / 1 ether;
        uint256 numerator = cCRVBalance * oracle.getUnderlyingPrice(cCRV);
        uint256 LTV;
        if (denominator != 0) {
            LTV = (numerator * 10000) / denominator;
        } else {
            LTV = 0;
        }
        uint256 toxicLTV = (1 ether * 1 ether * 10000) /
            (liquidationIncentive * uscdCollateralFactor);

        console.log("  USDC : ", usdcBalance);
        console.log("  CRV  : ", crvBalance);
        console.log("  cUSDC: ", cUSDCBalance);
        console.log("  cCRV : ", cCRVBalance);
        console.log("  borrowed CRV     : ", cCRVBorrowBalance);
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
        printBalances(bob_the_whale);
        printBalances(avi);
        printBalances(michael);
        printBalances(stacy);
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
