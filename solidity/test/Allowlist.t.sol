// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
}
