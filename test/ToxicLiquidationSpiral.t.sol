// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";

import "../src/CTokenInterfaces.sol";
import "../src/ComptrollerInterface.sol";

import "../src/Comptroller.sol";
import "../src/CToken.sol";
import "../src/CErc20Immutable.sol";
import "../src/JumpRateModelV2.sol";
import "../src/SimplePriceOracle.sol";
import "../src/MockTokens/MockERC20.sol";
import "../src/ErrorReporter.sol";

import "./utils/CompoundWrapper.sol";
import "./utils/TLSStructs.sol";
import "./utils/DataExport.sol";

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
contract ToxicLiquidityExploration is CompoundWrapper, ExportData {
    // test accounts
    address userA;
    address userB;
    address userC;
    address whale;

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

    function interpretGains(
        SpiralConfigurationVariables memory configVars,
        SpiralResultVariables memory resultVars
    ) public {
        // print general account state
        console.log("Target Toxic LTV: ", configVars.targetTLTV);
        printPoolBalances();
        printBalances(whale, "Whale");
        printBalances(userA, "Target");
        printBalances(userB, "Attacker");

        // print gains/losses
        console.log("Gains/Loss of target: ");
        console.logInt(resultVars.gainsTarget);
        console.log("Gains/Loss of attacker: ");
        console.logInt(resultVars.gainsAttacker);
        console.log("Gains/Loss of combined attacker/target:");
        int gainsAttackerCombined = resultVars.gainsAttacker +
            resultVars.gainsTarget;
        console.logInt(gainsAttackerCombined);
        console.log("Gains/Loss of whale's USDC: ");
        console.logInt(resultVars.gainsWhaleUSDC);
        console.log("Gains/Loss of whale's BorrowedToken: ");
        console.logInt(resultVars.gainsWhaleBorrow);
        console.log("Gains/Loss of whale combined in terms of USDC:");
        int lossWhaleCombined = resultVars.gainsWhaleUSDC +
            ((resultVars.gainsWhaleBorrow * int(configVars.usdcPrice)) /
                int(configVars.borrowTokenStartPrice));
        console.logInt(lossWhaleCombined);
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
    }

    /**
     * @notice Runs an attack on the Compound pool similar to that of the 0VIX protocol attack (https://0vixprotocol.medium.com/0vix-exploit-post-mortem-15c882dcf479).
     * In this scenario there are three different accounts created:
     * - 'target' account: an account that has borrowed and will be induced into the TLTV range and be liquidated on a loop
     * - 'attacker' account: the account performing the liquidations
     * - 'whale' account: an account representing other users who are not involved in the attack
     * note: the 'target' and 'attacker' can be the same off-chain entity but this isn't required
     * @param vars The configuration setup for the Spiral
     */
    function findToxicLTVExternalLosses(
        SpiralConfigurationVariables memory vars
    ) public {
        // require targetTLTV to actually be toxic
        require(
            vars.targetTLTV >=
                (1 * 10000 * 1 ether * 1 ether) /
                    (vars.liquidationIncentive * vars.uscdCollateralFactor),
            "targetTLTV need to be toxic"
        );

        // set up protocol
        liquidationIncentive = vars.liquidationIncentive;
        closeFactor = vars.closeFactor;
        uscdCollateralFactor = vars.uscdCollateralFactor;
        borrowTokenCollateralFactor = vars.borrowCollateralFactor;

        // set up prices
        oracle.setUnderlyingPrice(cUSDC, vars.usdcPrice);
        oracle.setUnderlyingPrice(cBorrowedToken, vars.borrowTokenStartPrice);

        setUpComptroller();

        // set up whale reserves, buying both usdc and borrowed asset
        mintFundsAndCollateral(whale, usdc, cUSDC, vars.startUSDCAmountWhale);
        mintFundsAndCollateral(
            whale,
            borrowToken,
            cBorrowedToken,
            vars.startBorrowAmountWhale
        );

        // setup target account with initial LTV at .8 (non liquidatable level)
        mintFundsAndCollateral(userA, usdc, cUSDC, vars.startUSDCAmountTarget);
        uint256 borrowAmount = ((vars.startUSDCAmountTarget) *
            uscdCollateralFactor *
            8) / (vars.borrowTokenStartPrice * 10);

        borrow(userA, borrowToken, cBorrowedToken, borrowAmount);
        require(
            getLTV(userA) < 8010 && getLTV(userA) > 7090,
            "inital LTV of target user is outside target range"
        );

        // setup attacker account with initial funds
        giveUserFunds(userB, usdc, vars.startUSDCAmountAttacker);
        swapAssets(userB, usdc, borrowToken, vars.startUSDCAmountAttacker);

        // figure out price of borrowed asset to hit targetTLTV for target account
        // attacker would manipulate an oracle somehow to achieve (or price would just drop here -- sad!)
        uint256 borrowTokenNewPrice = (vars.targetTLTV *
            cUSDC.balanceOfUnderlying(userA) *
            vars.uscdCollateralFactor) / (borrowToken.balanceOf(userA) * 10000);
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenNewPrice);

        // see target TLTV is hit for target account with .001 wiggle room
        require(
            getLTV(userA) < vars.targetTLTV + 10 &&
                getLTV(userA) > vars.targetTLTV - 10,
            "realized target TLTV wrong"
        );

        // loop with maximum closing factor to liquidate
        uint256 closingAmount = (vars.closeFactor *
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
                (vars.closeFactor *
                    cBorrowedToken.borrowBalanceCurrent(userA)) /
                1 ether; // amount of borrow tokens
            liquidationLoops++;
            uint256 neededRemainingCollateral = (closingAmount *
                borrowTokenNewPrice *
                liquidationIncentive) / (vars.usdcPrice * 1 ether);
            if (cUSDC.balanceOfUnderlying(userA) < neededRemainingCollateral) {
                if (cUSDC.balanceOfUnderlying(userA) < 10) {
                    // too small to try to claim
                    break;
                }
                // set to actual remaining amount of claimable collateral
                closingAmount =
                    (vars.closeFactor * (cUSDC.balanceOfUnderlying(userA))) /
                    (borrowTokenNewPrice);
            }
        }
        console.log("loops: ", liquidationLoops);

        // replace actual price to reflect gains/losses more clearly on open market
        oracle.setUnderlyingPrice(cBorrowedToken, vars.borrowTokenStartPrice);

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

        int targetGains = int256(usdc.balanceOf(userA)) -
            int256(vars.startUSDCAmountTarget);
        int attackerGains = int256(usdc.balanceOf(userB)) -
            int256(vars.startUSDCAmountAttacker);
        int whaleUSDCGains = int256(usdc.balanceOf(whale)) -
            int256(vars.startUSDCAmountWhale);
        int whaleBorrowGains = int256(borrowToken.balanceOf(whale)) -
            int256(vars.startBorrowAmountWhale);

        interpretGains(
            vars,
            SpiralResultVariables(
                targetGains,
                attackerGains,
                whaleUSDCGains,
                whaleBorrowGains,
                borrowTokenNewPrice
            )
        );
        exportTLSData(
            "dataBank.csv",
            vars,
            SpiralResultVariables(
                targetGains,
                attackerGains,
                whaleUSDCGains,
                whaleBorrowGains,
                borrowTokenNewPrice
            )
        );
    }

    /**
     * @notice Test to show behavior of Toxic Liquidity Spiral when prices are initially equal
     */
    function testTLTVEqualPrice() public {
        findToxicLTVExternalLosses(
            SpiralConfigurationVariables(
                13500, // Target Toxic Liquidity Threshold
                1100000000000000000, // Liquidation Incentive
                500000000000000000, // Close Factor
                855000000000000000, // USDC Collateral Factor
                550000000000000000, // Borrow Collateral Factor
                1 ether, // USDC Start Price
                1 ether, // Borrow Start Price
                10_000, // Starting USDC Amount Target
                10_000, // Starting USDC Amount Attacker
                20_000, // Starting USDC Amount Whale
                20_000 // Starting Borrow Amount Whale
            )
        );
    }
}
