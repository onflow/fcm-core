// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

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
    uint256 internal constant HEALTH_FACTOR_MIN = 1.25e18;
    uint256 internal constant HEALTH_FACTOR_TARGET = 1.45e18;
    uint256 internal constant HEALTH_FACTOR_MAX = 1.65e18;
    uint24 internal constant FEE = 100;
    uint24 internal constant FEE_ASSET_DEBT = 3000;

    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;

    address internal admin = address(0x12345);
    address internal user = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal stranger = address(0x5_7A);

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
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorTarget: HEALTH_FACTOR_TARGET,
                yieldOracle: address(yieldOracle),
                admin: admin,
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );
        vm.prank(admin);
        vault.setMaxTvl(1e21);

        // Pre-allow the addresses existing deposit tests use as receivers.
        // Gating-specific tests use fresh addresses (bob, carol, stranger).
        _allow(user);
        _allow(address(0xA));
        _allow(address(0xB));
    }

    /// @dev First depositor into an empty vault receives shares equal to
    ///      `assets * 10**_decimalsOffset()`. ERC4626's virtual-shares inflation
    ///      protection seeds the share/asset ratio at 1:1e6 for the first deposit.
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

    /// @dev A deposit must (1) pull the collateral from the depositor into Morpho,
    ///      (2) borrow loan token against it at the configured target health factor,
    ///      and (3) swap the borrowed loan token into yield token, leaving no loan
    ///      token idle in the vault. Expected borrow = `assets * price * lltv / target HF`.
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
        uint256 expectedBorrow = (amount * 2000 * 0.86e18) / 1.45e18;
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), expectedBorrow, 1, "vault fusdev");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "vault pyusd0");
    }

    /// @dev `mint` is intentionally not supported — the vault only accepts
    ///      asset-denominated deposits, since minting an exact share count would
    ///      require pre-computing the borrow+swap leg with unknown slippage.
    function test_Mint_Reverts() public {
        vm.expectRevert(bytes("not implemented"));
        vault.mint(1e18, user);
    }

    /// @dev After a deposit, NAV in asset terms should equal the original deposit
    ///      amount (modulo rounding): the collateral leg adds `assets` of value, and
    ///      the borrow→swap leg nets to zero because yield and debt are valued at the
    ///      same 1:1 mock rate. Verifies no value is leaked by the deposit flow itself.
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

    /// @dev Two sequential depositors contributing the same asset amount should
    ///      receive approximately the same share count. Tolerates ~1e-3 relative
    ///      drift from rounding in the second deposit's share computation against
    ///      the now-nonzero totalAssets/totalSupply.
    function test_Deposit_TwoDepositorsProRata() public {
        uint256 amount = 1 ether;
        address alice = address(0xA);
        address bobLocal = address(0xB);

        MockERC20(address(WETH)).mint(alice, amount);
        MockERC20(address(WETH)).mint(bobLocal, amount);

        vm.startPrank(alice);
        WETH.approve(address(vault), amount);
        uint256 aliceShares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.startPrank(bobLocal);
        WETH.approve(address(vault), amount);
        uint256 bobShares = vault.deposit(amount, bobLocal);
        vm.stopPrank();

        assertApproxEqRel(bobShares, aliceShares, 1e15, "share parity");
    }

    /// @dev A deposit without a prior ERC20 approval must revert at the
    ///      `transferFrom` step. Sanity check that the vault does not have any
    ///      hidden allowance path that would let it pull tokens without consent.
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
        _allow(alice);
        _allow(bob);
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

    // ---- in-kind redeem (escape hatch) ------------------------------------

    /// @notice Escape hatch: a holder exits in kind — repays its pro-rata debt in
    ///         loanToken and receives collateral + yield tokens directly, no swap.
    ///         (A swap-based redeem delivers only the asset and zero yield, so
    ///         receiving FUSDEV proves the swap-free path ran.)
    function test_RedeemInKind_FullExit() public {
        uint256 shares = _depositFor(user, 1 ether);

        // Sole holder exiting in full; pin the exact slices the vault must
        // deliver. claims = totalSupply + 10**offset (offset 6), so the slice
        // is shares/claims (just under 1, from the virtual-share offset).
        uint256 collateral = WETH.balanceOf(address(MORPHO));
        uint256 yield = FUSDEV.balanceOf(address(vault));
        uint256 claims = vault.totalSupply() + 1e6;
        uint256 expColl = collateral * shares / claims; // floors
        uint256 expYield = yield * shares / claims; // floors

        // Caller funds the debt repayment in loanToken and approves the vault.
        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        uint256 loanBefore = PYUSD0.balanceOf(user);

        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        (uint256 collOut, uint256 yieldOut) = vault.redeemInKind(shares, user, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 0, "shares burned");
        assertEq(collOut, expColl, "exact collateral slice");
        assertEq(yieldOut, expYield, "exact yield slice");
        assertEq(WETH.balanceOf(user), collOut, "collateral delivered in kind");
        assertEq(FUSDEV.balanceOf(user), yieldOut, "yield delivered in kind");

        // Debt and yield share the same base (1:1 borrow->swap, no interest), so
        // the debt slice is just the yield slice rounded up: the +1 proves Ceil
        // (Floor would give equality), i.e. the redeemer over-repays by 1 wei.
        uint256 debtSpent = loanBefore - PYUSD0.balanceOf(user);
        assertEq(debtSpent, yieldOut + 1, "debt slice = yield slice + 1 (rounded up)");
    }

    /// @notice A de-allowlisted holder can still exit: the escape hatch burns
    ///         shares, and the allowlist hook permits burns (same as `redeem`).
    function test_RedeemInKind_WorksWhenDeAllowlisted() public {
        uint256 shares = _depositFor(user, 1 ether);

        uint256 expColl = WETH.balanceOf(address(MORPHO)) * shares / (vault.totalSupply() + 1e6);
        uint256 expYield = FUSDEV.balanceOf(address(vault)) * shares / (vault.totalSupply() + 1e6);

        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.revokeRole(role, user);

        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        (uint256 collOut, uint256 yieldOut) = vault.redeemInKind(shares, user, user);
        vm.stopPrank();

        // Same full in-kind slice as a normal exit — de-allowlisting changes nothing.
        assertEq(vault.balanceOf(user), 0, "exited despite de-allowlist");
        assertEq(collOut, expColl, "exact collateral slice");
        assertEq(yieldOut, expYield, "exact yield slice");
        assertEq(WETH.balanceOf(user), collOut, "collateral delivered in kind");
        assertEq(FUSDEV.balanceOf(user), yieldOut, "yield delivered in kind");
    }

    /// @notice Partial in-kind exit alongside a second holder. Confirms the slices
    ///         are floored pro-rata, the debt slice rounds UP (Ceil — the redeemer
    ///         over-repays by 1 wei), and the remaining holder's value-per-share is
    ///         not diluted.
    function test_RedeemInKind_PartialExitDoesNotDiluteRemainingHolder() public {
        _allow(bob);
        uint256 aliceShares = _depositFor(user, 1 ether);
        uint256 bobShares = _depositFor(bob, 3 ether);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));
        uint256 bobValueBefore = vault.convertToAssets(bobShares);

        // Burn a non-round portion so the debt slice has a nonzero remainder and
        // the Ceil rounding actually bites. claims = totalSupply + 10**offset.
        uint256 exit = aliceShares / 3;
        uint256 claims = vault.totalSupply() + 1e6;

        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        uint256 loanBefore = PYUSD0.balanceOf(user);
        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        (uint256 collOut, uint256 yieldOut) = vault.redeemInKind(exit, user, user);
        vm.stopPrank();

        // Slices are exactly the floored pro-rata fraction of the position.
        assertEq(collOut, collBefore * exit / claims, "collateral slice floored pro-rata");
        assertEq(yieldOut, yieldBefore * exit / claims, "yield slice floored pro-rata");

        // Same base as the yield slice, so the +1 is the Ceil rounding biting here
        // on a partial slice.
        uint256 debtSpent = loanBefore - PYUSD0.balanceOf(user);
        assertEq(debtSpent, yieldOut + 1, "debt slice rounded up vs floored yield slice");

        // Bob stayed put: shares untouched and value-per-share did not drop — every
        // rounding residual stays with the vault, never leaking to the exiter.
        assertEq(vault.balanceOf(bob), bobShares, "bob shares untouched");
        assertGe(vault.convertToAssets(bobShares), bobValueBefore, "bob not diluted");
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
        address bobLocal = address(0xB);

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
        MockERC20(address(WETH)).mint(bobLocal, bobAmount);
        vm.startPrank(bobLocal);
        WETH.approve(address(vault), bobAmount);
        uint256 bobShares = vault.deposit(bobAmount, bobLocal);
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

        address bobLocal = address(0xB);
        MockERC20(address(WETH)).mint(bobLocal, amount);
        vm.startPrank(bobLocal);
        WETH.approve(address(vault), amount);
        uint256 bobShares = vault.deposit(amount, bobLocal);
        vm.stopPrank();

        // Bob still gets shares — collateral was supplied.
        assertGt(bobShares, 0, "bob gets shares");
        assertEq(WETH.balanceOf(address(MORPHO)), amount * 2, "both deposits collateral supplied");

        // No new borrowing — FUSDEV balance unchanged.
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "no new yield bought");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan token sitting idle");
    }

    // ---------------------------------------------------------------------
    // Role administration
    // ---------------------------------------------------------------------

    /// @notice Admin gets DEFAULT_ADMIN_ROLE on construction; bob/carol/stranger
    ///         start non-allowlisted.
    function test_InitialRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(vault.hasRole(vault.EARLY_ACCESS_ROLE(), bob));
        assertFalse(vault.hasRole(vault.EARLY_ACCESS_ROLE(), carol));
    }

    /// @notice Admin can grant EARLY_ACCESS_ROLE; hasRole reflects the grant.
    function test_AdminCanGrantRole() public {
        _allow(bob);
        assertTrue(vault.hasRole(vault.EARLY_ACCESS_ROLE(), bob));
    }

    /// @notice Admin can revoke EARLY_ACCESS_ROLE; hasRole reflects the revoke.
    function test_AdminCanRevokeRole() public {
        _allow(bob);
        _disallow(bob);
        assertFalse(vault.hasRole(vault.EARLY_ACCESS_ROLE(), bob));
    }

    /// @notice Non-admin cannot grant EARLY_ACCESS_ROLE.
    function test_NonAdminCannotGrantRole() public {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        vault.grantRole(role, bob);
    }

    // ---------------------------------------------------------------------
    // Deposit gating
    // ---------------------------------------------------------------------

    /// @notice maxDeposit returns 0 for a non-allowlisted receiver.
    function test_MaxDepositZeroForNonAllowlisted() public view {
        assertEq(vault.maxDeposit(carol), 0);
    }

    /// @notice maxDeposit returns the underlying max once the receiver is allowlisted.
    function test_MaxDepositNonZeroForAllowlisted() public {
        _allow(carol);
        assertGt(vault.maxDeposit(carol), 0);
    }

    /// @notice maxMint is similarly gated.
    function test_MaxMintZeroForNonAllowlisted() public view {
        assertEq(vault.maxMint(carol), 0);
    }

    /// @notice Deposit reverts when the receiver of shares is not allowlisted.
    ///         The override does not consult `maxDeposit`, but `_update` rejects
    ///         the mint with an AccessControl error.
    function test_DepositRevertsForNonAllowlistedReceiver() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                vault.EARLY_ACCESS_ROLE()
            )
        );
        vault.deposit(amount, bob);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Transfer gating
    // ---------------------------------------------------------------------

    /// @notice Transfers between allowlisted holders succeed.
    function test_TransferBetweenAllowlistedHoldersSucceeds() public {
        _allow(bob);

        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);

        vault.transfer(bob, shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.balanceOf(bob), shares);
    }

    /// @notice Transfer reverts when the recipient is not allowlisted.
    function test_TransferRevertsForNonAllowlistedRecipient() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                vault.EARLY_ACCESS_ROLE()
            )
        );
        vault.transfer(bob, shares);
        vm.stopPrank();
    }

    /// @notice Transfer reverts when the sender has been de-allowlisted, even
    ///         though they still hold shares.
    function test_TransferRevertsForDeAllowlistedSender() public {
        _allow(bob);

        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        _disallow(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                vault.EARLY_ACCESS_ROLE()
            )
        );
        vm.prank(user);
        vault.transfer(bob, shares);
    }

    // ---------------------------------------------------------------------
    // Rebalance
    // ---------------------------------------------------------------------

    /// @notice After a fresh deposit, HF lands exactly at the configured
    ///         target (1.45), which is inside [min=1.25, max=1.65]. A
    ///         non-forced rebalance is a no-op: debt, collateral, and FUSDEV
    ///         balance are unchanged.
    function test_Rebalance_NoopInsideBand() public {
        _depositFor(user, 1 ether);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));
        uint256 hfBefore = _healthFactor();

        vault.rebalance(false);

        assertEq(WETH.balanceOf(address(MORPHO)), collBefore, "coll unchanged");
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev unchanged");
        assertEq(_healthFactor(), hfBefore, "hf unchanged");
    }

    /// @notice When the collateral price rises enough to push HF above max
    ///         (1.65), `rebalance` borrows additional loan token and swaps
    ///         it into yield token, driving HF back to target (1.45). The
    ///         vault's collateral and the position's borrow shares both
    ///         move in the expected directions.
    function test_Rebalance_LeversWhenAboveMax() public {
        _depositFor(user, 1 ether);

        // Push HF above 1.65 by increasing collateral value
        marketOracle.setPrice(2300e36);
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "above max");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(false);

        // HF returns to target (within rounding from share math).
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "hf at target");
        // Lever path: more yield token now held.
        assertGt(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev grew");
        // No idle loan token left behind by the lever swap.
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    /// @notice When the collateral price drops enough to push HF below min
    ///         (1.25), `rebalance` sells yield token for loan token and
    ///         repays just enough debt to land HF back at target.
    function test_Rebalance_DeleversWhenBelowMin() public {
        _depositFor(user, 1 ether);

        // Push HF below 1.25 by lowering collateral value
        marketOracle.setPrice(1700e36);
        assertLt(_healthFactor(), HEALTH_FACTOR_MIN, "below min");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(false);

        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "hf at target");
        // Delever path: yield token shrunk.
        assertLt(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev shrank");
        // Repay leg consumed all realized loan token.
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    // ---- rebalance slippage floor ----------------------------------------

    /// @notice The delever swap reverts when realized slippage exceeds
    ///         `maxSlippageBps`: a 3% AMM haircut trips the default 1% floor,
    ///         so the rebalance reverts rather than executing at a bad price
    ///         (the price-impact / sandwich guard). Deposit/redeem have no such
    ///         floor — that slippage is the caller's via the router.
    function test_Rebalance_DeleverRevertsWhenSlippageExceedsFloor() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(1700e36); // push HF below min -> delever path
        assertLt(_healthFactor(), HEALTH_FACTOR_MIN, "below min");

        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(300); // 3% > 1% floor

        vm.expectRevert("Too little received");
        vault.rebalance(false);
    }

    /// @notice Same guard on the lever leg.
    function test_Rebalance_LeverRevertsWhenSlippageExceedsFloor() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(2300e36); // push HF above max -> lever path
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "above max");

        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(300); // 3% > 1% floor

        vm.expectRevert("Too little received");
        vault.rebalance(false);
    }

    /// @notice Loosening `maxSlippageBps` lets a previously-reverting rebalance
    ///         through: with the floor raised to 5%, a 3% haircut is tolerated.
    function test_Rebalance_RespectsLoosenedSlippage() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(1700e36);
        uint256 hfBefore = _healthFactor();
        assertLt(hfBefore, HEALTH_FACTOR_MIN, "below min");

        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(300); // 3%

        vm.prank(admin);
        vault.setMaxSlippageBps(500); // 5% > 3%, so the 3% haircut now passes

        vault.rebalance(false);
        assertGt(_healthFactor(), hfBefore, "delever raised HF");
    }

    /// @notice `maxSlippageBps` defaults to 1%, is admin-only, and rejects
    ///         values >= 100%.
    function test_SetMaxSlippageBps() public {
        assertEq(vault.maxSlippageBps(), 100, "default 1%");

        vm.prank(admin);
        vault.setMaxSlippageBps(250);
        assertEq(vault.maxSlippageBps(), 250, "admin updated");

        // Non-admin cannot set (DEFAULT_ADMIN_ROLE == bytes32(0)).
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", stranger, bytes32(0)
            )
        );
        vault.setMaxSlippageBps(300);

        // >= 100% rejected.
        vm.prank(admin);
        vm.expectRevert(FCMVault.InvalidSlippage.selector);
        vault.setMaxSlippageBps(10_000);
    }

    /// @notice `force=true` rebalances when HF is inside the dead band but
    ///         not exactly at target. Here we nudge HF slightly off-target
    ///         (still inside [min, max]); a non-forced call is a no-op, a
    ///         forced call pulls HF back to target.
    function test_Rebalance_ForceRebalancesInsideBand() public {
        _depositFor(user, 1 ether);

        // Small collateral price increase leaves HF inside [1.25, 1.65] but above target.
        marketOracle.setPrice(2100e36);
        uint256 hfBefore = _healthFactor();
        assertGt(hfBefore, HEALTH_FACTOR_TARGET, "above target");
        assertLt(hfBefore, HEALTH_FACTOR_MAX, "still inside band");

        // Without force the call is a no-op.
        vault.rebalance(false);
        assertEq(_healthFactor(), hfBefore, "non-forced: noop");

        // With force the position is driven to target.
        vault.rebalance(true);
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "forced: at target");
    }

    /// @notice `force=true` is still a no-op when HF is exactly at target —
    ///         neither lever nor delever branch fires, so no swap or borrow
    ///         is issued.
    function test_Rebalance_ForceAtTargetIsNoop() public {
        _depositFor(user, 1 ether);
        assertApproxEqAbs(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "at target");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));
        uint256 collBefore = WETH.balanceOf(address(MORPHO));

        vault.rebalance(true);

        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev unchanged");
        assertEq(WETH.balanceOf(address(MORPHO)), collBefore, "coll unchanged");
    }

    /// @notice Liquidation recovery: a liquidator seizes most of the vault's
    ///         collateral, leaving the position under-collateralized (HF well below WAD).
    ///         `rebalance` must not revert; it sells yield on a best-effort
    ///         basis and repays as much debt as the realized loan token covers.
    function test_Rebalance_LiquidationRecoveryDoesNotRevert() public {
        _depositFor(user, 1 ether);

        // A liquidation repays 200 of the ~1186 debt and seizes 0.7 of the
        // 1 ether collateral (a contrived ratio that grabs far more value
        // than it repays)
        // collateral 0.3 ether → maxBorrow 0.3 * 2000 * 0.86 = 516 vs ~986 debt → HF ≈ 0.52.
        _liquidate({seizedCollateral: 0.7 ether, repaidAssets: 200e18});
        assertLt(_healthFactor(), 1e18, "underwater");

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        // Best-effort: should succeed even though target is unreachable.
        vault.rebalance(false);

        // rebalance made progress: debt repaid and yield consumed.
        assertLt(_debt(), debtBefore, "debt reduced");
        assertLt(FUSDEV.balanceOf(address(vault)), fusBefore, "yield consumed");
    }

    /// @notice Constructor rejects HF configurations where the dead band is
    ///         malformed (target < min, target > max) or the lower bound is
    ///         below WAD (which would allow rebalancing into a liquidatable
    ///         position).
    function test_Rebalance_ConstructorValidatesHfBand() public {
        FCMVault.InitParams memory p = _baseParams();
        p.healthFactorMin = 0.9e18;
        vm.expectRevert(bytes("HF min < WAD"));
        new FCMVault(p);

        p = _baseParams();
        p.healthFactorMin = 1.6e18;
        p.healthFactorTarget = 1.5e18;
        vm.expectRevert(bytes("HF min > target"));
        new FCMVault(p);

        p = _baseParams();
        p.healthFactorTarget = 2e18;
        p.healthFactorMax = 1.6e18;
        vm.expectRevert(bytes("HF target > max"));
        new FCMVault(p);
    }

    // ---------------------------------------------------------------------
    // Lifecycle (deposit -> rebalance -> redeem)
    // ---------------------------------------------------------------------

    /// @notice Full happy-path lifecycle in a single flow: a user deposits,
    ///         the position is rebalanced, then the user redeems all shares.
    ///
    ///         The rebalance step is set up to perform a real balancing
    ///         operation: a collateral price rise pushes HF above
    ///         max, so a non-forced rebalance must borrow more
    ///         debt and buy more yield. We assert debt and yield
    ///         grew and HF returned to target.
    ///
    ///         NAV is price-invariant in this rig (collateral is measured in
    ///         token units; the yield and debt legs scale together), so the
    ///         round-trip returns approximately the original deposit despite
    ///         the price move.
    function test_Integration_DepositRebalanceRedeem() public {
        uint256 amount = 1 ether;

        // Deposit.
        uint256 shares = _depositFor(user, amount);
        assertGt(shares, 0, "deposit minted shares");
        assertEq(WETH.balanceOf(address(MORPHO)), amount, "collateral supplied to morpho");
        assertGt(FUSDEV.balanceOf(address(vault)), 0, "yield bought with borrowed debt");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token after deposit");
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "deposit lands at target HF");

        // Rebalance: price rise lifts HF above max, forcing a real lever-up.
        marketOracle.setPrice(2300e36);
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "price rise pushed HF above max");

        uint256 debtBefore = _debt();
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(false);

        assertGt(_debt(), debtBefore, "rebalance borrowed more debt");
        assertGt(FUSDEV.balanceOf(address(vault)), yieldBefore, "rebalance bought more yield");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token after rebalance");
        assertApproxEqRel(
            _healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "rebalance restored target HF"
        );

        // Redeem everything.
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(vault.balanceOf(user), 0, "all shares burned");
        assertEq(vault.totalSupply(), 0, "supply back to zero");
        assertEq(WETH.balanceOf(user), assetsOut, "user received redeemed asset");
        assertApproxEqRel(assetsOut, amount, 1e15, "round-trip returns ~deposit");
    }

    // ---- helpers -------------------------------------------------------

    function _allow(address account) internal {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.grantRole(role, account);
    }

    function _disallow(address account) internal {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.revokeRole(role, account);
    }

    function _debt() internal view returns (uint256) {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        Id marketId = MarketParamsLib.id(MarketParams(lt, ct, oracle, irm, lltv_));
        Position memory pos = MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MORPHO.market(marketId);
        return (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1))
            / (uint256(mkt.totalBorrowShares) + 1e6);
    }

    /// @dev Simulate a liquidation of the vault's position via the MockMorpho
    ///      test hook: seize `seizedCollateral` of collateral and repay
    ///      `repaidAssets` of debt.
    function _liquidate(uint256 seizedCollateral, uint256 repaidAssets) internal {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        MockMorpho(address(MORPHO))
            .liquidate(
                MarketParams(lt, ct, oracle, irm, lltv_),
                address(vault),
                seizedCollateral,
                repaidAssets
            );
    }

    function _baseParams() internal view returns (FCMVault.InitParams memory) {
        return FCMVault.InitParams({
            collateral: WETH,
            loanToken: PYUSD0,
            yieldToken: FUSDEV,
            marketOracle: address(marketOracle),
            marketIrm: MOCK_IRM,
            marketLltv: LLTV,
            feeYieldDebt: FEE,
            feeAssetDebt: FEE_ASSET_DEBT,
            healthFactorMin: HEALTH_FACTOR_MIN,
            healthFactorMax: HEALTH_FACTOR_MAX,
            healthFactorTarget: HEALTH_FACTOR_TARGET,
            yieldOracle: address(yieldOracle),
            admin: admin,
            name: "x",
            symbol: "x"
        });
    }

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
