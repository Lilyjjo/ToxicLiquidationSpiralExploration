# Toxic Liquidation Spiral Exploration

The purpose of this repo is to provide code demonstrating and exploring different aspects of Toxic Liquidation Spirals. It is a WIP.


Toxic Liquidation Spirals can occur in DeFi projects which utilize loan-to-value ratio based account liquidations. 
The intent of liquidating an account is to improve the account's health by lowering the loan-to-value ratio, but, under certain conditions, the process of liquidation can actually make an account's health worse.
This was [first observed](https://arxiv.org/pdf/2212.07306.pdf#:~:text=3%20Toxic%20Liquidation%20Spirals&text=Toxic%20liquida%2D%20tions%20are%20dangerous,Vinit%20and%20LT%20Vfin%20respectively.) in AAVE v2 in 2022, and subsequently was [used to hack](https://0vixprotocol.medium.com/0vix-exploit-post-mortem-15c882dcf479) a Compound v2 fork in 2023. 


Currently this repo contains an unmodified Compound v2 fork setup to mimic the behavior of the 2023 0VIX attack. It's a WIP. The file `test/ToxicLiquidationSpiral.t.sol` contains the setup and can be run with `forge test -vv`.


The suit currently runs two tests on the Compound fork:
- A short demonstrating that the setup is working 
- A toxic liquidation spiral attack similar to the 0VIX attack


The testing suit is setup to allow more tests to be added. 
