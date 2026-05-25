// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {FCMVault, WETH, PYUSD0, FUSDEV, MORPHO, MARKET_IRM} from "../src/FCMVault.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockIrm} from "./mocks/MockIrm.sol";

contract FCMVaultTest is Test {
    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;

    address internal user = address(0xA11CE);

    uint256 internal constant WETH_PRICE = 2000e36;
    uint256 internal constant YIELD_PRICE = 1e36;

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(address(WETH), erc20Code);
        vm.etch(address(PYUSD0), erc20Code);
        vm.etch(address(FUSDEV), erc20Code);
        vm.etch(address(MORPHO), address(new MockMorpho()).code);
        vm.etch(
            address(SwapLib.SWAP_ROUTER),
            address(new MockSwapRouter()).code
        );
        vm.etch(MARKET_IRM, address(new MockIrm()).code);

        marketOracle = new MockOracle(WETH_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);

        vault = new FCMVault(address(marketOracle), address(yieldOracle));
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
        assertApproxEqAbs(
            FUSDEV.balanceOf(address(vault)),
            expectedBorrow,
            1,
            "vault fusdev"
        );
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

    /// @dev Helper: deposit `amount` WETH on behalf of `who` and return shares.
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

    /// @notice withdraw(assets) computes shares via previewWithdraw and
    /// delegates to redeem. The number of shares it burned must equal
    /// previewWithdraw(assets) computed pre-call.
    function test_Withdraw_DelegatesToRedeem() public {
        uint256 amount = 1 ether;
        _depositFor(user, amount);

        uint256 target = amount / 2;
        uint256 expectedShares = vault.previewWithdraw(target);
        uint256 sharesBefore = vault.balanceOf(user);

        vm.prank(user);
        uint256 sharesBurned = vault.withdraw(target, user, user);

        assertEq(sharesBurned, expectedShares, "shares matches preview");
        assertEq(vault.balanceOf(user), sharesBefore - expectedShares, "shares burned");
        assertGt(WETH.balanceOf(user), 0, "user got weth");
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
}
