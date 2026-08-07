// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";

import {FCMVault, MORPHO_ADDRESS} from "../src/FCMVault.sol";
import {VaultHelpers} from "../test/utils/FCMVaultHelpers.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";

/// @title Rebalance
/// @notice Drives a LIVE FCMVault's leveraged Morpho position back inside its
///         configured health-factor band, rebalancing to the re-entry target.
///         `rebalance` is permissionless, so any account with FLOW for gas can
///         run this.
///
///         The market oracle (Pyth) must be fresh — push an update with
///         `make mainnet-update-oracle` first, otherwise the oracle read
///         inside `rebalance` reverts with StalePrice.
///
///         Everything is read from the vault itself, so this works against any
///         FCMVault address with no config file. Spends real funds (swap fees
///         + price impact) when it actually rebalances, so dry-run first by
///         dropping --broadcast — the dry-run fork-simulates the exact same
///         sequence for free.
///
///         Env:
///           VAULT  (required) FCMVault address
///
///         Usage (dry-run first by dropping --broadcast):
///           VAULT=0x... forge script script/Rebalance.s.sol \
///             --rpc-url flow_mainnet --broadcast --account "$ACCOUNT"
contract Rebalance is Script {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using VaultHelpers for FCMVault;

    function run() public {
        FCMVault vault = FCMVault(vm.envAddress("VAULT"));

        uint256 hfBefore = _healthFactor(vault);
        uint256 debtBefore = _debt(vault);

        vm.startBroadcast();
        vault.rebalance();
        vm.stopBroadcast();

        uint256 hfAfter = _healthFactor(vault);
        uint256 debtAfter = _debt(vault);

        console.log("=== rebalance complete ===");
        console.log("vault:      %s", address(vault));
        console.log("HF min:     %s", vault.HEALTH_FACTOR_MIN());
        console.log("HF max:     %s", vault.HEALTH_FACTOR_MAX());
        console.log("HF before:  %s", hfBefore);
        console.log("HF after:   %s", hfAfter);
        console.log("debt before: %s", debtBefore);
        console.log("debt after:  %s", debtAfter);
        if (debtAfter == debtBefore) {
            console.log("no-op: HF was inside [min, max]");
        }
    }

    /// @dev Reads the vault's Morpho market params and computes the position's
    ///      health factor the same way the contract does (WAD-scaled). Returns
    ///      `type(uint256).max` when there is no debt.
    function _healthFactor(FCMVault vault) internal view returns (uint256) {
        MarketParams memory mp = vault.getMarket();
        Position memory pos = IMorpho(MORPHO_ADDRESS).position(mp.id(), address(vault));
        if (pos.borrowShares == 0) return type(uint256).max;
        uint256 debt = _debtFromPosition(mp, pos);
        uint256 maxBorrow = (uint256(pos.collateral) * ((IOracle(mp.oracle).price() * mp.lltv) / 1e36)) / 1e18;
        return (maxBorrow * 1e18) / debt;
    }

    /// @dev The vault's outstanding debt in loan-token units.
    function _debt(FCMVault vault) internal view returns (uint256) {
        MarketParams memory mp = vault.getMarket();
        Position memory pos = IMorpho(MORPHO_ADDRESS).position(mp.id(), address(vault));
        if (pos.borrowShares == 0) return 0;
        return _debtFromPosition(mp, pos);
    }

    /// @dev Converts borrow shares to loan-token debt with Morpho's own
    ///      `SharesMathLib.toAssetsUp`, matching how Morpho charges debt (and
    ///      the contract's `MarketLib.debt`).
    function _debtFromPosition(MarketParams memory mp, Position memory pos) internal view returns (uint256) {
        Market memory mkt = IMorpho(MORPHO_ADDRESS).market(mp.id());
        return uint256(pos.borrowShares).toAssetsUp(uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));
    }
}
