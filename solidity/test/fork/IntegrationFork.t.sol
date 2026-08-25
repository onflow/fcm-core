// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {ForkDeployers} from "./ForkDeployers.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {console} from "forge-std/console.sol";

contract IntegrationForkTest is ForkDeployers {
    uint256 constant N_USERS = 100;
    uint256 constant DEPOSIT_AMOUNT = 0.1e8;
    uint256 constant MAX_REBALANCE_ITERATIONS = 500;

    address[] internal users;

    function setUp() public {
        _forkSetup();
        _fundArb();
        _depositUsers(N_USERS, DEPOSIT_AMOUNT);

        users = new address[](N_USERS);
        for (uint256 i = 0; i < N_USERS; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
        }

        console.log("=== Integration fork test setup ===");
        console.log("Collateral oracle price:", ORACLE_PRICE);
        console.log("Yield oracle price:", IOracle(YIELD_ORACLE).price());
        console.log("Pool spot (clean):", uint256(cleanSpot));
        console.log("Pool liquidity:", uint256(IUniswapV3Pool(YIELD_LOAN_POOL).liquidity()));
        console.log("---");
        _arbPoolToSpot();
    }

    function test_integration_fullLifecycleRealistic() public {
        vm.startPrank(address(0x1337));
        deal(address(WBTC), address(0x1337), 1e18);
        WBTC.approve(address(MORPHO), type(uint256).max);
        MORPHO.supplyCollateral(mp, 1e18, address(0x1337), "");
        vm.stopPrank();

        uint256 tvlAfterDeposits = _tvlUsd();
        console.log("TVL after all deposits ($):", tvlAfterDeposits / 1e6);
        assertGt(tvlAfterDeposits, 0, "TVL > 0 after deposits");

        (uint256 itersUp, uint256 hfUp) = _shockPriceAndRebalanceUntilOk(ORACLE_PRICE * 110 / 100);
        console.log("Lever rebalance: iterations =", itersUp, "| HF final =", hfUp / 1e15);
        assertGe(hfUp, HEALTH_FACTOR_MIN, "HF >= min after +10% shock rebalanced");

        (uint256 itersDown, uint256 hfDown) = _shockPriceAndRebalanceUntilOk(ORACLE_PRICE * 90 / 100);
        console.log("Delever rebalance: iterations =", itersDown, "| HF final =", hfDown / 1e15);
        assertGe(hfDown, HEALTH_FACTOR_MIN, "HF >= min after -10% shock rebalanced");

        setCollateralPrice(ORACLE_PRICE);
        uint256 totalReturned = _withdrawAllUsersSlowly();
        console.log("Total WBTC returned to users (sats):", totalReturned);
        console.log("Total WBTC deposited (sats):", DEPOSIT_AMOUNT * N_USERS);

        assertEq(vault.totalSupply(), 0, "all shares burned");
        assertApproxEqRel(totalReturned, DEPOSIT_AMOUNT * N_USERS, 0.6e18, "users recovered ~their principal");
    }

    function test_integration_earlyExitDoesNotLockFunds() public {
        address u = users[0];
        uint256 shares = vault.balanceOf(u);

        vm.prank(u);
        uint256 assetsOut = vault.redeem(shares, u, u);
        assertGt(assetsOut, 0, "early exit returns assets");

        _arbPoolToSpot();
    }

    function _shockPriceAndRebalanceUntilOk(uint256 newPrice) internal returns (uint256 iterations, uint256 hfFinal) {
        setCollateralPrice(newPrice);
        hfFinal = _hf();
        console.log("HF right after price shock:", hfFinal / 1e15);

        for (uint256 i = 0; i < MAX_REBALANCE_ITERATIONS; i++) {
            if (hfFinal >= HEALTH_FACTOR_MIN && hfFinal <= HEALTH_FACTOR_MAX) break;
            vault.rebalance();
            _arbPoolToSpot();
            hfFinal = _hf();
            iterations = i + 1;
        }
    }

    function _withdrawAllUsersSlowly() internal returns (uint256 totalReturned) {
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = users[i];
            uint256 shares = vault.balanceOf(u);
            if (shares == 0) continue;

            vm.prank(u);
            uint256 assetsOut = vault.redeem(shares, u, u);
            totalReturned += assetsOut;

            _arbPoolToSpot();
        }
        console.log("All", N_USERS, "withdrawals done. HF =", _hf() / 1e15);
    }
}
