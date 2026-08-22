// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

contract FCMMaxSlippageTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();
    }

    function test_maxSlippage_defaultIsZero() public view {
        assertEq(vault.maxSlippageBps(), 0);
    }

    function test_maxSlippage_revertsWhenNotOwner() public {
        vm.expectRevert(Errors.ownableUnauthorizedAccount(alice));
        vm.prank(alice);
        vault.setMaxSlippageBps(250);
    }

    function test_maxSlippage_ownerUpdatesBps() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(250);
        assertEq(vault.maxSlippageBps(), 250);
    }

    function test_maxSlippage_revertsOnInvalidSlippage() public {
        vm.expectRevert(Errors.invalidSlippage());
        vm.prank(owner);
        vault.setMaxSlippageBps(1001);
    }
}
