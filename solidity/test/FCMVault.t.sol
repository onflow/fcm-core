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
    uint256 internal constant HEALTH_FACTOR_TARGET = 1.45e18;
    uint24 internal constant FEE = 100;

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
                healthFactorUpperTarget: HEALTH_FACTOR_TARGET,
                yieldOracle: address(yieldOracle),
                admin: admin,
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );

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
}
