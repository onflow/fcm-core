// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Allowlist} from "../src/access/Allowlist.sol";
import {IAllowlist} from "../src/access/IAllowlist.sol";

contract AllowlistTest is Test {
    Allowlist internal allowlist;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal attacker = address(0xBAD);

    function setUp() public {
        allowlist = new Allowlist(owner);
    }

    function test_NewAddressIsNotAllowed() public view {
        assertFalse(allowlist.isAllowed(alice));
        assertFalse(allowlist.isAllowed(address(0)));
    }

    function test_AllowAddsToList() public {
        vm.prank(owner);
        allowlist.allow(alice);
        assertTrue(allowlist.isAllowed(alice));
    }

    function test_AllowEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(allowlist));
        emit IAllowlist.AddressAllowed(alice);
        vm.prank(owner);
        allowlist.allow(alice);
    }

    function test_DisallowRemovesFromList() public {
        vm.startPrank(owner);
        allowlist.allow(alice);
        allowlist.disallow(alice);
        vm.stopPrank();
        assertFalse(allowlist.isAllowed(alice));
    }

    function test_DisallowEmitsEvent() public {
        vm.prank(owner);
        allowlist.allow(alice);

        vm.expectEmit(true, true, true, true, address(allowlist));
        emit IAllowlist.AddressDisallowed(alice);
        vm.prank(owner);
        allowlist.disallow(alice);
    }

    function test_AllowZeroAddressReverts() public {
        vm.expectRevert(Allowlist.ZeroAddress.selector);
        vm.prank(owner);
        allowlist.allow(address(0));
    }

    function test_DisallowZeroAddressIsNoop() public {
        vm.recordLogs();
        vm.prank(owner);
        allowlist.disallow(address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertFalse(allowlist.isAllowed(address(0)));
    }

    function test_AllowIdempotent_NoEmitOnDuplicate() public {
        vm.prank(owner);
        allowlist.allow(alice);

        vm.recordLogs();
        vm.prank(owner);
        allowlist.allow(alice); // already allowed
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertTrue(allowlist.isAllowed(alice));
    }

    function test_DisallowIdempotent_NoEmitOnAbsent() public {
        vm.recordLogs();
        vm.prank(owner);
        allowlist.disallow(alice); // never added
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertFalse(allowlist.isAllowed(alice));
    }

    function test_AllowBatch() public {
        // Pre-seed one address so the batch contains a mix of new and existing.
        vm.prank(owner);
        allowlist.allow(alice);

        address[] memory batch = new address[](3);
        batch[0] = alice; // already allowed
        batch[1] = bob;
        batch[2] = carol;

        vm.prank(owner);
        allowlist.allowBatch(batch);

        assertTrue(allowlist.isAllowed(alice));
        assertTrue(allowlist.isAllowed(bob));
        assertTrue(allowlist.isAllowed(carol));
    }

    function test_DisallowBatch() public {
        vm.startPrank(owner);
        allowlist.allow(alice);
        allowlist.allow(bob);
        vm.stopPrank();

        address[] memory batch = new address[](3);
        batch[0] = alice;
        batch[1] = bob;
        batch[2] = carol; // never added

        vm.prank(owner);
        allowlist.disallowBatch(batch);

        assertFalse(allowlist.isAllowed(alice));
        assertFalse(allowlist.isAllowed(bob));
        assertFalse(allowlist.isAllowed(carol));
    }

    function test_AllowBatchRevertsOnZeroAddress() public {
        address[] memory batch = new address[](2);
        batch[0] = alice;
        batch[1] = address(0);

        vm.expectRevert(Allowlist.ZeroAddress.selector);
        vm.prank(owner);
        allowlist.allowBatch(batch);
    }
}
