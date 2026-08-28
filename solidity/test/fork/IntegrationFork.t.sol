// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {ForkDeployers} from "./ForkDeployers.sol";
import {console} from "forge-std/console.sol";

contract IntegrationForkTest is ForkDeployers {
    using FCMHelpers for FCMVault;
    uint256 constant N_USERS = 100;
    uint256 constant DEPOSIT_AMOUNT = 0.1e8;
    uint256 constant MAX_REBALANCE_ITERATIONS = 500;

    address[] internal users;

    function setUp() public {
        setupFork();
        depositUsers(N_USERS, DEPOSIT_AMOUNT);

        users = new address[](N_USERS);
        for (uint256 i = 0; i < N_USERS; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
        }
    }

    function test_integration_fullLifecycleRealistic() public {
        (uint256 itersUp, uint256 ltvUp) = _shockPriceAndRebalanceUntilOk(COLLATERAL_PRICE * 110 / 100);
        console.log("Lever rebalance: iterations =", itersUp, "| LTV final =", ltvUp / 1e15);
        assertLe(ltvUp, LTV_MAX, "LTV <= max after +10% shock rebalanced");

        (uint256 itersDown, uint256 ltvDown) = _shockPriceAndRebalanceUntilOk(COLLATERAL_PRICE * 90 / 100);
        console.log("Delever rebalance: iterations =", itersDown, "| LTV final =", ltvDown / 1e15);
        assertLe(ltvDown, LTV_MAX, "LTV <= max after -10% shock rebalanced");

        setCollateralPrice(COLLATERAL_PRICE);
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
    }

    function _shockPriceAndRebalanceUntilOk(uint256 newPrice) internal returns (uint256 iterations, uint256 ltvFinal) {
        setCollateralPrice(newPrice);
        ltvFinal = vault.ltv();
        console.log("LTV right after price shock:", ltvFinal / 1e15);

        for (uint256 i = 0; i < MAX_REBALANCE_ITERATIONS; i++) {
            if (ltvFinal >= LTV_MIN && ltvFinal <= LTV_MAX) break;
            vault.rebalance();
            arbPoolToSpot();
            ltvFinal = vault.ltv();
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

            arbPoolToSpot();
        }
        console.log("All", N_USERS, "withdrawals done. HF =", vault.ltv() / 1e15);
    }
}
