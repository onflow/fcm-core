// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ForkDeployers} from "../fork/ForkDeployers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FCMForkGasSnapshotsTest is ForkDeployers {
    using Math for uint256;

    function setUp() public {
        _forkSetup();
        _fundArb();
        _depositUsers(1, 1e8);
        vm.prank(arb);
        WBTC.approve(address(vault), type(uint256).max);
        vm.startPrank(arb);
    }

    function test_gasFork_deposit() public {
        vault.deposit(1e6, arb);
    }

    function test_gasFork_harvest() public {
        vm.pauseGasMetering();
        vault.deposit(1e8, arb);
        setYieldPrice(YIELD_ORACLE_PRICE * 2);
        vm.resumeGasMetering();

        vault.harvest(type(uint256).max);
    }

    function test_gasFork_rebalance() public {
        vm.pauseGasMetering();
        vault.deposit(1e8, arb);
        setCollateralPrice(ORACLE_PRICE * 2);
        vm.resumeGasMetering();

        vault.rebalance();
    }

    function test_gasFork_redeem() public {
        vm.pauseGasMetering();
        uint256 shares = vault.deposit(1e6, arb);
        setYieldPrice(YIELD_ORACLE_PRICE.mulDiv(102, 100));
        vm.resumeGasMetering();

        vault.redeem(shares, arb, arb);
    }
}
