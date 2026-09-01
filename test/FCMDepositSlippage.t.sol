// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

contract FCMDepositSlippageTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    uint256 internal fairShares;

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);
        grantFundApprove(alice, 3 ether);

        vm.prank(alice);
        fairShares = vault.deposit(1 ether, alice);
    }

    function test_depositSlippage_succeedsWithExactMinSharesOut() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice, fairShares);
        assertEq(shares, fairShares);
    }

    function test_depositSlippage_revertsWhenMinSharesOutExceeded() public {
        vm.expectRevert(Errors.slippageExceeded(fairShares, fairShares + 1));
        vm.prank(alice);
        vault.deposit(1 ether, alice, fairShares + 1);
    }

    function test_depositSlippage_zeroMinSharesOutSucceeds() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice, 0);
    }
}
