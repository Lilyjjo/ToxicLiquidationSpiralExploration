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
contract ExportDataUtil is Test {
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
        data = concatUint256(data, configVars.targetTLTV, false);
        data = concatUint256(data, configVars.liquidationIncentive, true);
        data = concatUint256(data, configVars.closeFactor, true);
        data = concatUint256(data, configVars.uscdCollateralFactor, true);
        data = concatUint256(data, configVars.borrowCollateralFactor, true);
        data = concatUint256(data, configVars.usdcPrice, true);
        data = concatUint256(data, configVars.borrowTokenStartPrice, true);
        data = concatUint256(data, configVars.startUSDCAmountTarget, true);
        data = concatUint256(data, configVars.startUSDCAmountAttacker, true);
        data = concatUint256(data, configVars.startUSDCAmountWhale, true);
        data = concatUint256(data, configVars.startBorrowAmountWhale, true);
        data = concatInt256(data, resultVars.gainsTarget, true);
        data = concatInt256(data, resultVars.gainsAttacker, true);
        data = concatInt256(data, resultVars.gainsWhaleUSDC, true);
        data = concatInt256(data, resultVars.gainsWhaleBorrow, true);
        data = concatUint256(data, resultVars.borrowTokenToxicPrice, true);
        data = concatUint256(data, resultVars.liquidationLoops, true);
    }

    /**
     * @notice Appends a piece of int data to a string
     * @param data The string to append the data to
     * @param additionalData The new data to add to the string
     * @param appendComma If a comma should be appended to the front of the new data
     */
    function concatInt256(
        string memory data,
        int additionalData,
        bool appendComma
    ) internal pure returns (string memory result) {
        string memory additionalDataString;
        if (additionalData < 0) {
            additionalDataString = string.concat(
                "-",
                Strings.toString(uint(additionalData * -1))
            );
        } else {
            additionalDataString = Strings.toString(uint(additionalData));
        }
        if (appendComma) {
            result = ",";
        }
        result = string.concat(result, additionalDataString);
        result = string.concat(data, result);
    }

    /**
     * @notice Appends a piece of uint data to a string
     * @param data The string to append the data to
     * @param additionalData The new data to add to the string
     * @param appendComma If a comma should be appended to the front of the new data
     */
    function concatUint256(
        string memory data,
        uint additionalData,
        bool appendComma
    ) internal pure returns (string memory result) {
        if (appendComma) {
            result = ",";
        }
        result = string.concat(result, Strings.toString(additionalData));
        result = string.concat(data, result);
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
