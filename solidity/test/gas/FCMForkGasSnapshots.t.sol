// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ForkDeployers} from "../fork/ForkDeployers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FCMForkGasSnapshotsTest is ForkDeployers {
    using Math for uint256;

    function setUp() public {
        setupFork();
        depositUsers(1, 1e8);
        grantFundApprove(alice, type(uint256).max);
    }

    function test_gasFork_deposit() public {
        vm.pauseGasMetering();
        vm.prank(alice);
        vm.resumeGasMetering();

        vault.deposit(1e6, alice);
    }

    function test_gasFork_harvest() public {
        vm.pauseGasMetering();
        vm.prank(alice);
        vault.deposit(1e8, alice);
        setYieldPrice(YIELD_PRICE * 2);
        vm.prank(alice);
        vm.resumeGasMetering();

        vault.harvest(type(uint256).max);
    }

    function test_gasFork_rebalance() public {
        vm.pauseGasMetering();
        vm.prank(alice);
        vault.deposit(1e8, alice);
        setCollateralPrice(COLLATERAL_PRICE * 2);
        vm.prank(alice);
        vm.resumeGasMetering();

        vault.rebalance();
    }

    function test_gasFork_redeem() public {
        vm.pauseGasMetering();
        vm.prank(alice);
        uint256 shares = vault.deposit(1e6, alice);
        setYieldPrice(YIELD_PRICE.mulDiv(102, 100));
        vm.prank(alice);
        vm.resumeGasMetering();

        vault.redeem(shares, alice, alice);
    }
}



// import {ForkDeployers} from "../fork/ForkDeployers.sol";

// contract FCMForkGasSnapshotsTest is ForkDeployers {
//     function setUp() public {
//         setupFork();
//         // _forkSetup();
//         // _fundArb();
//         // _depositUsers(1, 1e8);
//         // vm.prank(arb);
//         // WBTC.approve(address(vault), type(uint256).max);
//         // vm.startPrank(arb);
//     }

//     function test_gasFork_deposit() public {
//         vault.deposit(1e8, arb);
//     }

//     function test_gasFork_harvest() public {
//         vm.pauseGasMetering();
//         vault.deposit(1e8, arb);
//         setYieldPrice(YIELD_ORACLE_PRICE * 2);
//         vm.resumeGasMetering();

//         vault.harvest(type(uint256).max);
//     }

//     function test_gasFork_rebalance() public {
//         vm.pauseGasMetering();
//         vault.deposit(1e8, arb);
//         setCollateralPrice(ORACLE_PRICE * 2);
//         vm.resumeGasMetering();

//         vault.rebalance();
//     }

//     function test_gasFork_redeem() public {
//         vm.pauseGasMetering();
//         uint256 shares = vault.deposit(1e8, arb);
//         vm.resumeGasMetering();

//         vault.redeem(shares, arb, arb);
//     }
// }
