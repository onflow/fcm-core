// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract FCMRebalanceTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;
    bytes errorEmergencyRecoveryActive = Errors.emergencyRecoveryActive();

    function setUp() public {
        deployVault();
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
        vm.prank(owner);
        vault.setMaxTvl(1000 ether);
        grantFundApprove(alice, 1 ether);
    }

    function test_rebalance_noopInsideBand() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));

        vault.rebalance();
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(101, 100));
        vault.rebalance();
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(99, 100));
        vault.rebalance();
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_leversWhenAboveMax() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        assertLt(vault.ltv(), LTV_MIN);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        vault.rebalance();
        assertGe(vault.ltv(), LTV_MIN);
        assertGt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_deleversWhenBelowMin() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(50, 100));
        assertGt(vault.ltv(), LTV_MAX);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        vault.rebalance();
        assertLe(vault.ltv(), LTV_MAX);
        assertLt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_noIdleLoanToken() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 0);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        vault.rebalance();
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 0);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(50, 100));
        vault.rebalance();
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 0);
    }

    function test_rebalance_leverSkipsWhenSpotPastBound() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));

        setCollateralPrice(COLLATERAL_PRICE * 2);
        setYieldPoolPrice(YIELD_PRICE.mulDiv(100_000, 99_000));
        vault.rebalance();

        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);

        setYieldPoolPrice(YIELD_PRICE.mulDiv(100_000, 99_001));
        vault.rebalance();

        assertGt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_deleverSkipsWhenSpotPastBound() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));

        setCollateralPrice(COLLATERAL_PRICE / 2);
        setYieldPoolPrice(YIELD_PRICE.mulDiv(98_999, 100_000));
        vault.rebalance();

        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);

        setYieldPoolPrice(YIELD_PRICE.mulDiv(99_000, 100_000));
        vault.rebalance();

        assertLt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_leverUpGreatPrice() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));

        setCollateralPrice(COLLATERAL_PRICE * 2);
        setYieldPoolPrice(YIELD_PRICE.mulDiv(1, 500));
        vault.rebalance();

        assertGt(YIELD_TOKEN.balanceOf(address(vault)), originalYield * 100);
        assertEq(LOAN_TOKEN.balanceOf(address(vault)), 0);
    }

    function test_rebalance_deleverGreatPrice() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));

        setCollateralPrice(COLLATERAL_PRICE / 2);
        setYieldPoolPrice(YIELD_PRICE.mulDiv(5000, 1));
        vault.rebalance();

        assertLt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
        assertEq(vault.ltv(), LTV_MAX);
    }

    function testFuzz_rebalance_leverPartialFill(uint16 slippageBps) public {
        slippageBps = uint16(bound(slippageBps, 1, 1000));
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 originalDebt = vault.debt();

        vm.prank(owner);
        vault.setMaxSlippageBps(slippageBps);
        setCollateralPrice(COLLATERAL_PRICE * 2);
        setYieldLoanPoolPriceImpact(1e6, 1e6);

        vault.rebalance();
        uint256 yieldBought = YIELD_TOKEN.balanceOf(address(vault)) - originalYield;
        uint256 newDebt = vault.debt() - originalDebt;
        uint256 price = yieldBought.mulDiv(1e36, newDebt);
        assertGe(price, uint256(10_000 - slippageBps) * 1e36 / 1e4);
        assertLe(price, YIELD_PRICE);
    }

    function testFuzz_rebalance_deleverPartialFill(uint16 slippageBps) public {
        slippageBps = uint16(bound(slippageBps, 1, 1000));
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        uint256 originalDebt = vault.debt();

        vm.prank(owner);
        vault.setMaxSlippageBps(slippageBps);
        setCollateralPrice(COLLATERAL_PRICE / 2);
        setYieldLoanPoolPriceImpact(1e6, 1e6);

        vault.rebalance();
        uint256 yieldSold = originalYield - YIELD_TOKEN.balanceOf(address(vault));
        uint256 newDebt = originalDebt - vault.debt();
        uint256 price = yieldSold.mulDiv(1e36, newDebt);
        assertGe(price, uint256(10_000 - slippageBps) * 1e36 / 1e4);
        assertGe(price, YIELD_PRICE);
    }

    function testFuzz_rebalance_liquidationRecovery(uint256 seizedCollateral, uint256 repaidAssets) public {
        seizedCollateral = uint256(bound(seizedCollateral, 1, 1 ether));
        repaidAssets = uint256(bound(repaidAssets, 1, 1 ether));

        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);

        MORPHO.liquidate(vault.market(), address(vault), seizedCollateral, repaidAssets);

        vault.rebalance();

        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertGe(redeemed, (1 ether - seizedCollateral).mulDiv(999, 1000));
    }

    function test_rebalance_revertsAfterEmergencyRecoveryExecuted() public {
        vm.startPrank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        vault.executeEmergencyRecovery();

        vm.expectRevert(errorEmergencyRecoveryActive);
        vault.rebalance();
    }

    function test_rebalance_skipsLeverUpDuringRecovery() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        COLLATERAL_ORACLE.setPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        uint256 ltvBefore = vault.ltv();
        assertLt(ltvBefore, LTV_MIN);
        vault.rebalance();
        assertEq(vault.ltv(), ltvBefore);
    }

    function test_rebalance_deleversDuringRecovery() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        COLLATERAL_ORACLE.setPrice(1000e36);
        assertGt(vault.ltv(), LTV_MAX);
        vault.rebalance();
        assertLe(vault.ltv(), LTV_MAX);
    }

    function test_rebalance_leverRevertsWhenMorphoMarketIlliquid() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE * 2);

        MORPHO.setBorrowCap(vault.market(), 1);
        vm.expectRevert();
        vault.rebalance();
    }

    function test_rebalance_deleverNeedMoreYieldThanAvailable() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(10, 100));
        setYieldPrice(YIELD_PRICE.mulDiv(10, 100));

        // vault position is completely unhealthy, we lose money restoring it.
        vm.expectRevert();
        vault.rebalance();
    }

    function test_rebalance_noopStillEmitsSnapshot() public {
        setCollateralPrice(2e36);
        setYieldPrice(4e36);

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 snap = vm.snapshotState();
        vault.rebalance();

        uint256 coll = vault.collateral();
        uint256 debt = vault.debt();
        uint256 yieldBal = YIELD_TOKEN.balanceOf(address(vault));
        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(coll, debt, yieldBal, 2e36, 4e36);
        vault.rebalance();
    }

    function test_rebalance_feesAccrue() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        vm.startPrank(owner);
        vault.setManagementFeeBps(100);
        vault.setFeeRecipient(carol);
        vault.grantEarlyAccess(carol);
        vm.warp(block.timestamp + 30 days);

        vault.rebalance();

        uint256 actualFeeShares = vault.balanceOf(carol);
        assertGt(actualFeeShares, 0);
    }

    function test_rebalance_fullLiquidationRecovery() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether, alice);
        MORPHO.liquidate(vault.market(), address(vault), 1 ether, 1000 ether);
        vault.rebalance();

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 0.5 ether, 2);
    }

    function test_rebalance_leverEmitsUpdatedSnapshot() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 debtBeforeLever = vault.debt();
        setCollateralPrice(2300e36); // push LTV below min so rebalance levers

        uint256 snap = vm.snapshotState();
        vault.harvest(type(uint256).max);
        vault.rebalance();

        uint256 coll = vault.collateral();
        uint256 debt = vault.debt();
        uint256 yieldBal = YIELD_TOKEN.balanceOf(address(vault));
        vm.revertToState(snap);

        // Harvest emits its own VaultState; run it before the expectEmit so only rebalance's is checked.
        vault.harvest(type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(coll, debt, yieldBal, 2300e36, YIELD_PRICE);
        vault.rebalance();

        assertGt(vault.debt(), debtBeforeLever);
        assertGt(YIELD_TOKEN.balanceOf(address(vault)), 0);
    }

    // Hits `_rebalanceLever`'s `targetDebt <= currentDebt` guard: 1:1 oracle + 11 wei collateral
    // -> maxBorrow=9, borrow=6 (ltv=0.545 < LTV_MIN); targetDebt=floor(9*0.61/0.86)=6 == currentDebt -> no-op.
    function test_rebalance_leverNoopWhenTargetDebtFloorsToCurrentDebt() public {
        setCollateralPrice(1e40); // 1:1 oracle
        vm.prank(alice);
        vault.deposit(4, alice);

        LOAN_TOKEN.mint(address(this), 1);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 1, 0, address(vault), "");

        assertLt(vault.ltv(), LTV_MIN);
        uint256 debtBefore = vault.debt();

        vault.rebalance();

        assertEq(vault.debt(), debtBefore);
    }

    // Hits `_rebalanceDelever`'s `yieldToSell == 0` guard: vault is over-levered (ltv > LTV_MAX)
    // with `repayAmount > 0` (oracle implies yieldToSell >= 1), but the `yieldToSell > yieldBalance`
    // clamp zeroes it when yield is wiped — a price drop after yield drains to zero strands delever.
    function test_rebalance_deleverNoopWhenVaultHasNoYieldToSell() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        YIELD_TOKEN.burn(address(vault), YIELD_TOKEN.balanceOf(address(vault)));
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), 0);

        setCollateralPrice(COLLATERAL_PRICE / 3);
        assertGt(vault.ltv(), LTV_MAX);
        uint256 debtBefore = vault.debt();

        vault.rebalance();

        assertEq(vault.debt(), debtBefore);
    }
}
