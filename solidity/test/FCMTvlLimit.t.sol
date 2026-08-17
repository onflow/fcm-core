// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests for the TVL limit on FCMVault.
contract FCMTvlLimitTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    // Mirror the contract's event so we can use vm.expectEmit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    bytes errorBobUnauthorized = Errors.ownableUnauthorizedAccount(address(bob));

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
    }

    function test_tvlLimit_defaultsToZero() public view {
        assertEq(vault.maxTvl(), 0);
    }

    function test_tvlLimit_depositRevertsAtZero() public {
        vm.prank(alice);
        vm.expectRevert(_errorMaxDepositExceeded(alice, 1));
        vault.deposit(1, alice);
    }

    function test_tvlLimit_onlyOwnerCanSetMaxTvl() public {
        vm.prank(bob);
        vm.expectRevert(errorBobUnauthorized);
        vault.setMaxTvl(1000);
    }

    function test_tvlLimit_raiseAndLower() public {
        vm.startPrank(owner);
        vault.setMaxTvl(1000);
        vault.setMaxTvl(0);
    }

    function test_tvlLimit_emitsMaxTvlSetEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MaxTvlSet(0, 1000);
        vault.setMaxTvl(1000);

        vm.expectEmit(true, true, true, true, address(vault));
        emit MaxTvlSet(1000, 500);
        vault.setMaxTvl(500);
    }

    function _errorMaxDepositExceeded(address receiver, uint256 assets) internal view returns (bytes memory) {
        return Errors.erc4626ExceededMaxDeposit(receiver, assets, vault.maxDeposit(receiver));
    }
}
