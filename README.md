# Toxic Liquidation Spiral Exploration

The purpose of this repo is to provide code demonstrating and exploring different aspects of Toxic Liquidation Spirals. It is a WIP.


Toxic Liquidation Spirals can occur in DeFi projects which utilize loan-to-value ratio based account liquidations. 
The intent of liquidating an account is to improve the account's health by lowering the loan-to-value ratio, but, under certain conditions, the process of liquidation can actually make an account's health worse.
This was [first observed](https://arxiv.org/pdf/2212.07306.pdf#:~:text=3%20Toxic%20Liquidation%20Spirals&text=Toxic%20liquida%2D%20tions%20are%20dangerous,Vinit%20and%20LT%20Vfin%20respectively.) in AAVE v2 in 2022, and subsequently was [used to hack](https://0vixprotocol.medium.com/0vix-exploit-post-mortem-15c882dcf479) a Compound v2 fork in 2023. 


Currently this repo contains an unmodified Compound v2 fork setup to mimic the behavior of the 2023 0VIX attack. It's a WIP. The file `test/ToxicLiquidationSpiral.t.sol` contains the setup and can be run with `forge test -vv`.


The suite currently runs three tests on the Compound fork:
- A short example demonstrating that the setup is working 
- A hardcoded toxic liquidation spiral attack similar to the 0VIX attack
- An example of a fuzzing test which shows the effects of changing the liquidation incentive on the protocol on the total percentage of funds stolen


Results for tests ran with the 'findToxicLTVExternalLosses()' function export the test results to a CSV file that can be opened with Google Sheets or Excel for further analysis. The idea is that you'd run a fuzzer and see the range of behaviors (is a WIP). A clean data header can be found at `dataHeaderNoData.csv` and the expected output filename is `dataBank.csv`. The script used to move the data is called `add_data_script.sh` and assumes a unix-like machine. Window users will have to modify. 


The testing suite is setup to allow more tests to be added and more will be added as I have the time to work on this. 
