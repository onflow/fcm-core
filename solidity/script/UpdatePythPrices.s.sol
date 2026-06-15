// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IPyth {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

interface IOracle {
    function price() external view returns (uint256);
}

/// @title UpdatePythPrices
/// @notice Fetches fresh FLOW, ETH, and BTC prices from Hermes and pushes them to Pyth on Flow EVM.
/// @dev Requires `curl` and Foundry's `--ffi` flag.
contract UpdatePythPrices is Script {
    uint256 internal constant FLOW_MAINNET_CHAIN_ID = 747;

    IPyth internal constant PYTH = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43);

    string internal constant HERMES_URL =
        "https://hermes.pyth.network/v2/updates/price/latest?encoding=hex";
    string internal constant FLOW_ID =
        "2fb245b9a84554a0f15aa123cbb5f64cd263b59e9a87d80148cbffab50c69f30";
    string internal constant ETH_ID =
        "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
    string internal constant BTC_ID =
        "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";

    address internal constant WFLOW_PYUSD_ORACLE = 0xd8848Ccc8beA82046Da0B144844118db17086af4;
    address internal constant WETH_PYUSD_ORACLE = 0xD744044044C0Dd0c73BeA440747115674Ebae030;
    address internal constant WBTC_PYUSD_ORACLE = 0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8;

    function run() public {
        require(block.chainid == FLOW_MAINNET_CHAIN_ID, "expected Flow EVM mainnet");

        (bytes memory updateData, uint256 publishTime) = _fetchUpdateData();
        bytes[] memory updates = new bytes[](1);
        updates[0] = updateData;

        uint256 fee = PYTH.getUpdateFee(updates);
        console.log("Hermes update bytes:", updateData.length);
        console.log("Hermes publish time:", publishTime);
        console.log("Pyth update fee (wei):", fee);

        vm.startBroadcast();
        PYTH.updatePriceFeeds{value: fee}(updates);
        vm.stopBroadcast();

        console.log("Oracle prices after simulated update:");
        _logPrice("WFLOW/PYUSD:", WFLOW_PYUSD_ORACLE);
        _logPrice("WETH/PYUSD:", WETH_PYUSD_ORACLE);
        _logPrice("WBTC/PYUSD:", WBTC_PYUSD_ORACLE);
    }

    function _fetchUpdateData() internal returns (bytes memory updateData, uint256 publishTime) {
        string[] memory command = new string[](5);
        command[0] = "curl";
        command[1] = "-fsSL";
        command[2] = "--max-time";
        command[3] = "30";
        command[4] =
            string.concat(HERMES_URL, "&ids[]=", FLOW_ID, "&ids[]=", ETH_ID, "&ids[]=", BTC_ID);

        string memory response = string(vm.ffi(command));
        string memory updateDataHex = vm.parseJsonString(response, ".binary.data[0]");
        require(bytes(updateDataHex).length > 0, "Hermes returned empty update data");

        updateData = vm.parseBytes(string.concat("0x", updateDataHex));
        publishTime = vm.parseJsonUint(response, ".parsed[0].price.publish_time");
    }

    function _logPrice(string memory label, address oracle) internal view {
        try IOracle(oracle).price() returns (uint256 oraclePrice) {
            console.log(label, oraclePrice);
        } catch {
            console.log(string.concat(label, " FAILED"));
        }
    }
}
