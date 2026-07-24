// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {MockCpmmSwapRouter} from "./mocks/MockCpmmSwapRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
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
    uint256 internal constant HEALTH_FACTOR_MAX = 1.65e18;
    // Re-entry targets just inside each bound: a delever lands at minTarget
    // (just above min), a lever lands at maxTarget (just below max).
    // Ordering: min <= minTarget <= maxTarget <= max.
    uint256 internal constant HEALTH_FACTOR_MIN_TARGET = 1.3e18;
    uint256 internal constant HEALTH_FACTOR_MAX_TARGET = 1.6e18;
    // Deposits lever fresh collateral to the midpoint of the band; rebalance
    // acts only at the bounds.
    uint256 internal constant DEPOSIT_TARGET_HF = (HEALTH_FACTOR_MIN + HEALTH_FACTOR_MAX) / 2;
    // Upper edge of the yield-factor band (rho = yieldValue/debt): harvest fires only
    // when rho > YIELD_FACTOR_MAX. Placeholder (1% band) pending the yield-factor sim.
    uint256 internal constant YIELD_FACTOR_MAX = 1.01e18;
    uint24 internal constant FEE = 100;
    uint24 internal constant FEE_ASSET_DEBT = 3000;

    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;
    MockUniswapV3Pool internal yieldPool;
    MockUniswapV3Pool internal assetPool;

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
        // Yield/debt pool spot defaults to 1:1 (Q96), matching the 1e36 yield
        // oracle so a rebalance's oracle-derived price limit sits on the
        // tradeable side of spot.
        yieldPool = new MockUniswapV3Pool();
        // Asset/debt pool spot defaults to 1:1 (Q96); harvest tests set the market
        // oracle to 1:1 so its leg-2 (loan->collateral) limit sits on the tradeable side.
        assetPool = new MockUniswapV3Pool();

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
                yieldDebtPool: address(yieldPool),
                assetDebtPool: address(assetPool),
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
                healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
                yieldFactorMax: YIELD_FACTOR_MAX,
                yieldOracle: address(yieldOracle),
                admin: admin,
                recoveryDelay: 7 days,
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
    ///      (2) borrow loan token against it at the band-midpoint health factor,
    ///      and (3) swap the borrowed loan token into yield token, leaving no loan
    ///      token idle in the vault. Expected borrow = `assets * price * lltv / midpoint HF`.
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

    /// @notice Robustness: while the vault is marked underwater (totalAssets() == 0)
    ///         with shares outstanding, minting against the collapsed `navBefore + 1`
    ///         denominator would produce a disproportionate share amount. The guard reverts
    ///         instead, and maxDeposit mirrors it as 0. The empty-vault first deposit is
    ///         unaffected (see test_Deposit_FirstDepositMintsShares).
    function test_Deposit_RevertsWhenUnderwaterWithHolders() public {
        _depositFor(user, 1 ether);

        // Crush both legs below the debt so totalAssets() clamps to 0: yield ~worthless and
        // the collateral (fixed WETH amount) worth less than the debt once the mark drops.
        yieldOracle.setPrice(1);
        marketOracle.setPrice(1000e36);
        assertEq(vault.totalAssets(), 0, "precondition: marked underwater");
        assertGt(vault.totalSupply(), 0, "precondition: holders outstanding");

        _allow(bob);
        MockERC20(address(WETH)).mint(bob, 1 ether);
        vm.startPrank(bob);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert(FCMVault.VaultUnderwater.selector);
        vault.deposit(1 ether, bob);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0, "maxDeposit mirrors the guard");
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
        assertApproxEqRel(WETH.balanceOf(address(MORPHO)), collateralBefore / 2, 1e15, "collateral halved");
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

    /// @notice Case B (the yield sale falls short of the pro-rata debt slice):
    /// redeem fills the shortfall by selling a slice of the redeemer's OWN
    /// collateral, so they receive their full pro-rata value — not the old
    /// scale-down haircut. We under-back the vault (burn 10% of its yield) to
    /// force a real shortfall; collateral is sold to cover it and the redeemer
    /// gets ~their full NAV share back.
    function test_Redeem_CaseB_FillsShortfallFromCollateral() public {
        marketOracle.setPrice(1e36); // 1:1 so debtToCollateral matches the mock swap
        uint256 shares = _depositFor(user, 1 ether);
        // Under-back: burn 10% of the vault's yield so the yield sale can't cover
        // the debt slice (Case B) with a meaningful shortfall.
        MockERC20(address(FUSDEV)).burn(address(vault), FUSDEV.balanceOf(address(vault)) / 10);
        uint256 fairValue = vault.convertToAssets(shares);
        uint256 mkCollBefore = WETH.balanceOf(address(MORPHO));

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertApproxEqRel(assetsOut, fairValue, 0.02e18, "full pro-rata value, not a haircut");
        assertLt(WETH.balanceOf(address(MORPHO)), mkCollBefore, "collateral sold to cover shortfall");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan-token dust");
        assertEq(vault.balanceOf(user), 0, "shares burned");
    }

    /// @notice Deep impairment: the shortfall exceeds the health-factor headroom,
    ///         so the collateral can only be withdrawn after the debt slice is
    ///         repaid. The flash loan supplies the shortfall up front, so redeem
    ///         still delivers full pro-rata value at any health factor.
    function test_Redeem_CaseB_DeepImpairmentFlashCoversAnyHF() public {
        marketOracle.setPrice(1e36); // 1:1 so debtToCollateral matches the mock swap
        uint256 shares = _depositFor(user, 1 ether);
        // Burn 60% of the vault's yield: the shortfall now dwarfs the hf headroom,
        // which the pre-flash path could not have covered without breaching hf.
        MockERC20(address(FUSDEV)).burn(address(vault), FUSDEV.balanceOf(address(vault)) * 6 / 10);
        uint256 fairValue = vault.convertToAssets(shares);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertApproxEqRel(assetsOut, fairValue, 0.02e18, "full pro-rata value, not a haircut");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan-token dust");
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
    ///      leaving the position with a health factor >> midpoint (~7×). A 99%
    ///      swap fee is then set so the rebalancing cost is maximally visible.
    ///
    ///      Bob makes a tiny 0.001 ETH deposit. If deposit were to rebalance
    ///      the whole protocol to the midpoint health factor, it would borrow
    ///      ~474k PYUSD0 and wipe out the vault's NAV at a 99% swap fee.
    ///      Instead, borrow is capped to Bob's proportional contribution
    ///      (~5.93 PYUSD0), so:
    ///        - Bob still receives shares.
    ///        - Vault NAV increases (Bob contributed positive value).
    ///        - Health factor stays far above the midpoint, not pulled down to it.
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

        // Brutal swap fee: if deposit rebalanced to the midpoint HF it would borrow
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
        assertApproxEqRel(healthAfter, healthBefore, 1e15, "bob did not materially change health factor");
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
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, vault.DEFAULT_ADMIN_ROLE()
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
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, vault.EARLY_ACCESS_ROLE()
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
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, vault.EARLY_ACCESS_ROLE()
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
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, vault.EARLY_ACCESS_ROLE()
            )
        );
        vm.prank(user);
        vault.transfer(bob, shares);
    }

    // ---------------------------------------------------------------------
    // Rebalance
    // ---------------------------------------------------------------------

    /// @notice After a fresh deposit, HF lands at the band midpoint (1.45),
    ///         which is inside [min=1.25, max=1.65]. A rebalance is a no-op:
    ///         debt, collateral, and FUSDEV balance are unchanged.
    function test_Rebalance_NoopInsideBand() public {
        _depositFor(user, 1 ether);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));
        uint256 hfBefore = _healthFactor();

        vault.rebalance();

        assertEq(WETH.balanceOf(address(MORPHO)), collBefore, "coll unchanged");
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev unchanged");
        assertEq(_healthFactor(), hfBefore, "hf unchanged");
    }

    /// @notice When the collateral price rises enough to push HF above max
    ///         (1.65), `rebalance` borrows additional loan token and swaps
    ///         it into yield token, driving HF down to the re-entry target
    ///         just below the upper bound (`healthFactorMaxTarget`, 1.60) —
    ///         not a central target. The vault's collateral and the position's
    ///         borrow shares both move in the expected directions.
    function test_Rebalance_LeversWhenAboveMax() public {
        _depositFor(user, 1 ether);

        // Push HF above 1.65 by increasing collateral value
        marketOracle.setPrice(2300e36);
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "above max");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        // HF returns to the upper re-entry target (within rounding from share math).
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_MAX_TARGET, 1e15, "hf at maxTarget");
        // Lever path: more yield token now held.
        assertGt(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev grew");
        // No idle loan token left behind by the lever swap.
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    /// @notice When the collateral price drops enough to push HF below min
    ///         (1.25), `rebalance` sells yield token for loan token and
    ///         repays just enough debt to land HF at the re-entry target just
    ///         above the lower bound (`healthFactorMinTarget`, 1.30) — not a
    ///         central target.
    function test_Rebalance_DeleversWhenBelowMin() public {
        _depositFor(user, 1 ether);

        // Push HF below 1.25 by lowering collateral value
        marketOracle.setPrice(1700e36);
        assertLt(_healthFactor(), HEALTH_FACTOR_MIN, "below min");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_MIN_TARGET, 1e15, "hf at minTarget");
        // Delever path: yield token shrunk.
        assertLt(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev shrank");
        // Repay leg consumed all realized loan token.
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    // ---- rebalance price-limit guard -------------------------------------

    /// @notice When the pool's marginal price is already past the oracle-derived
    ///         slippage bound, the delever swap is skipped entirely (a swap-free
    ///         no-op) rather than trading at a bad price. Selling yield raises
    ///         the yield/loan price, so a pool spot already above the bound
    ///         leaves no room to sell within tolerance.
    function test_Rebalance_DeleverSkipsWhenSpotPastBound() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(1700e36); // push HF below min -> delever path
        uint256 hfBefore = _healthFactor();
        assertLt(hfBefore, HEALTH_FACTOR_MIN, "below min");

        // Pool yield/loan price 2% above oracle — past the 1% bound for selling
        // yield (a price-raising swap), so the swap is skipped.
        _setPoolPrice(102, 100);

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(); // no revert; spot past bound, so no swap

        assertEq(_healthFactor(), hfBefore, "hf unchanged");
        assertEq(_debt(), debtBefore, "debt unchanged");
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "yield unchanged");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    /// @notice Same price-limit skip on the lever leg: buying yield lowers the
    ///         yield/loan price, so a pool spot already below the bound leaves no
    ///         room to buy within tolerance. No swap runs, no idle loan lingers.
    function test_Rebalance_LeverSkipsWhenSpotPastBound() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(2300e36); // push HF above max -> lever path
        uint256 hfBefore = _healthFactor();
        assertGt(hfBefore, HEALTH_FACTOR_MAX, "above max");

        // Pool yield/loan price 2% below oracle — past the 1% bound for buying
        // yield (a price-lowering swap), so the swap is skipped.
        _setPoolPrice(98, 100);

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(); // no revert; spot past bound, so no swap

        assertEq(_healthFactor(), hfBefore, "hf unchanged");
        assertEq(_debt(), debtBefore, "debt unchanged");
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "yield unchanged");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    // ---- partial rebalancing (price-impact pool) -------------------------

    /// @dev The price ratio `num/den` in Q64.192 fixed point (`num/den * 2**192`),
    ///      i.e. the square of a `sqrtPriceX96`. `_priceX192(1, 4)` is a 1:4 price.
    function _priceX192(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.mulDiv(num, 1 << 192, den);
    }

    /// @dev The `sqrtPriceX96` encoding of the price ratio `num/den`
    ///      (`sqrt(num/den) * 2**96`). `_sqrtPriceX96(99, 100)` is the sqrt price
    ///      at 99% of a 1:1 price; `_sqrtPriceX96(1, 1)` is `Q96`.
    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.sqrt(_priceX192(num, den));
    }

    /// @dev Set the yield/debt pool's spot to `num/den` (yield/loan price) in
    ///      `sqrtPriceX96` form, so tests can place spot on either side of the
    ///      oracle-derived bound. Default (1/1) is `Q96`.
    function _setPoolPrice(uint256 num, uint256 den) internal {
        yieldPool.setSqrtPriceX96(uint160(_sqrtPriceX96(num, den)));
    }

    /// @dev Etch a constant-product swap router over the swap-router address and
    ///      seed both sides of the yield/debt pair with `reserve`, giving a 1:1
    ///      spot rate (matching the 1e36 yield oracle and the pool mock's
    ///      default Q96 spot) plus size-dependent price impact. Call AFTER any
    ///      flat-rate deposit so deposit's unfloored swap runs at the clean 1:1
    ///      rate; the CPMM then governs the rebalance, honoring the
    ///      `sqrtPriceLimitX96` the vault derives from the oracle.
    function _installCpmmRouter(uint256 reserve) internal {
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockCpmmSwapRouter()).code);
        MockCpmmSwapRouter r = MockCpmmSwapRouter(address(SwapLib.SWAP_ROUTER));
        r.setReserves(address(PYUSD0), reserve);
        r.setReserves(address(FUSDEV), reserve);
    }

    /// @notice Partial delever: when selling the full delever amount would push
    ///         a shallow pool past the price bound, the pool fills only up to the
    ///         bound (a partial fill) instead of reverting. HF rises toward — but
    ///         falls short of — the lower re-entry target, debt and yield both
    ///         shrink, and no idle loan token is left behind.
    function test_Rebalance_PartialDeleverMakesProgress() public {
        _depositFor(user, 1 ether);

        marketOracle.setPrice(1700e36); // push HF below min -> delever path
        uint256 hfBefore = _healthFactor();
        assertLt(hfBefore, HEALTH_FACTOR_MIN, "below min");

        // Shallow pool: the full delever (~61e18 yield) moves the price well past
        // the 1% bound, so the pool fills only the fraction within tolerance.
        _installCpmmRouter(1000e18);

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        uint256 hfAfter = _healthFactor();
        assertGt(hfAfter, hfBefore, "delever raised HF");
        assertLt(hfAfter, HEALTH_FACTOR_MIN_TARGET, "fell short of target (partial)");
        assertLt(_debt(), debtBefore, "debt partially repaid");
        assertLt(FUSDEV.balanceOf(address(vault)), fusBefore, "yield partially sold");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle");
    }

    /// @notice Partial lever: when the full lever swap would push the pool past
    ///         the price bound, the pool fills only up to it and the vault repays
    ///         the unspent borrow, so HF falls toward — but not all the way to —
    ///         the upper re-entry target, with no idle loan token left.
    function test_Rebalance_PartialLeverMakesProgress() public {
        _depositFor(user, 1 ether);

        marketOracle.setPrice(2300e36); // push HF above max -> lever path
        uint256 hfBefore = _healthFactor();
        assertGt(hfBefore, HEALTH_FACTOR_MAX, "above max");

        _installCpmmRouter(1000e18);

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        uint256 hfAfter = _healthFactor();
        assertLt(hfAfter, hfBefore, "lever lowered HF");
        assertGt(hfAfter, HEALTH_FACTOR_MAX_TARGET, "fell short of target (partial)");
        assertGt(_debt(), debtBefore, "debt partially increased");
        assertGt(FUSDEV.balanceOf(address(vault)), fusBefore, "yield partially bought");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no loan idle (remainder repaid)");
    }

    /// @notice Loosening `maxSlippageBps` widens the price bound, admitting a
    ///         pool spot that was previously past it. With the pool 2% above
    ///         oracle, a 1% bound skips the delever (no-op); raising the bound to
    ///         5% moves the limit past spot and the delever proceeds.
    function test_Rebalance_RespectsLoosenedSlippage() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(1700e36);
        uint256 hfBefore = _healthFactor();
        assertLt(hfBefore, HEALTH_FACTOR_MIN, "below min");

        // Pool 2% above oracle: past the default 1% bound for selling yield.
        _setPoolPrice(102, 100);

        // Default 1% bound: spot is past it, so the delever is a no-op.
        vault.rebalance();
        assertEq(_healthFactor(), hfBefore, "1% bound skips: HF unchanged");

        // Loosen to 5%: the bound now sits past spot, so the delever proceeds.
        vm.prank(admin);
        vault.setMaxSlippageBps(500);

        vault.rebalance();
        assertGt(_healthFactor(), hfBefore, "5% bound admits the delever: HF raised");
    }

    // ---- price-limit math (security-critical conversion) -----------------

    /// @notice The oracle -> `sqrtPriceLimitX96` conversion matches the
    ///         oracle price discounted by `maxSlippageBps`, in both swap
    ///         directions, and tracks the oracle's magnitude (decimals baked in).
    function test_PriceLimit_OracleMathMatchesOracleAndSlippage() public {
        FCMVaultHarness h = new FCMVaultHarness(_baseParams());
        uint256 q96 = 1 << 96;

        // Default oracle is 1:1 (P_oracle = 1, oracle sqrt price = Q96) and the
        // default bound is 1%. A price-decreasing (zeroForOne) swap discounts
        // the oracle sqrt price by sqrt(1 - slip); a price-increasing one
        // divides by it. Selling the loan token is zeroForOne; selling the
        // yield token is oneForZero. At the default 1:1 spot both directions are
        // feasible, so the returned limit is the raw oracle conversion.
        uint256 sqrtFloor = _sqrtPriceX96(99, 100); // Q96*sqrt(0.99), the 1% floor
        (uint160 loStart,) = h.exposed_yieldDebtSwapLimit(address(PYUSD0)); // zeroForOne
        (uint160 hiStart,) = h.exposed_yieldDebtSwapLimit(address(FUSDEV)); // oneForZero
        assertEq(uint256(loStart), sqrtFloor, "zeroForOne = Q96*sqrt(1-slip)");
        assertEq(uint256(hiStart), Math.mulDiv(q96, q96, sqrtFloor), "oneForZero = Q96/sqrt(1-slip)");

        // The two directions differ by exactly the slippage factor 1/(1-slip).
        assertApproxEqRel(
            Math.mulDiv(uint256(hiStart), 1e18, sqrtFloor),
            uint256(1e18) * 10_000 / (10_000 - 100),
            1e12,
            "directions differ by 1/(1-slip)"
        );

        // Magnitude tracks the oracle: with yield worth 4 loan, P_oracle = 1/4
        // (yield is token1 here). Move spot to match so both legs stay feasible,
        // then limit(zeroForOne)*limit(oneForZero) ~= P_oracle*2**192.
        yieldOracle.setPrice(4e36);
        _setPoolPrice(1, 4);
        (uint160 lo,) = h.exposed_yieldDebtSwapLimit(address(PYUSD0));
        (uint160 hi,) = h.exposed_yieldDebtSwapLimit(address(FUSDEV));
        assertApproxEqRel(uint256(lo) * uint256(hi), _priceX192(1, 4), 1e12, "product ~= P_oracle*2**192");
    }

    /// @notice The swap-limit feasibility flag flips with the pool's live spot:
    ///         feasible when spot is on the tradeable side of the bound, skipped
    ///         once spot is already past it.
    function test_PriceLimit_SkipFlagTracksSpot() public {
        FCMVaultHarness h = new FCMVaultHarness(_baseParams());

        // Default spot (Q96) is within bound for both legs.
        (, bool okSellYield) = h.exposed_yieldDebtSwapLimit(address(FUSDEV));
        (, bool okBuyYield) = h.exposed_yieldDebtSwapLimit(address(PYUSD0));
        assertTrue(okSellYield, "delever feasible at 1:1 spot");
        assertTrue(okBuyYield, "lever feasible at 1:1 spot");

        // Spot 2% above oracle: selling yield (price-raising) is past the bound.
        _setPoolPrice(102, 100);
        (, okSellYield) = h.exposed_yieldDebtSwapLimit(address(FUSDEV));
        assertFalse(okSellYield, "delever skipped when spot 2% high");

        // Spot 2% below oracle: buying yield (price-lowering) is past the bound.
        _setPoolPrice(98, 100);
        (, okBuyYield) = h.exposed_yieldDebtSwapLimit(address(PYUSD0));
        assertFalse(okBuyYield, "lever skipped when spot 2% low");
    }

    /// @notice `maxSlippageBps` defaults to 1%, is admin-only, and rejects
    ///         values >= 100%.
    function test_SetMaxSlippageBps() public {
        assertEq(vault.maxSlippageBps(), 100, "default 1%");

        vm.prank(admin);
        vault.setMaxSlippageBps(250);
        assertEq(vault.maxSlippageBps(), 250, "admin updated");

        // Non-owner cannot set.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        vault.setMaxSlippageBps(300);

        // >= 100% rejected.
        vm.prank(admin);
        vm.expectRevert(FCMVault.InvalidSlippage.selector);
        vault.setMaxSlippageBps(10_000);
    }

    /// @notice `rebalance` is a no-op anywhere strictly inside the band, not
    ///         just at the midpoint. Here we nudge HF off-center (above the
    ///         midpoint but still below max); the call leaves the position
    ///         untouched. There is no longer any way to force a rebalance
    ///         inside the band — the smallest-swap policy only acts at a bound.
    function test_Rebalance_NoopWhenOffCenterButInBand() public {
        _depositFor(user, 1 ether);

        // Small collateral price increase leaves HF inside [1.25, 1.65] but above the midpoint.
        marketOracle.setPrice(2100e36);
        uint256 hfBefore = _healthFactor();
        assertGt(hfBefore, DEPOSIT_TARGET_HF, "above midpoint");
        assertLt(hfBefore, HEALTH_FACTOR_MAX, "still inside band");

        uint256 fusBefore = FUSDEV.balanceOf(address(vault));
        uint256 collBefore = WETH.balanceOf(address(MORPHO));

        vault.rebalance();

        assertEq(_healthFactor(), hfBefore, "hf unchanged");
        assertEq(FUSDEV.balanceOf(address(vault)), fusBefore, "fusdev unchanged");
        assertEq(WETH.balanceOf(address(MORPHO)), collBefore, "coll unchanged");
    }

    /// @notice A fresh deposit levers collateral to the band midpoint
    ///         `(min + max) / 2`, leaving symmetric headroom to both bounds.
    function test_Deposit_LandsAtBandMidpoint() public {
        _depositFor(user, 1 ether);
        assertApproxEqRel(_healthFactor(), DEPOSIT_TARGET_HF, 1e15, "deposit lands at midpoint");
    }

    /// @notice Liquidation recovery: a liquidator seizes most of the vault's
    ///         collateral, leaving the position under-collateralized (HF well below WAD).
    ///         `rebalance` must not revert; it sells yield on a best-effort
    ///         basis and repays as much debt as the realized loan token covers.
    function test_Rebalance_LiquidationRecoveryDoesNotRevert() public {
        _depositFor(user, 1 ether);

        // A pure collateral seizure (no debt repaid) grabs 0.7 of the 1 ether
        // collateral, leaving the position underwater with the full debt intact.
        // collateral 0.3 ether → maxBorrow 0.3 * 2000 * 0.86 = 516 vs ~1186 debt → HF ≈ 0.43.
        // No debt is repaid, so the yield leg still exactly backs the debt and harvest
        // no-ops: this exercises liquidation-recovery delevering alone.
        _liquidate({seizedCollateral: 0.7 ether, repaidAssets: 0});
        assertLt(_healthFactor(), 1e18, "underwater");

        uint256 debtBefore = _debt();
        uint256 fusBefore = FUSDEV.balanceOf(address(vault));

        // Best-effort: should succeed even though target is unreachable.
        vault.rebalance();

        // rebalance made progress: debt repaid and yield consumed.
        assertLt(_debt(), debtBefore, "debt reduced");
        assertLt(FUSDEV.balanceOf(address(vault)), fusBefore, "yield consumed");
    }

    /// @notice Constructor rejects malformed band configs: the HF band/targets
    ///         (`WAD <= min <= minTarget <= maxTarget <= max`; a below-WAD min would
    ///         allow rebalancing into a liquidatable position) and the yield-factor
    ///         band edge (`yieldFactorMax >= WAD`).
    function test_Rebalance_ConstructorValidatesBands() public {
        FCMVault.InitParams memory p = _baseParams();
        p.healthFactorMin = 0.9e18;
        vm.expectRevert(bytes("HF min < WAD"));
        new FCMVault(p);

        // min above the lower re-entry target.
        p = _baseParams();
        p.healthFactorMin = 1.35e18; // > minTarget (1.30)
        vm.expectRevert(bytes("HF min > minTarget"));
        new FCMVault(p);

        // targets crossed (minTarget above maxTarget).
        p = _baseParams();
        p.healthFactorMinTarget = 1.62e18; // > maxTarget (1.60)
        vm.expectRevert(bytes("HF minTarget > maxTarget"));
        new FCMVault(p);

        // upper re-entry target above the upper bound.
        p = _baseParams();
        p.healthFactorMaxTarget = 1.7e18; // > max (1.65)
        vm.expectRevert(bytes("HF maxTarget > max"));
        new FCMVault(p);

        // yield-factor band edge below WAD (harvest trigger below bare backing).
        p = _baseParams();
        p.yieldFactorMax = 0.9e18; // < WAD
        vm.expectRevert(bytes("yieldFactorMax < WAD"));
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
    ///         max, so the rebalance must borrow more debt and buy more
    ///         yield. We assert debt and yield grew and HF returned to the
    ///         upper re-entry target.
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
        assertApproxEqRel(_healthFactor(), DEPOSIT_TARGET_HF, 1e15, "deposit lands at midpoint HF");

        // Rebalance: price rise lifts HF above max, forcing a real lever-up.
        marketOracle.setPrice(2300e36);
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "price rise pushed HF above max");

        uint256 debtBefore = _debt();
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        assertGt(_debt(), debtBefore, "rebalance borrowed more debt");
        assertGt(FUSDEV.balanceOf(address(vault)), yieldBefore, "rebalance bought more yield");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token after rebalance");
        assertApproxEqRel(
            _healthFactor(), HEALTH_FACTOR_MAX_TARGET, 1e15, "rebalance restored HF to upper re-entry target"
        );

        // Redeem everything.
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(vault.balanceOf(user), 0, "all shares burned");
        assertEq(vault.totalSupply(), 0, "supply back to zero");
        assertEq(WETH.balanceOf(user), assetsOut, "user received redeemed asset");
        assertApproxEqRel(assetsOut, amount, 1e15, "round-trip returns ~deposit");
    }

    // VaultState logging
    // ---------------------------------------------------------------------

    /// @notice Every state-modifying entry point emits a `VaultState` snapshot
    ///         whose fields match the vault's actual post-call state: the three
    ///         leg balances read straight from Morpho/the token, and the three
    ///         oracle prices (debtPrice being the 1e36 scale itself).
    function test_VaultState_DepositEmitsSnapshot() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);

        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vm.recordLogs();
        vault.deposit(amount, user);
        vm.stopPrank();

        _assertVaultStateMatchesCurrentState();
    }

    /// @notice `redeem` emits a `VaultState` snapshot reflecting the unwound
    ///         position (less collateral, debt, and yield than before).
    function test_VaultState_RedeemEmitsSnapshot() public {
        uint256 shares = _depositFor(user, 1 ether);

        vm.recordLogs();
        vm.prank(user);
        vault.redeem(shares / 2, user, user);

        (uint256 collateral, uint256 debt, uint256 yield,,,) = _assertVaultStateMatchesCurrentState();
        // A partial redeem leaves a live position behind.
        assertGt(collateral, 0, "collateral remains");
        assertGt(debt, 0, "debt remains");
        assertGt(yield, 0, "yield remains");
    }

    /// @notice `redeemInKind` emits a `VaultState` snapshot reflecting the
    ///         in-kind exit.
    function test_VaultState_RedeemInKindEmitsSnapshot() public {
        uint256 shares = _depositFor(user, 1 ether);

        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        vm.recordLogs();
        vault.redeemInKind(shares / 2, user, user);
        vm.stopPrank();

        _assertVaultStateMatchesCurrentState();
    }

    /// @notice `rebalance` emits a `VaultState` snapshot even when it is a
    ///         no-op inside the dead band — the modifier fires after every
    ///         call regardless of whether the body mutated state.
    function test_VaultState_RebalanceNoopStillEmitsSnapshot() public {
        _depositFor(user, 1 ether);

        vm.recordLogs();
        vault.rebalance(); // HF in band → no-op body, but modifier emits

        _assertVaultStateMatchesCurrentState();
    }

    /// @notice After a lever-up rebalance, the snapshot must report the price
    ///         the rebalance saw and the grown yield leg.
    function test_VaultState_RebalanceLeverEmitsUpdatedSnapshot() public {
        _depositFor(user, 1 ether);
        marketOracle.setPrice(2300e36); // push HF above max so rebalance levers

        vm.recordLogs();
        vault.rebalance();

        (,, uint256 yield, uint256 collPrice,, uint256 yieldPrice) = _assertVaultStateMatchesCurrentState();
        assertEq(collPrice, 2300e36, "snapshot collateral price is the new oracle price");
        assertEq(yieldPrice, YIELD_PRICE, "snapshot yield price");
        assertGt(yield, 0, "yield leg present");
    }

    /// @notice The emitted prices track the live oracles: `collateralPrice` and
    ///         `yieldPrice` come from the two oracles, and `debtPrice` is the
    ///         fixed 1e36 oracle scale (debt is already in loan-token units).
    function test_VaultState_PricesReflectOracles() public {
        marketOracle.setPrice(1234e36);
        yieldOracle.setPrice(5e35);

        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        vm.recordLogs();
        vault.deposit(amount, user);
        vm.stopPrank();

        (,,, uint256 collPrice, uint256 debtPrice, uint256 yieldPrice) = _lastVaultState();
        assertEq(collPrice, 1234e36, "collateral price from market oracle");
        assertEq(debtPrice, 1e36, "debt price is the 1e36 oracle scale");
        assertEq(yieldPrice, 5e35, "yield price from yield oracle");
    }

    // ---- helpers -------------------------------------------------------

    /// @dev Decode the most recent `VaultState` event emitted by the vault from
    ///      the recorded logs. Reverts if none was emitted. Caller must have
    ///      started recording with `vm.recordLogs()` before the action.
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
        bytes32 sig = keccak256("VaultState(uint256,uint256,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != sig) {
                continue;
            }
            (collateral, debt, yield, collateralPrice, debtPrice, yieldPrice) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            found = true;
        }
        require(found, "VaultState not emitted");
    }

    /// @dev Assert the last emitted `VaultState` matches the vault's actual
    ///      current state, and return the decoded fields for further checks.
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
        assertEq(collateral, _collateral(), "collateral leg");
        // contract's market.debt() rounds up; the test helper floors → ±1 wei.
        assertApproxEqAbs(debt, _debt(), 1, "debt leg");
        assertEq(yield, FUSDEV.balanceOf(address(vault)), "yield leg");
        assertEq(collateralPrice, marketOracle.price(), "collateral price");
        assertEq(debtPrice, 1e36, "debt price (oracle scale)");
        assertEq(yieldPrice, yieldOracle.price(), "yield price");
    }

    function _collateral() internal view returns (uint256) {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        Id marketId = MarketParamsLib.id(MarketParams(lt, ct, oracle, irm, lltv_));
        return uint256(MORPHO.position(marketId, address(vault)).collateral);
    }

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
        return
            (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1)) / (uint256(mkt.totalBorrowShares) + 1e6);
    }

    /// @dev Simulate a liquidation of the vault's position via the MockMorpho
    ///      test hook: seize `seizedCollateral` of collateral and repay
    ///      `repaidAssets` of debt.
    function _liquidate(uint256 seizedCollateral, uint256 repaidAssets) internal {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        MockMorpho(address(MORPHO))
            .liquidate(MarketParams(lt, ct, oracle, irm, lltv_), address(vault), seizedCollateral, repaidAssets);
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
            yieldDebtPool: address(yieldPool),
            assetDebtPool: address(assetPool),
            healthFactorMin: HEALTH_FACTOR_MIN,
            healthFactorMax: HEALTH_FACTOR_MAX,
            healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
            healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
            yieldFactorMax: YIELD_FACTOR_MAX,
            yieldOracle: address(yieldOracle),
            admin: admin,
            recoveryDelay: 7 days,
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
        uint256 debt =
            (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1)) / (uint256(mkt.totalBorrowShares) + 1e6);
        uint256 maxBorrow =
            Math.mulDiv(uint256(pos.collateral), Math.mulDiv(marketOracle.priceValue(), lltv_, 1e36), 1e18);
        return Math.mulDiv(maxBorrow, 1e18, debt);
    }

    // ---- timelocked emergency recovery -----------------------------------

    /// @dev Fund the owner with loanToken to repay the debt, then schedule and
    ///      warp past the timelock so a recovery is executable.
    function _armRecovery() internal {
        MockERC20(address(PYUSD0)).mint(admin, 1_000_000 ether);
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();
        vm.warp(block.timestamp + vault.recoveryDelay());
    }

    /// @notice Happy path: after the timelock, the owner funds the debt and the
    ///         whole position (collateral + yield) is swept to the owner.
    function test_Recovery_ExecuteSweepsPositionToOwner() public {
        _depositFor(user, 1 ether);
        _armRecovery();

        vm.startPrank(admin);
        PYUSD0.approve(address(vault), type(uint256).max);
        vault.executeEmergencyRecovery();
        vm.stopPrank();

        assertTrue(vault.recovered(), "recovered flag set");
        assertEq(WETH.balanceOf(address(vault)), 0, "no collateral left in vault");
        assertEq(FUSDEV.balanceOf(address(vault)), 0, "no yield left in vault");
        assertGt(WETH.balanceOf(admin), 0, "owner received collateral");
        assertGt(FUSDEV.balanceOf(admin), 0, "owner received yield");
    }

    /// @notice Deposits are permanently blocked once a recovery has executed.
    function test_Recovery_BlocksDepositsAfterExecute() public {
        _depositFor(user, 1 ether);
        _armRecovery();
        vm.startPrank(admin);
        PYUSD0.approve(address(vault), type(uint256).max);
        vault.executeEmergencyRecovery();
        vm.stopPrank();

        MockERC20(address(WETH)).mint(user, 1 ether);
        vm.startPrank(user);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert(FCMVault.EmergencyRecoveryActive.selector);
        vault.deposit(1 ether, user);
        vm.stopPrank();
        // maxDeposit reflects the halt (ERC-4626: must report 0 when disabled).
        assertEq(vault.maxDeposit(user), 0, "maxDeposit 0 after execute");

        // And rebalancing reverts on the recovered vault, so the off-chain
        // rebalancer gets an explicit signal to stop.
        vm.expectRevert(FCMVault.EmergencyRecoveryActive.selector);
        vault.rebalance();
    }

    /// @notice Deposits are frozen as soon as a recovery is scheduled (before
    ///         execute), so new funds can't enter ahead of the sweep.
    function test_Recovery_BlocksDepositsWhilePending() public {
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();

        MockERC20(address(WETH)).mint(user, 1 ether);
        vm.startPrank(user);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert(FCMVault.EmergencyRecoveryActive.selector);
        vault.deposit(1 ether, user);
        vm.stopPrank();
        // maxDeposit reflects the halt (ERC-4626: must report 0 when disabled).
        assertEq(vault.maxDeposit(user), 0, "maxDeposit 0 while pending");
    }

    /// @notice The owner can cancel a pending recovery during the timelock.
    function test_Recovery_OwnerCanCancel() public {
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();
        assertGt(vault.recoveryValidAt(), 0, "scheduled");

        vm.prank(admin);
        vault.cancelEmergencyRecovery();
        assertEq(vault.recoveryValidAt(), 0, "cancelled");
    }

    /// @notice Execution reverts before the timelock elapses.
    function test_Recovery_ExecuteRevertsBeforeDelay() public {
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();
        vm.prank(admin);
        vm.expectRevert(FCMVault.EmergencyRecoveryNotReady.selector);
        vault.executeEmergencyRecovery();
    }

    /// @notice A holder can still redeem while a recovery is pending — the
    ///         timelock window is a real exit opportunity, not a lockup.
    function test_Recovery_RedeemStaysOpenWhilePending() public {
        uint256 shares = _depositFor(user, 1 ether);
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, user);
        assertGt(assets, 0, "redeem works during pending recovery");
    }

    /// @notice The escape hatch (`redeemInKind`) also stays open while a
    ///         recovery is pending — a holder can self-exit in kind throughout
    ///         the timelock window.
    function test_Recovery_RedeemInKindStaysOpenWhilePending() public {
        uint256 shares = _depositFor(user, 1 ether);
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();

        // Caller funds the debt slice and approves the vault.
        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        (uint256 collOut, uint256 yieldOut) = vault.redeemInKind(shares, user, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 0, "shares burned during pending recovery");
        assertGt(collOut, 0, "collateral delivered in kind");
        assertGt(yieldOut, 0, "yield delivered in kind");
    }

    /// @notice Only the owner may schedule or cancel a recovery.
    function test_Recovery_AccessControl() public {
        vm.prank(user);
        vm.expectRevert();
        vault.scheduleEmergencyRecovery();

        vm.prank(admin);
        vault.scheduleEmergencyRecovery();
        vm.prank(user);
        vm.expectRevert();
        vault.cancelEmergencyRecovery();
    }

    // ---- harvest (rebalance's harvest leg) -------------------------------

    /// @notice The harvest fires only when the yield factor (yield value / debt) exceeds
    ///         `yieldFactorMax`, then sells the FUSDEV above the debt backing down to bare
    ///         backing and supplies it as collateral. Add-only: debt is UNCHANGED (it never
    ///         borrows), so hf rises and NAV stays ~flat. A small surplus keeps hf in-band,
    ///         so the leverage leg is a no-op.
    function test_Rebalance_HarvestsSurplusAsCollateral() public {
        // 1:1 WETH price so the constant-rate mock is faithful across FUSDEV->PYUSD->WETH.
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);

        // Small accrued carry (+5% FUSDEV) so the added collateral keeps hf in-band.
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 20);

        uint256 navBefore = vault.totalAssets();
        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));
        uint256 debtBefore = _debt();
        uint256 hfBefore = _healthFactor();

        vault.rebalance();

        assertGt(WETH.balanceOf(address(MORPHO)), collBefore, "collateral grew");
        assertLt(FUSDEV.balanceOf(address(vault)), yieldBefore, "surplus yield sold");
        assertApproxEqAbs(_debt(), debtBefore, 1, "debt unchanged: no re-lever");
        assertGt(_healthFactor(), hfBefore, "hf rose (de-risked, not re-levered)");
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15, "NAV ~flat");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token");
    }

    /// @notice Harvest's loan->collateral leg is oracle-floored like the first leg: when the
    ///         asset/debt pool is priced past the slippage bound, the vault does not buy
    ///         collateral at the mispriced rate. The leg is skipped and the realized surplus
    ///         is repaid as debt instead (a deleverage), leaving no loan token idle.
    function test_Rebalance_HarvestSkipsMispricedCollateralLeg() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 20);

        // First leg (yield->loan) trades on `yieldPool`, still at the oracle price, so the
        // surplus is realized in loan token. The asset/debt pool, however, is dragged far past
        // the bound, so the second leg (loan->collateral) cannot execute within tolerance.
        assetPool.setSqrtPriceX96(uint160(_sqrtPriceX96(4, 1)));

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 debtBefore = _debt();
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        assertLt(FUSDEV.balanceOf(address(vault)), yieldBefore, "surplus yield sold (first leg)");
        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "no collateral bought off-oracle");
        assertLt(_debt(), debtBefore, "realized surplus repaid as debt (leg skipped)");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token");
    }

    /// @notice Harvest's loan->collateral leg partial-fills like the rebalance swaps: when
    ///         the asset/debt pool can only absorb part of the realized surplus within the
    ///         slippage bound, the vault buys what it can at tolerance, repays the remainder
    ///         as debt, and leaves no loan token idle — the split-path accounting.
    function test_Rebalance_HarvestPartialCollateralLegRepaysRemainder() public {
        // Fair loan-per-collateral sits 0.7% below the CPMM's 1:1 spot, so leg 2's
        // price-raising limit leaves only ~0.15% of pool depth of room while leg 1
        // (yield oracle at spot) keeps its full 1% — leg 1 fills, leg 2 can't.
        marketOracle.setPrice(0.993e36);
        _depositFor(user, 1 ether);
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 20);

        // Shallow CPMM on all three tokens: leg 1's ~0.03e18 surplus fits its ~0.05e18
        // cap (full fill), leg 2's cap is ~0.015e18 (partial fill).
        _installCpmmRouter(10e18);
        MockCpmmSwapRouter(address(SwapLib.SWAP_ROUTER)).setReserves(address(WETH), 10e18);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 debtBefore = _debt();
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        assertLt(FUSDEV.balanceOf(address(vault)), yieldBefore, "surplus yield sold (leg 1)");
        assertGt(WETH.balanceOf(address(MORPHO)), collBefore, "some collateral bought within tolerance");
        assertLt(_debt(), debtBefore, "unconverted remainder repaid as debt");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token");
    }

    /// @notice A surplus large enough to push hf past `healthFactorMax` triggers the
    ///         leverage leg in the same call: harvest adds collateral (hf rises above max),
    ///         then `_adjustLeverage` levers back to `maxTarget`. So debt grows here — unlike
    ///         the small-surplus case above, where harvest leaves debt unchanged.
    function test_Rebalance_HarvestThenLeversWhenSurplusLarge() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);

        // Large surplus (+50% FUSDEV) so the harvested collateral pushes hf above max.
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 2);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 debtBefore = _debt();

        vault.rebalance();

        assertGt(WETH.balanceOf(address(MORPHO)), collBefore, "harvest added collateral");
        assertGt(_debt(), debtBefore, "leverage leg fired (debt grew)");
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_MAX_TARGET, 1e15, "levered to maxTarget");
    }

    /// @notice No carry to realize right after a deposit: FUSDEV exactly backs the debt.
    function test_Rebalance_HarvestNoopWhenNoSurplus() public {
        _depositFor(user, 1 ether);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));
        uint256 debtBefore = _debt();

        vault.rebalance();

        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "collateral unchanged");
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), yieldBefore, 1, "yield unchanged");
        assertApproxEqAbs(_debt(), debtBefore, 1, "debt unchanged");
    }

    /// @notice A surplus below the yield-factor band (rho <= yieldFactorMax) does not harvest:
    ///         the band gate holds the vault in-band rather than realizing sub-threshold carry.
    function test_Rebalance_HarvestNoopBelowYieldFactorMax() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);

        // +0.5% FUSDEV -> rho = 1.005 < YIELD_FACTOR_MAX (1.01): below the band, no harvest.
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 200);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance();

        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "collateral unchanged (below band)");
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), yieldBefore, 1, "yield unchanged (below band)");
    }

    /// @notice A dust surplus whose swap output rounds to zero must no-op the harvest,
    ///         not revert the whole rebalance. The router rejects a zero-amount swap
    ///         (like UniswapV3's 'AS'), so without the zero-guard the second leg would
    ///         revert once the first leg returns nothing. Uses a `yieldFactorMax == WAD` vault
    ///         so the harvest fires on the dust; the default 1% band would gate it out before
    ///         the swap (see test_Rebalance_HarvestNoopBelowYieldFactorMax).
    function test_Harvest_NoopOnDustSurplus() public {
        marketOracle.setPrice(1e36);

        FCMVault.InitParams memory p = _baseParams();
        p.yieldFactorMax = 1e18; // WAD: harvest fires on any surplus, so the dust reaches the guard
        FCMVault dustVault = new FCMVault(p);
        vm.startPrank(admin);
        dustVault.setMaxTvl(1e21);
        dustVault.grantRole(dustVault.EARLY_ACCESS_ROLE(), user);
        vm.stopPrank();

        MockERC20(address(WETH)).mint(user, 1 ether);
        vm.startPrank(user);
        WETH.approve(address(dustVault), 1 ether);
        dustVault.deposit(1 ether, user);
        vm.stopPrank();

        // A dust surplus above the exact backing.
        MockERC20(address(FUSDEV)).mint(address(dustVault), 1000);

        // Extreme slippage tolerance + pool fee so the first swap's oracle floor and its
        // output both round to zero: loanGot == 0, tripping the no-op guard.
        vm.prank(admin);
        dustVault.setMaxSlippageBps(9999);
        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBps(9999);

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        dustVault.rebalance(); // must not revert
        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "collateral unchanged");
    }

    /// @notice The harvest no-ops when the yield token has depegged below the debt it
    ///         backs — a raw-unit surplus is not real carry.
    function test_Rebalance_HarvestNoopOnDepeg() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 20);

        yieldOracle.setPrice(YIELD_PRICE / 2); // FUSDEV worth half -> no value above debt

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));
        vault.rebalance();

        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "no harvest on depeg");
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), yieldBefore, 1, "yield unchanged");
    }

    /// @notice The harvest is frozen while a recovery is pending, but `rebalance` itself
    ///         does not revert (only an executed recovery reverts it).
    function test_Harvest_FrozenDuringPendingRecovery() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 20);

        vm.prank(admin);
        vault.scheduleEmergencyRecovery();

        uint256 collBefore = WETH.balanceOf(address(MORPHO));
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        vault.rebalance(); // does not revert while a recovery is merely pending

        assertApproxEqAbs(WETH.balanceOf(address(MORPHO)), collBefore, 1, "harvest frozen: no collateral");
        assertApproxEqAbs(FUSDEV.balanceOf(address(vault)), yieldBefore, 1, "harvest frozen: yield untouched");
    }

    /// @notice With partial-fill swaps (#72), harvest can no longer block the delever: when
    ///         the position is over-levered and the yield leg is thin, `rebalance` harvests
    ///         best-effort (partial-fill, no revert) and then delevers in the same call, so
    ///         the position's health improves rather than the whole tick reverting.
    function test_Rebalance_HarvestDoesNotBlockDelever() public {
        marketOracle.setPrice(1e36);
        _depositFor(user, 1 ether);
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 2);
        MockSwapRouter(address(SwapLib.SWAP_ROUTER)).setFeeBpsForPool(FEE_ASSET_DEBT, 300);

        marketOracle.setPrice(0.82e36); // over-levered -> delever due
        uint256 hfBefore = _healthFactor();
        assertLt(hfBefore, HEALTH_FACTOR_MIN, "below min");

        vault.rebalance(); // no revert: harvest is best-effort, then the delever fires

        assertGt(_healthFactor(), hfBefore, "position deleveraged (harvest didn't block it)");
    }

    // ---- management & performance fees ------------------------------------

    function _enableFees(address recipient, uint256 mgmtBps, uint256 perfBps) internal {
        _allow(recipient);
        vm.startPrank(admin);
        vault.setFeeRecipient(recipient);
        vault.setManagementFeeBps(mgmtBps);
        vault.setPerformanceFeeBps(perfBps);
        vm.stopPrank();
    }

    /// @notice With no recipient/rates configured, no fee shares are ever minted.
    function test_Fees_OffByDefault() public {
        _depositFor(user, 1 ether);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();
        assertEq(vault.totalSupply(), vault.balanceOf(user), "no fee shares minted");
    }

    /// @notice Only the admin can set fees, and rates are capped.
    function test_Fees_SetAccessAndCaps() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setManagementFeeBps(100);

        vm.startPrank(admin);
        vm.expectRevert(FCMVault.InvalidFee.selector);
        vault.setManagementFeeBps(1_001); // > MAX_MANAGEMENT_FEE_BPS (10%)
        vm.expectRevert(FCMVault.InvalidFee.selector);
        vault.setPerformanceFeeBps(5_001); // > MAX_PERFORMANCE_FEE_BPS (50%)
        vault.setManagementFeeBps(200);
        vault.setPerformanceFeeBps(2_000);
        vm.stopPrank();
        assertEq(vault.managementFeeBps(), 200, "mgmt set");
        assertEq(vault.performanceFeeBps(), 2_000, "perf set");
    }

    /// @notice Management fee accrues ~ rate * NAV * elapsed, minted as shares.
    function test_Fees_ManagementAccrual() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0); // 2%/yr, no perf
        _depositFor(user, 1 ether);

        uint256 nav = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        uint256 feeShares = vault.balanceOf(feeRcpt);
        assertGt(feeShares, 0, "fee shares minted");
        assertApproxEqRel(vault.convertToAssets(feeShares), nav * 200 / 10_000, 2e16, "mgmt ~2% NAV");
    }

    /// @notice Performance fee ~ rate * gain above HWM; not double-charged.
    function test_Fees_PerformanceAccrualAndHWM() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 0, 2_000); // 20% perf, no mgmt
        _depositFor(user, 1 ether);

        uint256 navBefore = vault.totalAssets();
        // Simulate yield: +10% FUSDEV in the vault -> NAV rises.
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 10);
        uint256 gain = vault.totalAssets() - navBefore;
        assertGt(gain, 0, "nav rose");

        vault.accrueFees();
        uint256 feeShares = vault.balanceOf(feeRcpt);
        assertGt(feeShares, 0, "perf fee minted");
        assertApproxEqRel(vault.convertToAssets(feeShares), gain * 2_000 / 10_000, 3e16, "perf ~20% gain");

        // Second accrual with no new gain -> no additional fee (HWM holds).
        uint256 prev = vault.balanceOf(feeRcpt);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), prev, "no double-charge above HWM");
    }

    /// @notice No performance fee while below the high-water mark (drawdown).
    function test_Fees_NoPerfInDrawdown() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 0, 2_000);
        _depositFor(user, 1 ether);

        // First gain sets the HWM and charges.
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 10);
        vault.accrueFees();
        uint256 afterFirst = vault.balanceOf(feeRcpt);
        assertGt(afterFirst, 0, "charged on first gain");

        // Drawdown: drop the yield-token price so NAV falls below the HWM.
        yieldOracle.setPrice(YIELD_PRICE / 2);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), afterFirst, "no fee in drawdown");

        // Partial recovery: price rises off the low but pps stays below the HWM —
        // rebuilding toward the prior peak still incurs no fee.
        yieldOracle.setPrice((YIELD_PRICE * 3) / 4);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), afterFirst, "no fee on sub-HWM recovery");
    }

    /// @notice If the recipient isn't allowlisted, accrual SKIPS (no mint) and
    ///         core flows are NOT bricked.
    function test_Fees_RecipientNotAllowlistedSkips() public {
        address feeRcpt = address(0xBAD);
        vm.startPrank(admin);
        vault.setFeeRecipient(feeRcpt); // deliberately NOT allowlisted
        vault.setManagementFeeBps(200);
        vault.setPerformanceFeeBps(2_000);
        vm.stopPrank();

        _depositFor(user, 1 ether); // must not revert
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees(); // must not revert
        assertEq(vault.balanceOf(feeRcpt), 0, "no shares minted to non-allowlisted recipient");
    }

    /// @notice Once recovered, fees stop accruing.
    function test_Fees_NoAccrualAfterRecovered() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0);
        _depositFor(user, 1 ether);

        MockERC20(address(PYUSD0)).mint(admin, 1_000_000 ether);
        vm.prank(admin);
        vault.scheduleEmergencyRecovery();
        vm.warp(block.timestamp + vault.recoveryDelay());
        vm.startPrank(admin);
        PYUSD0.approve(address(vault), type(uint256).max);
        vault.executeEmergencyRecovery();
        vm.stopPrank();

        uint256 prev = vault.balanceOf(feeRcpt);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), prev, "no accrual after recovered");
    }

    /// @notice Both fee legs in one accrual sum into a single dilution mint, and
    ///         the recipient's claim ~= management + performance fee.
    function test_Fees_CombinedAccrual() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 2_000); // 2%/yr mgmt + 20% perf
        _depositFor(user, 1 ether);

        uint256 nav0 = vault.totalAssets();
        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 10);
        uint256 navAccrue = vault.totalAssets();
        uint256 gain = navAccrue - nav0;
        vm.warp(block.timestamp + 365 days);

        vault.accrueFees();
        uint256 feeShares = vault.balanceOf(feeRcpt);
        assertGt(feeShares, 0, "combined fee minted");

        uint256 expected = (navAccrue * 200 / 10_000) + (gain * 2_000 / 10_000);
        assertApproxEqRel(vault.convertToAssets(feeShares), expected, 3e16, "claim ~= mgmt + perf");
    }

    /// @notice Enabling fees after a gain/elapsed window must NOT retroactively
    ///         charge the pre-enable period (guards the unconditional clock/HWM
    ///         advance; a gating change would make this fail).
    function test_Fees_NoRetroactiveChargeOnEnable() public {
        address feeRcpt = address(0xFEE5);
        _depositFor(user, 1 ether); // fees OFF

        MockERC20(address(FUSDEV)).mint(address(vault), FUSDEV.balanceOf(address(vault)) / 10);
        vm.warp(block.timestamp + 365 days);

        _enableFees(feeRcpt, 200, 2_000);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), 0, "no retroactive charge for the pre-enable window");
    }

    /// @notice Fees accrue on the redeem path, and a de-allowlisted recipient
    ///         skips minting without bricking the redeem.
    function test_Fees_AccruesOnRedeemAndDeAllowlistDoesNotBrick() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0); // mgmt only
        uint256 shares = _depositFor(user, 1 ether);

        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        vault.redeem(shares / 2, user, user);
        assertGt(vault.balanceOf(feeRcpt), 0, "fee accrued via the redeem path");

        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.revokeRole(role, feeRcpt);
        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        vault.redeem(shares / 4, user, user); // must not revert
    }

    /// @notice `accrueFees` is permissionless; the fee setters are admin-gated.
    function test_Fees_AccruePermissionlessSettersGated() public {
        _depositFor(user, 1 ether);
        vm.prank(stranger);
        vault.accrueFees(); // permissionless

        vm.prank(stranger);
        vm.expectRevert();
        vault.setFeeRecipient(stranger);
        vm.prank(stranger);
        vm.expectRevert();
        vault.setManagementFeeBps(100);
    }

    /// @notice The management accrual clamps the billable gap at one year: a
    ///         multi-year dormancy bills a single year's fee, not the full
    ///         elapsed span (unclamped, 3 years at 2%/yr would dilute ~6%).
    function test_Fees_ManagementClampedAtOneYear() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0); // 2%/yr, no perf
        _depositFor(user, 1 ether);

        uint256 nav = vault.totalAssets();
        vm.warp(block.timestamp + 3 * 365 days);
        vault.accrueFees();

        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(feeRcpt)), nav * 200 / 10_000, 2e16, "one year billed, not three"
        );
    }

    /// @notice The HWM is seeded at the initial price-per-share, so the first
    ///         deposit is not counted as performance — an immediate accrual
    ///         after the first deposit mints nothing.
    function test_Fees_NoPerfOnFirstDeposit() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 0, 2_000); // perf only
        _depositFor(user, 1 ether);

        vault.accrueFees();
        assertEq(vault.balanceOf(feeRcpt), 0, "first deposit is not performance");
    }

    /// @notice The dilution gross-up delivers the true rate: a 10%/yr management
    ///         fee over one year leaves the recipient holding exactly 10% of NAV
    ///         (not 10/1.1 ≈ 9.09%, which a non-grossed-up mint would give).
    function test_Fees_GrossUpDeliversTrueRate() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 1_000, 0); // 10%/yr, no perf
        _depositFor(user, 1 ether);

        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        // Tight tolerance: a naive (non-grossed) mint would land ~9.09%, far outside.
        uint256 recipientValue = vault.convertToAssets(vault.balanceOf(feeRcpt));
        assertApproxEqRel(recipientValue, vault.totalAssets() / 10, 1e15, "recipient holds true 10%");
    }

    /// @notice Fees accrue on the `rebalance` path — the hook runs before the
    ///         dead-band no-op check, so even a no-op rebalance meters the fee.
    function test_Fees_AccruesOnRebalance() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0); // mgmt only
        _depositFor(user, 1 ether);

        vm.warp(block.timestamp + 30 days);
        vault.rebalance(); // accrues fees at the top of rebalance
        assertGt(vault.balanceOf(feeRcpt), 0, "fee accrued via the rebalance path");
    }

    /// @notice Fees accrue on the `redeemInKind` escape-hatch path.
    function test_Fees_AccruesOnRedeemInKind() public {
        address feeRcpt = address(0xFEE5);
        _enableFees(feeRcpt, 200, 0); // mgmt only
        uint256 shares = _depositFor(user, 1 ether);

        vm.warp(block.timestamp + 30 days);
        MockERC20(address(PYUSD0)).mint(user, 1_000_000 ether);
        vm.startPrank(user);
        PYUSD0.approve(address(vault), type(uint256).max);
        vault.redeemInKind(shares / 2, user, user);
        vm.stopPrank();

        assertGt(vault.balanceOf(feeRcpt), 0, "fee accrued via the redeemInKind path");
    }
}

/// @dev Exposes the vault's internal price-limit math so the security-critical
///      oracle -> `sqrtPriceLimitX96` conversion can be asserted directly.
contract FCMVaultHarness is FCMVault {
    constructor(FCMVault.InitParams memory p) FCMVault(p) {}

    function exposed_yieldDebtSwapLimit(address tokenIn) external view returns (uint160, bool) {
        return _yieldDebtSwapLimit(tokenIn);
    }
}
