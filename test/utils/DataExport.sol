// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";

import "./TLSStructs.sol";

/**
 * @title ExportData
 * @author Lilyjjo
 * @notice Contract to hold logic for printing out a row of test data to a file
 */
contract ExportData is Test {
    /**
     * @notice Turns Toxic Liquidation Spiral config and result structs
     * into a string of comma separated data, can be used in .CSV files
     * @param configVars The configuration variables TLS test was run with
     * @param resultVars The resulting state after the test compeletes
     */
    function createTLSDataString(
        SpiralConfigurationVariables memory configVars,
        SpiralResultVariables memory resultVars
    ) internal pure returns (string memory data) {
        data = string.concat(data, Strings.toString(configVars.targetTLTV));
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.liquidationIncentive)
        );
        data = string.concat(data, ",");
        data = string.concat(data, Strings.toString(configVars.closeFactor));
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.uscdCollateralFactor)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.borrowCollateralFactor)
        );
        data = string.concat(data, ",");
        data = string.concat(data, Strings.toString(configVars.usdcPrice));
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.borrowTokenStartPrice)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.startUSDCAmountTarget)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.startUSDCAmountAttacker)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.startUSDCAmountWhale)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(configVars.startBorrowAmountWhale)
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(uint(resultVars.gainsTarget * -1))
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(uint(resultVars.gainsAttacker))
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(uint(resultVars.gainsWhaleUSDC))
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(uint(resultVars.gainsWhaleBorrow * -1))
        );
        data = string.concat(data, ",");
        data = string.concat(
            data,
            Strings.toString(resultVars.borrowTokenToxicPrice)
        );
    }

    /**
     * @notice Attempts to append a string to a file
     * @param filename The name of the file
     * @param data The string of data to append to the file
     */
    function exportString(string memory filename, string memory data) internal {
        string[] memory inputs = new string[](3);
        inputs[0] = "./add_data_script.sh";
        inputs[1] = data;
        inputs[2] = filename;
        vm.ffi(inputs);
    }

    /**
     * @notice Exports a row of Toxic Liquidity Spiral data to a file
     * @param fileName The name of the file to append the data to
     * @param configVars The configuration variables TLS test was run with
     * @param resultVars The resulting state after the test compeletes
     */
    function exportTLSData(
        string memory fileName,
        SpiralConfigurationVariables memory configVars,
        SpiralResultVariables memory resultVars
    ) public {
        string memory data = createTLSDataString(configVars, resultVars);
        exportString(fileName, data);
    }
}
