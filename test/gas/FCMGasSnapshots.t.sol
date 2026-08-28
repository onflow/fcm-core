// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "../utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";

contract FCMGasSnapshotsTest is Test, Deployers {
    using FCMHelpers for FCMVault;

    function setUp() public {
        deployVault();
        vm.startPrank(owner);
        vault.setMaxTvl(100 ether);
        vault.setMaxSlippageBps(100);
        vm.stopPrank();
        grantFundApprove(alice, 1 ether);
        vm.startPrank(alice);
    }

    function test_gas_deposit() public {
        vault.deposit(1 ether, alice);
    }

    function test_gas_harvest() public {
        vm.pauseGasMetering();
        vault.deposit(1 ether, alice);
        setYieldPrice(YIELD_PRICE * 2);
        vm.resumeGasMetering();

        vault.harvest(type(uint256).max);
    }

    function test_gas_rebalance() public {
        vm.pauseGasMetering();
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE * 2);
        vm.resumeGasMetering();

        vault.rebalance();
    }

    function test_gas_redeem() public {
        vm.pauseGasMetering();
        uint256 shares = vault.deposit(1 ether, alice);
        vm.resumeGasMetering();

        vault.redeem(shares, alice, alice);
    }
}
