// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMMaxRedeemTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(100 ether);
        vault.grantFundApprove(alice, 1 ether);
        vault.grantFundApprove(bob, 1 ether);
    }

    function test_maxRedeem_zeroWhenActiveEmergencyRecovery() public {
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_zeroWhenNoBalance() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_returnsBalanceWhenHealthy() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_maxRedeem_zeroWhenHealthFactorAboveMax() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        assertGt(shares, 0);

        setCollateralPrice(COLLATERAL_PRICE * 3); // HF well above MAX
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MAX);

        assertEq(vault.maxRedeem(alice), 0);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_maxRedeem_perOwnerIndependence() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1 ether, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(0.5 ether, bob);

        assertEq(vault.maxRedeem(alice), aliceShares);
        assertEq(vault.maxRedeem(bob), bobShares);
        assertEq(vault.maxRedeem(stranger), 0);
    }

    // ERC4626 consistency gap: `redeem()` does NOT enforce `maxRedeem` /
    // `ERC4626ExceededMaxRedeem` — its only HF gate is `>= HEALTH_FACTOR_MIN`. So when
    // `hf > HEALTH_FACTOR_MAX` but `hf >= HEALTH_FACTOR_MIN`, `maxRedeem` reports 0
    // yet `redeem()` still succeeds. This pins that divergence.
    function test_maxRedeem_reportsZeroButRedeemStillSucceeds() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE * 3); // HF above MAX (> MIN too)
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MAX);
        assertEq(vault.maxRedeem(alice), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0);
    }
}
