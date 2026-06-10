// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FCMVault} from "../src/FCMVault.sol";

/// @title LiveCheck
/// @notice End-to-end integration check against a LIVE FCMVault deployment:
///         deposit a small amount of the underlying asset, verify shares and
///         NAV accounting, redeem everything, and verify the round-trip
///         value. Spends real funds (swap fees + price impact), so dry-run
///         first by dropping --broadcast -- the dry-run fork-simulates the
///         exact same sequence for free.
///
///         Everything is read from the vault itself, so this works against
///         any FCMVault address with no config file.
///
///         The broadcaster must hold CHECK_AMOUNT of the vault asset, have
///         EARLY_ACCESS_ROLE, and have FLOW for gas.
///
///         Env:
///           VAULT              (required) FCMVault address
///           CHECK_AMOUNT       asset base units to deposit (default 0.01e18)
///           MIN_ROUNDTRIP_BPS  minimum acceptable redeem/deposit ratio in
///                              basis points (default 9700 = 3% tolerance for
///                              swap fees and price impact)
///
///         Usage:
///           VAULT=0x... forge script script/LiveCheck.s.sol \
///             --rpc-url flow_mainnet --broadcast --slow --private-key $PRIVATE_KEY
contract LiveCheck is Script {
    function run() public {
        FCMVault vault = FCMVault(vm.envAddress("VAULT"));
        uint256 amount = vm.envOr("CHECK_AMOUNT", uint256(0.01e18));
        uint256 minRoundtripBps = vm.envOr("MIN_ROUNDTRIP_BPS", uint256(9700));
        IERC20 assetToken = IERC20(vault.asset());

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();

        // Pre-flight: fail with a clear reason before any value moves.
        require(
            vault.hasRole(vault.EARLY_ACCESS_ROLE(), caller),
            "caller lacks EARLY_ACCESS_ROLE on the vault"
        );
        require(
            assetToken.balanceOf(caller) >= amount,
            "caller does not hold CHECK_AMOUNT of the vault asset"
        );
        require(
            vault.maxDeposit(caller) >= amount, "TVL headroom below CHECK_AMOUNT (is maxTvl set?)"
        );

        uint256 assetBefore = assetToken.balanceOf(caller);
        uint256 sharesBefore = vault.balanceOf(caller);
        uint256 navBefore = vault.totalAssets();

        // Deposit.
        assetToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, caller);
        require(shares > 0, "deposit minted zero shares");
        require(
            vault.balanceOf(caller) == sharesBefore + shares,
            "share balance does not reflect minted shares"
        );
        require(vault.totalAssets() > navBefore, "vault NAV did not grow on deposit");

        // Redeem everything we just minted.
        uint256 redeemed = vault.redeem(shares, caller, caller);
        vm.stopBroadcast();

        require(vault.balanceOf(caller) == sharesBefore, "shares were not fully burned");
        require(
            assetToken.balanceOf(caller) == assetBefore - amount + redeemed,
            "asset balance delta does not match redeem output"
        );
        uint256 roundtripBps = redeemed * 10_000 / amount;
        require(
            roundtripBps >= minRoundtripBps, "round-trip value below MIN_ROUNDTRIP_BPS tolerance"
        );

        console.log("=== live check passed ===");
        console.log("deposited:  %s", amount);
        console.log("shares:     %s", shares);
        console.log("redeemed:   %s", redeemed);
        console.log("round-trip: %s bps", roundtripBps);
    }
}
