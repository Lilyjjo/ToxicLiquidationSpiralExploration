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
    function exportDataRow(
        SpiralConfigurationVariables memory configVars,
        SpiralResultVariables memory resultVars
    ) public {
        string memory data = "";
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

        string[] memory inputs = new string[](2);
        inputs[0] = "./add_data_script.sh";
        inputs[1] = data;
        vm.ffi(inputs);
    }
}
