// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MORPHO} from "../src/FCMVault.sol";
import {ConfiguredScript} from "./ConfiguredScript.s.sol";

/// @title SeedMarket
/// @notice Supplies loan-token liquidity to the Morpho market so the vault
///         has something to borrow. The market must already exist (it does on
///         Flow EVM mainnet, but unseeded). The broadcaster must hold
///         `SEED_AMOUNT` of the loan token.
///
///         The supplied position belongs to the broadcaster and earns
///         interest from the vault's borrowing; it can be withdrawn later
///         with `morpho.withdraw` (subject to utilization).
///
///         Usage (dry-run first by dropping --broadcast):
///           SEED_AMOUNT=<loan token base units> \
///           forge script script/SeedMarket.s.sol --rpc-url flow_mainnet \
///             --broadcast --account "$ACCOUNT"
contract SeedMarket is ConfiguredScript {
    function run() public {
        Config memory c = _loadConfig();
        _requireMarketExists(c);

        uint256 amount = vm.envUint("SEED_AMOUNT");
        require(amount > 0, "SEED_AMOUNT must be > 0 (loan token base units)");

        vm.startBroadcast();
        address supplier = _broadcaster();
        require(
            IERC20(c.loanToken).balanceOf(supplier) >= amount,
            "broadcaster holds less loan token than SEED_AMOUNT"
        );

        IERC20(c.loanToken).approve(address(MORPHO), amount);
        (uint256 supplied,) = MORPHO.supply(_marketParams(c), amount, 0, supplier, "");
        vm.stopBroadcast();

        console.log("supplied %s loan token to market on behalf of %s", supplied, supplier);
    }
}
