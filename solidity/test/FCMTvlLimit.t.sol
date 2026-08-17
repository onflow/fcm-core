// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FCMVault} from "../src/FCMVault.sol";
import {Deployers} from "./utils/Deployers.sol";
import {VaultHelpers} from "./utils/FCMVaultHelpers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests for the TVL limit on FCMVault.
contract TvlLimitTest is Test, Deployers {
    using VaultHelpers for FCMVault;

    // Mirror the contract's event so we can use vm.expectEmit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    bytes errorBobUnauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(bob));

    function setUp() public {
        deployVault();
        vault.grantFundApprove(alice, 1 ether);
    }

    function test_DefaultZero() public view {
        assertEq(vault.maxTvl(), 0, "maxTvl should default to 0");
    }

    function test_DepositRevertsAtZero() public {
        vm.prank(alice);
        vm.expectRevert(_errorMaxDepositExceeded(alice, 1));
        vault.deposit(1, alice);
    }

    function test_OnlyOwnerCanSetMaxTvl() public {
        vm.prank(bob);
        vm.expectRevert(errorBobUnauthorized);
        vault.setMaxTvl(1000);
    }

    function test_RaiseAndLower() public {
        vm.startPrank(owner);
        vault.setMaxTvl(1000);
        vault.setMaxTvl(0);
    }

    function test_EmitsEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MaxTvlSet(0, 1000);
        vault.setMaxTvl(1000);

        vm.expectEmit(true, true, true, true, address(vault));
        emit MaxTvlSet(1000, 500);
        vault.setMaxTvl(500);
    }

    function _errorMaxDepositExceeded(address receiver, uint256 assets) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            ERC4626.ERC4626ExceededMaxDeposit.selector, receiver, assets, vault.maxDeposit(receiver)
        );
    }
}
