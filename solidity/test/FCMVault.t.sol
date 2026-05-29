// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FCMVault, MORPHO} from "../src/FCMVault.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Id, MarketParams, Position, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockIrm} from "./mocks/MockIrm.sol";

contract FCMVaultTest is Test {
    // Token addresses — using the real Flow EVM addresses so mocks are
    // etched where the vault constants would otherwise point.
    IERC20 constant WETH = IERC20(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
    address constant MOCK_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;

    uint256 internal constant WETH_PRICE = 2000e36;
    uint256 internal constant YIELD_PRICE = 1e36;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant HEALTH_FACTOR_TARGET = 1.45e18;
    uint24 internal constant FEE = 100;
    uint24 internal constant FEE_ASSET_DEBT = 3000;

    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;

    address internal user = address(0xA11CE);

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(address(WETH), erc20Code);
        vm.etch(address(PYUSD0), erc20Code);
        vm.etch(address(FUSDEV), erc20Code);
        vm.etch(address(MORPHO), address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        marketOracle = new MockOracle(WETH_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);

        vault = new FCMVault(
            FCMVault.InitParams({
                collateral: WETH,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                marketOracle: address(marketOracle),
                marketIrm: MOCK_IRM,
                marketLltv: LLTV,
                feeYieldDebt: FEE,
                feeAssetDebt: FEE_ASSET_DEBT,
                healthFactorUpperTarget: HEALTH_FACTOR_TARGET,
                yieldOracle: address(yieldOracle),
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );
    }

    function test_Deposit_FirstDepositMintsShares() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);

        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // _decimalsOffset() == 6 → first depositor gets assets * 1e6.
        assertEq(shares, amount * 1e6, "shares");
        assertEq(vault.balanceOf(user), shares, "balanceOf user");
        assertEq(vault.totalSupply(), shares, "totalSupply");
    }

    function test_Deposit_PullsCollateralAndBorrowsDebt() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);

        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        assertEq(WETH.balanceOf(user), 0, "user weth");
        assertEq(WETH.balanceOf(address(MORPHO)), amount, "morpho weth");
        assertEq(WETH.balanceOf(address(vault)), 0, "vault weth");

        // toBorrow = 2000 * 0.86 / 1.45 ≈ 1186.2069 PYUSD0 (1:1 to FUSDEV).
        uint256 expectedBorrow = ((amount * 2000 * 0.86e18) / 1.45e18);
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), expectedBorrow, 1, "vault fusdev");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "vault pyusd0");
    }

    function test_Deposit_NavRoundsToOriginalAssets() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);

        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // collateral + yieldInAsset - debtInAsset = amount, since the yield
        // and debt legs are equal in value at the mock 1:1 swap rate.
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "totalAssets");
    }

    function test_Deposit_TwoDepositorsProRata() public {
        uint256 amount = 1 ether;
        address alice = address(0xA);
        address bob = address(0xB);

        MockERC20(address(WETH)).mint(alice, amount);
        MockERC20(address(WETH)).mint(bob, amount);

        vm.startPrank(alice);
        WETH.approve(address(vault), amount);
        uint256 aliceShares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        WETH.approve(address(vault), amount);
        uint256 bobShares = vault.deposit(amount, bob);
        vm.stopPrank();

        assertApproxEqRel(bobShares, aliceShares, 1e15, "share parity");
    }

    function test_Deposit_RevertsOnZeroApproval() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.prank(user);
        vm.expectRevert();
        vault.deposit(amount, user);
    }

    // ---- redeem tests ------------------------------------------------------

    /// @dev    Test helper: mint `amount` of (mock) WETH to `who`, approve
    ///         the vault, and deposit on their behalf. Used by every redeem
    ///         test to put the vault into a known leveraged state.
    /// @param  who     Account that will own the resulting vault shares.
    /// @param  amount  WETH amount to deposit (in token units).
    /// @return shares  Vault shares minted to `who`.
    function _depositFor(address who, uint256 amount) internal returns (uint256 shares) {
        MockERC20(address(WETH)).mint(who, amount);
        vm.startPrank(who);
        WETH.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @notice Round-trip: deposit 1 WETH then immediately redeem all shares.
    /// With 1:1 mock swap rates and matching oracle prices, the AMM-mediated
    /// unwind (FUSDEV->PYUSD0->repay->withdrawCollateral) should return the
    /// original WETH within rounding tolerance.
    function test_Redeem_RoundTripReturnsApproximatelyDeposited() public {
        uint256 amount = 1 ether;
        uint256 shares = _depositFor(user, amount);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertApproxEqAbs(assetsOut, amount, 1, "assetsOut approx deposit");
        assertEq(WETH.balanceOf(user), assetsOut, "user weth credit");
        assertEq(vault.balanceOf(user), 0, "shares burned");
    }

    /// @notice Redeem to a different receiver: shares are burned from the
    /// owner, WETH is delivered to the receiver, and the owner's WETH
    /// balance is untouched.
    function test_Redeem_BurnsSharesAndTransfersToReceiver() public {
        uint256 amount = 1 ether;
        uint256 shares = _depositFor(user, amount);
        address receiver = address(0xBEEF);

        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, receiver, user);

        assertEq(vault.balanceOf(user), 0, "owner shares");
        assertEq(vault.totalSupply(), supplyBefore - shares, "supply decreased");
        assertEq(WETH.balanceOf(receiver), assetsOut, "receiver weth");
        assertEq(WETH.balanceOf(user), 0, "owner weth untouched");
    }

    /// @notice Partial redeem (half of shares) unwinds proportionally — about
    /// half the collateral, half the debt, and half the FUSDEV position are
    /// removed; the rest of the position remains intact and healthy.
    function test_Redeem_PartialRedeemUnwindsProportionalSlice() public {
        uint256 amount = 2 ether;
        uint256 shares = _depositFor(user, amount);

        uint256 collateralBefore = WETH.balanceOf(address(MORPHO));
        uint256 fusdevBefore = FUSDEV.balanceOf(address(vault));

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares / 2, user, user);

        // ~half of each leg consumed (within 0.1% — virtual-share offset).
        assertApproxEqRel(
            WETH.balanceOf(address(MORPHO)), collateralBefore / 2, 1e15, "collateral halved"
        );
        assertApproxEqRel(FUSDEV.balanceOf(address(vault)), fusdevBefore / 2, 1e15, "fusdev halved");
        assertApproxEqRel(assetsOut, amount / 2, 1e15, "assetsOut approx half");

        // Remaining shares roughly track the remaining position.
        assertApproxEqRel(vault.balanceOf(user), shares / 2, 1, "shares halved");
    }

    /// @notice Two depositors: Alice redeeming her full stake leaves Bob's
    /// position and share balance materially unaffected.
    function test_Redeem_TwoDepositorsIndependentRedeem() public {
        address alice = address(0xA);
        address bob = address(0xB);
        uint256 aliceShares = _depositFor(alice, 1 ether);
        uint256 bobShares = _depositFor(bob, 3 ether);

        uint256 bobSharesBefore = vault.balanceOf(bob);

        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceShares, alice, alice);

        assertApproxEqRel(aliceOut, 1 ether, 1e15, "alice round-trip");
        assertEq(vault.balanceOf(alice), 0, "alice burned");
        assertEq(vault.balanceOf(bob), bobSharesBefore, "bob shares untouched");
        assertEq(bobShares, bobSharesBefore, "bob shares from deposit retained");
    }

    /// @notice An operator who is not the owner and has no allowance cannot
    /// redeem on the owner's behalf — call reverts via ERC20 allowance check.
    function test_Redeem_RevertsIfNotOwnerAndNoAllowance() public {
        uint256 shares = _depositFor(user, 1 ether);
        address operator = address(0xCAFE);

        vm.prank(operator);
        vm.expectRevert();
        vault.redeem(shares, operator, user);
    }

    /// @notice When the owner pre-approves an operator for `shares`, the
    /// operator can redeem and the allowance is consumed exactly.
    function test_Redeem_SpendsAllowanceWhenOperatorRedeems() public {
        uint256 shares = _depositFor(user, 1 ether);
        address operator = address(0xCAFE);

        vm.prank(user);
        vault.approve(operator, shares);

        vm.prank(operator);
        uint256 assetsOut = vault.redeem(shares, operator, user);

        assertEq(vault.allowance(user, operator), 0, "allowance spent");
        assertEq(WETH.balanceOf(operator), assetsOut, "operator paid");
        assertEq(vault.balanceOf(user), 0, "owner shares burned");
    }

    /// @notice Yield surplus: mint extra FUSDEV to the vault to simulate
    /// yield accrual. On redeem, the proportional sale plus the surplus PYUSD0
    /// reconcile leg push WETH output above the original deposit.
    function test_Redeem_SurplusPyusdReconciledToWeth() public {
        uint256 amount = 1 ether;
        uint256 shares = _depositFor(user, amount);

        // Simulate yield: extra FUSDEV appears in the vault.
        uint256 fusdevYield = FUSDEV.balanceOf(address(vault)) / 10; // +10%
        MockERC20(address(FUSDEV)).mint(address(vault), fusdevYield);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertGt(assetsOut, amount, "yield captured");
    }

    /// @notice Case B: when the FUSDEV->PYUSD0 swap returns less than the
    /// pro-rata debt slice, redeem scales BOTH the repay and the collateral
    /// withdrawal down by k = pyusdGot / debtSlice. The redeemer takes the
    /// haircut on their payout; remaining collateral stays in the vault.
    /// Here we induce a 10% AMM haircut via MockSwapRouter.setFeeBps, so
    /// pyusdGot = 0.9 * debtSlice → k = 0.9. The user should receive ~90%
    /// of the fair-execution round-trip WETH, and no PYUSD0 should be left
    /// in the vault (Case B uses everything received to repay).
    function test_Redeem_YieldUnderperformsScalesBothLegs() public {
        uint256 amount = 1 ether;
        uint256 shares = _depositFor(user, amount);

        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(1000);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertApproxEqRel(assetsOut, (amount * 9) / 10, 0.01e18, "scaled payout ~k*amount");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no surplus / dust");
        assertEq(vault.balanceOf(user), 0, "shares burned");
    }

    /// @notice redeem(0) is a no-op: returns 0 with no state change.
    function test_Redeem_ZeroSharesIsNoop() public {
        _depositFor(user, 1 ether);
        uint256 supplyBefore = vault.totalSupply();
        uint256 sharesBefore = vault.balanceOf(user);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(0, user, user);

        assertEq(assetsOut, 0, "zero out");
        assertEq(vault.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(vault.balanceOf(user), sharesBefore, "shares unchanged");
    }

    // ---- deposit edge-case tests ------------------------------------------

    /// @dev Verifies that a deposit only borrows against the depositor's own
    ///      collateral, not the entire available headroom in the protocol.
    ///
    ///      Setup: Alice makes a large deposit, then the collateral price 5×es,
    ///      leaving the position with a health factor >> target (~7×). A 99%
    ///      swap fee is then set so the rebalancing cost is maximally visible.
    ///
    ///      Bob makes a tiny 0.001 ETH deposit. If deposit were to rebalance
    ///      the whole protocol to target health factor, it would borrow
    ///      ~474k PYUSD0 and wipe out the vault's NAV at a 99% swap fee.
    ///      Instead, borrow is capped to Bob's proportional contribution
    ///      (~5.93 PYUSD0), so:
    ///        - Bob still receives shares.
    ///        - Vault NAV increases (Bob contributed positive value).
    ///        - Health factor stays far above target, not pulled down to it.
    function test_Deposit_DepositDoesNotRebalanceProtocol() public {
        address alice = address(0xA);
        address bob = address(0xB);

        uint256 aliceAmount = 100 ether;
        MockERC20(address(WETH)).mint(alice, aliceAmount);
        vm.startPrank(alice);
        WETH.approve(address(vault), aliceAmount);
        vault.deposit(aliceAmount, alice);
        vm.stopPrank();

        // 5× price increase → health factor jumps from 1.45 to ~7.25.
        marketOracle.setPrice(10_000e36);

        // Brutal swap fee: if deposit rebalanced to target HF it would borrow
        // ~474k PYUSD0, lose 99% to fees, and crater the vault NAV.
        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(9_900);

        uint256 navBefore = vault.totalAssets();
        uint256 healthBefore = _healthFactor();

        uint256 bobAmount = 0.001 ether;
        MockERC20(address(WETH)).mint(bob, bobAmount);
        vm.startPrank(bob);
        WETH.approve(address(vault), bobAmount);
        uint256 bobShares = vault.deposit(bobAmount, bob);
        vm.stopPrank();

        assertGt(bobShares, 0, "bob receives shares");
        assertGt(vault.totalAssets(), navBefore, "nav increased");

        uint256 healthAfter = _healthFactor();
        assertGt(healthAfter, 5e18, "health factor still well above target after bob");
        assertApproxEqRel(
            healthAfter, healthBefore, 1e15, "bob did not materially change health factor"
        );
    }

    /// @dev When the position health factor is below the target (price has dropped,
    ///      existing debt is already too high), a new deposit must not borrow any
    ///      additional loan token. It still supplies collateral and mints shares —
    ///      it just skips the borrow+swap leg entirely until health recovers.
    function test_Deposit_NoBorrowWhenPositionUnhealthy() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // Drop price so existing debt exceeds the health factor target.
        // At 800e36: maxBorrow = 1e18 * 800 * 0.86 = 688 PYUSD0.
        // Existing debt ≈ 1186 PYUSD0 → HF ≈ 0.58, well below target of 1.45.
        marketOracle.setPrice(800e36);

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        address bob = address(0xB);
        MockERC20(address(WETH)).mint(bob, amount);
        vm.startPrank(bob);
        WETH.approve(address(vault), amount);
        uint256 bobShares = vault.deposit(amount, bob);
        vm.stopPrank();

        // Bob still gets shares — collateral was supplied.
        assertGt(bobShares, 0, "bob gets shares");
        assertEq(WETH.balanceOf(address(MORPHO)), amount * 2, "both deposits collateral supplied");

        // No new borrowing — FUSDEV balance unchanged.
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "no new yield bought");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan token sitting idle");
    }

    // ---- helpers -------------------------------------------------------

    function _healthFactor() internal view returns (uint256) {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        Id marketId = MarketParamsLib.id(MarketParams(lt, ct, oracle, irm, lltv_));
        Position memory pos = MORPHO.position(marketId, address(vault));
        Market memory mkt = MORPHO.market(marketId);
        if (pos.borrowShares == 0) return type(uint256).max;
        uint256 debt = (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1))
            / (uint256(mkt.totalBorrowShares) + 1e6);
        uint256 maxBorrow = Math.mulDiv(
            uint256(pos.collateral), Math.mulDiv(marketOracle.priceValue(), lltv_, 1e36), 1e18
        );
        return Math.mulDiv(maxBorrow, 1e18, debt);
    }
}
