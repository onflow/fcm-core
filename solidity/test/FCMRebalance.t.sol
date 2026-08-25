// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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
        (,, bool ok) = _grabHealthFactors();
        assertFalse(ok);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(101, 100));
        vault.rebalance();
        (,, ok) = _grabHealthFactors();
        assertFalse(ok);

        setCollateralPrice(COLLATERAL_PRICE.mulDiv(99, 100));
        vault.rebalance();
        (,, ok) = _grabHealthFactors();
        assertFalse(ok);

        assertEq(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_leversWhenAboveMax() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MAX);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        vault.rebalance();
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MAX);
        assertGt(YIELD_TOKEN.balanceOf(address(vault)), originalYield);
    }

    function test_rebalance_deleversWhenBelowMin() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        setCollateralPrice(COLLATERAL_PRICE.mulDiv(50, 100));
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);
        uint256 originalYield = YIELD_TOKEN.balanceOf(address(vault));
        vault.rebalance();
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MIN);
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
        assertEq(vault.debt(), 0);
        // we allow loan tokens to be lost.
        assertGt(LOAN_TOKEN.balanceOf(address(vault)), 0);
    }

    function testFuzz_rebalance_leverPartialFill(uint16 slippageBps) public {
        slippageBps = uint16(bound(slippageBps, 1, 9999));
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
        slippageBps = uint16(bound(slippageBps, 1, 9999));
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
        MARKET_ORACLE.setPrice(COLLATERAL_PRICE.mulDiv(150, 100));
        vm.prank(owner);
        vault.scheduleEmergencyRecovery();
        vm.warp(vault.emergencyRecoveryValidAt());
        uint256 hfBefore = vault.healthFactor();
        assertGt(hfBefore, HEALTH_FACTOR_MAX);
        vault.rebalance();
        assertEq(vault.healthFactor(), hfBefore);
    }

    function test_rebalance_deleversDuringRecovery() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        MARKET_ORACLE.setPrice(1000e36);
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);
        vault.rebalance();
        assertGt(vault.healthFactor(), HEALTH_FACTOR_MIN);
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

        setCollateralPrice(COLLATERAL_PRICE / 10);
        setYieldPrice(YIELD_PRICE / 10);

        uint256 originalHealthFactor = vault.healthFactor();
        vault.rebalance();
        assertGt(vault.healthFactor(), originalHealthFactor);
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);
    }

    function test_rebalance_noopStillEmitsSnapshot() public {
        setCollateralPrice(2e36);
        setYieldPrice(4e36);

        vm.prank(alice);
        vault.deposit(1 ether, alice);

        uint256 depositHealth = (HEALTH_FACTOR_MAX_TARGET + HEALTH_FACTOR_MIN_TARGET) / 2;
        uint256 debt = uint256(2 ether).mulDiv(MARKET_LLTV, depositHealth);
        vm.expectEmit(true, true, true, true);
        emit IFCMVault.VaultState(1 ether, debt, debt / 4, 2e36, 1e36, 4e36);
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

    function _grabHealthFactors() internal view returns (uint256, uint256, bool) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == IFCMVault.Rebalanced.selector) {
                return (uint256(entries[i].topics[1]), uint256(entries[i].topics[2]), true);
            }
        }
        return (0, 0, false);
    }

    function test_rebalance_leverEmitsUpdatedSnapshot() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);
        uint256 debtBeforeLever = vault.debt();
        setCollateralPrice(2300e36); // push HF above max so rebalance levers

        vm.recordLogs();
        vault.harvest(type(uint256).max);
        vault.rebalance();

        (, uint256 debt, uint256 yield, uint256 collPrice,, uint256 yieldPrice) = _assertVaultStateMatchesCurrentState();
        assertEq(collPrice, 2300e36);
        assertEq(yieldPrice, YIELD_PRICE);
        assertGt(debt, debtBeforeLever);
        assertGt(yield, 0);
    }

    /// @dev Decode the last `VaultState` snapshot emitted by the vault.
    function _lastVaultState()
        internal
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 yield,
            uint256 collateralPrice,
            uint256 debtPrice,
            uint256 yieldPrice
        )
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != IFCMVault.VaultState.selector) continue;
            (collateral, debt, yield, collateralPrice, debtPrice, yieldPrice) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            found = true;
        }
        require(found, "VaultState not emitted");
    }

    /// @dev Assert the last `VaultState` snapshot matches the vault's actual current state.
    function _assertVaultStateMatchesCurrentState()
        internal
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 yield,
            uint256 collateralPrice,
            uint256 debtPrice,
            uint256 yieldPrice
        )
    {
        (collateral, debt, yield, collateralPrice, debtPrice, yieldPrice) = _lastVaultState();
        assertEq(collateral, vault.collateral());
        assertApproxEqAbs(debt, vault.debt(), 1);
        assertEq(yield, YIELD_TOKEN.balanceOf(address(vault)));
    }

    // Hits `_rebalanceLever`'s `targetDebt <= currentDebt` guard, only reachable at
    // sub-100-wei scale: 1:1 oracle + 4 wei collateral -> maxBorrow=3, borrow=2 (HF=1.5);
    // repay 1 wei -> debt=1, HF=3>MAX, and targetDebt=floor(3e18/1.6e18)=1 == currentDebt -> no-op.
    function test_rebalance_leverNoopWhenTargetDebtFloorsToCurrentDebt() public {
        setCollateralPrice(1e36); // 1:1 oracle
        vm.prank(alice);
        vault.deposit(4, alice);

        LOAN_TOKEN.mint(address(this), 10);
        LOAN_TOKEN.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(vault.market(), 1, 0, address(vault), "");

        assertGt(vault.healthFactor(), HEALTH_FACTOR_MAX);
        uint256 debtBefore = vault.debt();

        vault.rebalance();

        assertEq(vault.debt(), debtBefore);
    }

    // Hits `_rebalanceDelever`'s `yieldToSell == 0` guard: vault is over-levered (hf < MIN)
    // with `repayAmount > 0` (oracle implies yieldToSell >= 1), but the `yieldToSell > yieldBalance`
    // clamp zeroes it when yield is wiped — a price drop after yield drains to zero strands delever.
    function test_rebalance_deleverNoopWhenVaultHasNoYieldToSell() public {
        vm.prank(alice);
        vault.deposit(1 ether, alice);

        YIELD_TOKEN.burn(address(vault), YIELD_TOKEN.balanceOf(address(vault)));
        assertEq(YIELD_TOKEN.balanceOf(address(vault)), 0);

        setCollateralPrice(COLLATERAL_PRICE / 3);
        assertLt(vault.healthFactor(), HEALTH_FACTOR_MIN);
        uint256 debtBefore = vault.debt();

        vault.rebalance();

        assertEq(vault.debt(), debtBefore);
    }
}
