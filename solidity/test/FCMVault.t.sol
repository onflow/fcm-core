// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {FCMVault} from "../src/FCMVault.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FCMVaultTest is Test {
    FCMVault public vault;
    MockERC20 public asset;

    address internal admin = address(0x12345);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal stranger = address(0x5_7A);

    uint256 internal constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        asset = new MockERC20();
        vault = new FCMVault("Flow Credit Markets Vault", "fcmV", IERC20(address(asset)), admin);
    }

    /// @dev Mint asset to `account` and approve the vault to pull it.
    function _fund(address account, uint256 amount) internal {
        asset.mint(account, amount);
        vm.prank(account);
        asset.approve(address(vault), amount);
    }

    /// @dev Grant ALLOWED_ROLE to `account`.
    function _allow(address account) internal {
        bytes32 role = vault.ALLOWED_ROLE();
        vm.prank(admin);
        vault.grantRole(role, account);
    }

    /// @dev Revoke ALLOWED_ROLE from `account`.
    function _disallow(address account) internal {
        bytes32 role = vault.ALLOWED_ROLE();
        vm.prank(admin);
        vault.revokeRole(role, account);
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @notice Vault stores the asset address from the constructor.
    function test_AssetIsSet() public view {
        assertEq(vault.asset(), address(asset));
    }

    /// @notice Admin gets DEFAULT_ADMIN_ROLE on construction; no one starts allowlisted.
    function test_InitialRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(vault.hasRole(vault.ALLOWED_ROLE(), alice));
    }

    /// @notice Gating is on by default — must be explicitly disabled for GA.
    function test_GatingEnabledByDefault() public view {
        assertTrue(vault.gatingEnabled());
    }

    // ---------------------------------------------------------------------
    // Role administration
    // ---------------------------------------------------------------------

    /// @notice Admin can grant ALLOWED_ROLE; hasRole reflects the grant.
    function test_AdminCanGrantRole() public {
        _allow(alice);
        assertTrue(vault.hasRole(vault.ALLOWED_ROLE(), alice));
    }

    /// @notice Admin can revoke ALLOWED_ROLE; hasRole reflects the revoke.
    function test_AdminCanRevokeRole() public {
        _allow(alice);
        _disallow(alice);
        assertFalse(vault.hasRole(vault.ALLOWED_ROLE(), alice));
    }

    /// @notice Non-admin cannot grant ALLOWED_ROLE.
    function test_NonAdminCannotGrantRole() public {
        bytes32 role = vault.ALLOWED_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        vault.grantRole(role, alice);
    }

    /// @notice AccessControlEnumerable exposes member enumeration.
    function test_EnumeratesAllowedMembers() public {
        _allow(alice);
        _allow(bob);
        bytes32 role = vault.ALLOWED_ROLE();
        assertEq(vault.getRoleMemberCount(role), 2);
        address m0 = vault.getRoleMember(role, 0);
        address m1 = vault.getRoleMember(role, 1);
        assertTrue((m0 == alice && m1 == bob) || (m0 == bob && m1 == alice));
    }

    // ---------------------------------------------------------------------
    // Deposit gating
    // ---------------------------------------------------------------------

    /// @notice maxDeposit returns 0 for a non-allowlisted receiver while gating is on.
    function test_MaxDepositZeroForNonAllowlisted() public view {
        assertEq(vault.maxDeposit(alice), 0);
    }

    /// @notice maxDeposit returns the underlying max once the receiver is allowlisted.
    function test_MaxDepositNonZeroForAllowlisted() public {
        _allow(alice);
        assertGt(vault.maxDeposit(alice), 0);
    }

    /// @notice maxMint is similarly gated.
    function test_MaxMintZeroForNonAllowlisted() public view {
        assertEq(vault.maxMint(alice), 0);
    }

    /// @notice An allowlisted user can deposit.
    function test_AllowlistedUserCanDeposit() public {
        _allow(alice);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(asset.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    /// @notice Deposit reverts at the ERC4626 layer when the receiver of shares
    ///         is not allowlisted — because maxDeposit() returns 0 for them.
    function test_DepositRevertsForNonAllowlistedReceiver() public {
        _allow(alice);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector, bob, DEPOSIT_AMOUNT, 0
            )
        );
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, bob);
    }

    // ---------------------------------------------------------------------
    // Transfer gating
    // ---------------------------------------------------------------------

    /// @notice Transfers between allowlisted holders succeed.
    function test_TransferBetweenAllowlistedHoldersSucceeds() public {
        _allow(alice);
        _allow(bob);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(alice);
        vault.transfer(bob, shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), shares);
    }

    /// @notice Transfer reverts when the recipient is not allowlisted.
    function test_TransferRevertsForNonAllowlistedRecipient() public {
        _allow(alice);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, vault.ALLOWED_ROLE()
            )
        );
        vm.prank(alice);
        vault.transfer(bob, shares);
    }

    /// @notice Transfer reverts when the sender has been de-allowlisted, even
    ///         though they still hold shares.
    function test_TransferRevertsForDeAllowlistedSender() public {
        _allow(alice);
        _allow(bob);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        _disallow(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                vault.ALLOWED_ROLE()
            )
        );
        vm.prank(alice);
        vault.transfer(bob, shares);
    }

    // ---------------------------------------------------------------------
    // Burn / exit path
    // ---------------------------------------------------------------------

    /// @notice A de-allowlisted holder can still withdraw their assets.
    function test_DeAllowlistedHolderCanWithdraw() public {
        _allow(alice);
        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // Remove alice from the allowlist — she should still be able to exit.
        _disallow(alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        assertEq(assetsBack, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), DEPOSIT_AMOUNT);
    }

    // ---------------------------------------------------------------------
    // gatingEnabled toggle
    // ---------------------------------------------------------------------

    /// @notice Admin can disable gating; the vault then accepts any depositor.
    function test_GatingDisabledAllowsAnyDeposit() public {
        vm.prank(admin);
        vault.setGatingEnabled(false);

        _fund(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    /// @notice With gating disabled, maxDeposit no longer returns 0 for non-allowlisted.
    function test_GatingDisabledMaxDepositNonZero() public {
        vm.prank(admin);
        vault.setGatingEnabled(false);
        assertGt(vault.maxDeposit(alice), 0);
    }

    /// @notice With gating disabled, share transfers between any holders succeed.
    function test_GatingDisabledAllowsAnyTransfer() public {
        vm.prank(admin);
        vault.setGatingEnabled(false);

        _fund(alice, DEPOSIT_AMOUNT);
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(alice);
        vault.transfer(bob, shares);
        assertEq(vault.balanceOf(bob), shares);
    }

    /// @notice setGatingEnabled emits GatingEnabledSet.
    function test_SetGatingEnabledEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit FCMVault.GatingEnabledSet(false);
        vm.prank(admin);
        vault.setGatingEnabled(false);
    }

    /// @notice Non-admin cannot toggle gating.
    function test_NonAdminCannotSetGatingEnabled() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        vault.setGatingEnabled(false);
    }
}
