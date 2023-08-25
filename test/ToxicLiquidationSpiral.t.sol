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
 * @title Test contract for running Toxic Liquidity Spirals on a Compound V2 Fork.
 * @author Lilyjjo
 * @notice This testing contract is setup to allow users to simulate different trading and price scenarios on Compound v2.
 * The function `findToxicLTVExternalLosses()` allows users to run toxic liquidation spirals with different setup
 * configurations and to compare the relative impacts of the configuration changes with outputs to a CSV file.
 */
contract ToxicLiquidityExploration is CompoundWrapper, ExportDataUtil {
    // Accounts for use in test writing
    address userA;
    address userB;
    address userC;
    address whale;

    /**
     * @notice Sets up a clean Compound V2 fork per test run.
     * @param protocolVars Chosen variables for test's Compound instantiation.
     */
    function setUpTest(
        CompoundV2InitializationVars memory protocolVars
    ) public {
        setUpComptrollerContracts(protocolVars);
        setUpUserAccounts();
    }

    /**
     * @notice Initializes addresses for use in tests.
     */
    function setUpUserAccounts() internal {
        userA = vm.addr(1001);
        userB = vm.addr(1002);
        userC = vm.addr(1003);
        whale = vm.addr(1004);

        addToMarkets(userA);
        addToMarkets(userB);
        addToMarkets(whale);
    }

    /**
     * @notice Prints out human readable interpretation of a Toxic Liquidity
     * Spiral scenario.
     * @param configVars The configuration variables TLS test was run with
     * @param resultVars The resulting state after the test compeletes
     */
    function interpretGains(
        SpiralConfigurationVariables memory configVars,
        SpiralResultVariables memory resultVars
    ) public {
        // print general account state
        console.log("Target Toxic LTV: ", configVars.targetTLTV);
        printPoolBalances();
        printUserBalances(whale, "Whale");
        printUserBalances(userA, "Target");
        printUserBalances(userB, "Attacker");

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

    /*****************************************
     *                 Tests                 *
     *****************************************/

    /**
     * @notice Performs simple short on Compound setup to see that everything is working as intended.
     */
    function testSimpleShort() public {
        CompoundV2InitializationVars
            memory protocolVars = basicInitializationVars(
                855000000000000000, // uscdCollateralFactor
                550000000000000000, // borrowTokenCollateralFactor
                1080000000000000000, // liquidationIncentive
                500000000000000000, // closeFactor
                1 ether, // cUSCDStartPrice
                1 ether // cBorrowTokenStartPrice
            );
        setUpTest(protocolVars);

        // set up whale reserves
        mintFundsAndCollateral(whale, usdc, cUSDC, 10_000);
        mintFundsAndCollateral(whale, borrowToken, cBorrowedToken, 10_000);

        // start test: userA wants to short (aka borrow asset then swap it for
        // the collateral because they think the price of the borrow will drop)
        uint256 userAStartUSDC = 1000;
        mintFundsAndCollateral(userA, usdc, cUSDC, userAStartUSDC);
        borrow(userA, cBorrowedToken, 500);
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
        CompoundV2InitializationVars
            memory protocolVars = basicInitializationVars(
                vars.uscdCollateralFactor,
                vars.borrowCollateralFactor,
                vars.liquidationIncentive,
                vars.closeFactor,
                vars.usdcPrice,
                vars.borrowTokenStartPrice
            );

        setUpTest(protocolVars);

        // Require targetTLTV to actually be toxic
        require(
            vars.targetTLTV >=
                (1 * 10000 * 1 ether * 1 ether) /
                    (vars.liquidationIncentive * vars.uscdCollateralFactor),
            "targetTLTV needs to be toxic"
        );

        // Set up whale reserves, buying both usdc and borrowed asset
        mintFundsAndCollateral(whale, usdc, cUSDC, vars.startUSDCAmountWhale);
        mintFundsAndCollateral(
            whale,
            borrowToken,
            cBorrowedToken,
            vars.startBorrowAmountWhale
        );

        // Setup target account with initial LTV at .8 (a non liquidatable level
        // under normal protocol operations). Can make this variable as well
        mintFundsAndCollateral(userA, usdc, cUSDC, vars.startUSDCAmountTarget);
        uint256 borrowAmount = ((vars.startUSDCAmountTarget) *
            protocolVars.uscdCollateralFactor *
            8) / (vars.borrowTokenStartPrice * 10);

        borrow(userA, cBorrowedToken, borrowAmount);
        require(
            getLTV(userA) < 8010 && getLTV(userA) > 7090,
            "inital LTV of target user is outside target range"
        );

        // Setup attacker account with initial funds
        giveUserFunds(userB, usdc, vars.startUSDCAmountAttacker);
        swapAssets(userB, usdc, borrowToken, vars.startUSDCAmountAttacker);

        // Figure out price of borrowed asset to hit targetTLTV for target account
        // Attacker would manipulate an oracle somehow to achieve (or price would just drop here -- sad!)
        uint256 borrowTokenNewPrice = (vars.targetTLTV *
            cUSDC.balanceOfUnderlying(userA) *
            vars.uscdCollateralFactor) / (borrowToken.balanceOf(userA) * 10000);
        oracle.setUnderlyingPrice(cBorrowedToken, borrowTokenNewPrice);

        // See target TLTV is hit for target account with .001 wiggle room
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
            uint256 seizeTokens = (closingAmount *
                protocolVars.liquidationIncentive *
                borrowTokenNewPrice) /
                (vars.usdcPrice * cUSDC.exchangeRateStored());
            if (seizeTokens > cUSDC.balanceOf(userA)) {
                // closingAmount is based on userA's borrow balance, but userA's
                // collateral can be too low to cover the liquidation reward.
                if (cUSDC.balanceOfUnderlying(userA) < 10) {
                    // Too small to try to claim, quit liquidation
                    break;
                }
                // This re-calculates the closingAmount to not revert on over-seizing
                // collateral.
                closingAmount =
                    (cUSDC.balanceOf(userA) *
                        vars.usdcPrice *
                        cUSDC.exchangeRateStored()) /
                    (protocolVars.liquidationIncentive * borrowTokenNewPrice);
                if (closingAmount == 0) {
                    break;
                }
            }
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
        }

        // Liquidation spiral is done, convert balances to better showcase transfer
        // of value.

        // Replace actual price to reflect gains/losses more clearly on open market
        oracle.setUnderlyingPrice(cBorrowedToken, vars.borrowTokenStartPrice);

        // Have userB transfer his funds out of the protocol and swap for USDC
        removeCollateral(userB, cUSDC, cUSDC.balanceOfUnderlying(userB));
        swapAssets(userB, borrowToken, usdc, borrowToken.balanceOf(userB));

        // Have userA swap borrowed funds for USDC
        swapAssets(userA, borrowToken, usdc, borrowToken.balanceOf(userA));

        // Have whale withdraw all assets they can from pool
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

        // combine whale gains in terms of usdc for easier analysis
        int whaleTotalGains = whaleUSDCGains +
            ((whaleBorrowGains * int(vars.borrowTokenStartPrice)) /
                int(vars.usdcPrice));

        // compute percentage lost of whale's funds (in basis points)
        uint whaleTotalInitialFunds = vars.startUSDCAmountWhale +
            ((vars.startBorrowAmountWhale * vars.borrowTokenStartPrice) /
                vars.usdcPrice);
        int whalePercentLost = (10_000 * whaleTotalGains) /
            int(whaleTotalInitialFunds);

        interpretGains(
            vars,
            SpiralResultVariables(
                targetGains,
                attackerGains,
                whaleUSDCGains,
                whaleBorrowGains,
                whaleTotalGains,
                whalePercentLost,
                borrowTokenNewPrice,
                liquidationLoops
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
                whaleTotalGains,
                whalePercentLost,
                borrowTokenNewPrice,
                liquidationLoops
            )
        );
    }

    /**
     * @notice Test to show behavior of Toxic Liquidity Spiral when prices are initially equal
     */
    function testTLTVEqualPriceHardcoded() public {
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
    } // command: forge test -vv -m testTLTVEqualPriceHardcoded

    /**
     * @notice Example test showing how to utilize fuzzing. The results of the
     * fuzz runs will be exported into the 'dataBank.csv' file for post-run
     * analysis.
     * @param liquidationIncentive Variable to fuzz.
     */
    function testFuzz_liquidationIncentive(uint liquidationIncentive) public {
        vm.assume(liquidationIncentive < 1e18 && liquidationIncentive > 0);

        uint targetToxicLiquidityThreshold = 13500;
        //uint liquidationIncentive = 1100000000000000000;
        uint closeFactor = 500000000000000000;
        uint usdcCollateralFactor = 855000000000000000;
        uint borrowedTokenCollateralFactor = 550000000000000000;
        uint usdcStartPrice = 1 ether;
        uint borredTokenStartPrice = 1 ether;
        uint startingUSDCAmountTarget = 10_000;
        uint startingUSDCAmountAttacker = 10_000;
        uint startingUSDCAmountWhale = 20_000;
        uint startingBorredTokenAmountWhale = 20_000;

        // TLTV logic will not work if this is not true
        vm.assume(
            targetToxicLiquidityThreshold >=
                (1 * 10000 * 1 ether * 1 ether) /
                    (liquidationIncentive * usdcCollateralFactor)
        );

        // run actual test
        findToxicLTVExternalLosses(
            SpiralConfigurationVariables(
                targetToxicLiquidityThreshold, // Target Toxic Liquidity Threshold
                liquidationIncentive, // Liquidation Incentive
                closeFactor, // Close Factor
                usdcCollateralFactor, // USDC Collateral Factor
                borrowedTokenCollateralFactor, // Borrow Collateral Factor
                usdcStartPrice, // USDC Start Price
                borredTokenStartPrice, // Borrow Start Price
                startingUSDCAmountTarget, // Starting USDC Amount Target
                startingUSDCAmountAttacker, // Starting USDC Amount Attacker
                startingUSDCAmountWhale, // Starting USDC Amount Whale
                startingBorredTokenAmountWhale // Starting Borrow Amount Whale
            )
        );
    }

    /**
     * @notice Example test showing how to utilize fuzzing. The results of the
     * fuzz runs will be exported into the 'dataBank.csv' file for post-run
     * analysis.
     * @param targetToxicLiquidityThreshold Variable to fuzz.
     */
    function testFuzz_targetToxicLTV(
        uint24 targetToxicLiquidityThreshold
    ) public {
        vm.assume(
            targetToxicLiquidityThreshold < 2e18 &&
                targetToxicLiquidityThreshold > 0
        );

        //uint targetToxicLiquidityThreshold = 13500;
        uint liquidationIncentive = 1100000000000000000;
        uint closeFactor = 500000000000000000;
        uint usdcCollateralFactor = 855000000000000000;
        uint borrowedTokenCollateralFactor = 550000000000000000;
        uint usdcStartPrice = 1 ether;
        uint borredTokenStartPrice = 1 ether;
        uint startingUSDCAmountTarget = 10_000;
        uint startingUSDCAmountAttacker = 10_000;
        uint startingUSDCAmountWhale = 20_000;
        uint startingBorredTokenAmountWhale = 20_000;

        // TLTV logic will not work if this is not true
        vm.assume(
            targetToxicLiquidityThreshold >=
                (1 * 10000 * 1 ether * 1 ether) /
                    (liquidationIncentive * usdcCollateralFactor)
        );

        // run actual test
        findToxicLTVExternalLosses(
            SpiralConfigurationVariables(
                targetToxicLiquidityThreshold, // Target Toxic Liquidity Threshold
                liquidationIncentive, // Liquidation Incentive
                closeFactor, // Close Factor
                usdcCollateralFactor, // USDC Collateral Factor
                borrowedTokenCollateralFactor, // Borrow Collateral Factor
                usdcStartPrice, // USDC Start Price
                borredTokenStartPrice, // Borrow Start Price
                startingUSDCAmountTarget, // Starting USDC Amount Target
                startingUSDCAmountAttacker, // Starting USDC Amount Attacker
                startingUSDCAmountWhale, // Starting USDC Amount Whale
                startingBorredTokenAmountWhale // Starting Borrow Amount Whale
            )
        );
    } // command: forge test -vv -m testFuzz_target
}
