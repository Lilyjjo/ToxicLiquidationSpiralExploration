// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

struct SpiralConfigurationVariables {
    uint targetTLTV;
    uint liquidationIncentive;
    uint closeFactor;
    uint uscdCollateralFactor;
    uint borrowCollateralFactor;
    uint usdcPrice;
    uint borrowTokenStartPrice;
    uint startUSDCAmountTarget;
    uint startUSDCAmountAttacker;
    uint startUSDCAmountWhale;
    uint startBorrowAmountWhale;
}

struct SpiralResultVariables {
    int gainsTarget;
    int gainsAttacker;
    int gainsWhaleUSDC;
    int gainsWhaleBorrow;
    int gainsWhaleTotal;
    int whalePercentLost;
    uint borrowTokenToxicPrice;
    uint liquidationLoops;
}
