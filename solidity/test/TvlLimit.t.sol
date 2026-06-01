// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCMVault} from "../src/FCMVault.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Tests for the TVL limit on FCMVault.
contract TvlLimitTest is Test {
    FCMVault public vault;
    MockERC20 public asset;

    address internal owner;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant USER_BAL = 10_000;

    // Mirror the contract's events so we can use vm.expectEmit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        owner = address(this);
        asset = new MockERC20();
        vault = new FCMVault("Flow Credit Markets Vault", "fcmV", IERC20(address(asset)));

        asset.mint(owner, USER_BAL);
        asset.approve(address(vault), type(uint256).max);

        asset.mint(alice, USER_BAL);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        asset.mint(bob, USER_BAL);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    function _expectMaxDepositExceeded(address receiver, uint256 assets) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector,
                receiver,
                assets,
                vault.maxDeposit(receiver)
            )
        );
    }

    // -------------------- defaults --------------------

    function test_MaxTvlDefaultsToZero() public view {
        assertEq(vault.maxTvl(), 0, "maxTvl should default to 0");
    }

    function test_OwnerDefaultsToDeployer() public view {
        assertEq(vault.owner(), owner);
    }

    function test_LimitStartsAtZero_DepositReverts() public {
        _expectMaxDepositExceeded(owner, 1);
        vault.deposit(1, owner);
    }

    function test_LimitStartsAtZero_MaxDepositIsZero() public view {
        assertEq(vault.maxDeposit(owner), 0);
    }

    // -------------------- setMaxTvl --------------------

    function test_SetMaxTvl_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMaxTvl(1_000);
    }

    function test_SetMaxTvl_OwnerCanRaiseAndLower() public {
        vault.setMaxTvl(1_000);
        assertEq(vault.maxTvl(), 1_000);

        vault.setMaxTvl(500);
        assertEq(vault.maxTvl(), 500);

        vault.setMaxTvl(0);
        assertEq(vault.maxTvl(), 0);
    }

    function test_SetMaxTvl_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit MaxTvlSet(0, 1_000);
        vault.setMaxTvl(1_000);

        vm.expectEmit(false, false, false, true, address(vault));
        emit MaxTvlSet(1_000, 500);
        vault.setMaxTvl(500);
    }

    // -------------------- transferOwnership --------------------

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.transferOwnership(alice);
    }

    function test_TransferOwnership_TransfersControl() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);

        // Previous owner can no longer adjust the limit.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMaxTvl(1_000);

        // New owner can.
        vm.prank(alice);
        vault.setMaxTvl(1_000);
        assertEq(vault.maxTvl(), 1_000);
    }

    function test_TransferOwnership_EmitsEvent() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferred(owner, alice);
        vault.transferOwnership(alice);
    }

    function test_RenounceOwnership_LocksLimitForever() public {
        vault.setMaxTvl(1_000);
        vault.transferOwnership(address(0));
        assertEq(vault.owner(), address(0));

        // The limit is now frozen — no caller can change it.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMaxTvl(2_000);
    }

    // -------------------- deposit() limit enforcement --------------------

    function test_Deposit_BelowLimitSucceeds() public {
        vault.setMaxTvl(1_000);
        uint256 shares = vault.deposit(500, owner);
        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 500);
    }

    function test_Deposit_ExactlyAtLimitSucceeds() public {
        vault.setMaxTvl(1_000);
        vault.deposit(1_000, owner);
        assertEq(vault.totalAssets(), 1_000);
    }

    function test_Deposit_OneOverLimitReverts() public {
        vault.setMaxTvl(1_000);
        _expectMaxDepositExceeded(owner, 1_001);
        vault.deposit(1_001, owner);
    }

    /// @notice Limit is global, not user-specific: alice's deposit reduces
    ///         bob's headroom. Also exercises sequential accumulation toward
    ///         the limit.
    function test_Deposit_LimitIsGlobalAcrossUsers() public {
        vault.setMaxTvl(1_000);

        vm.prank(alice);
        vault.deposit(600, alice);

        _expectMaxDepositExceeded(bob, 500);
        vm.prank(bob);
        vault.deposit(500, bob);

        // Bob can still deposit up to the remaining 400.
        vm.prank(bob);
        vault.deposit(400, bob);
        assertEq(vault.totalAssets(), 1_000);
    }

    function testFuzz_Deposit_RespectsLimit(uint96 limit, uint96 amount) public {
        // Bound inputs so we isolate limit enforcement from balance/allowance
        // failures.
        limit = uint96(bound(uint256(limit), 0, USER_BAL));
        amount = uint96(bound(uint256(amount), 0, USER_BAL));

        vault.setMaxTvl(limit);
        if (amount <= limit) {
            vault.deposit(amount, owner);
            assertEq(vault.totalAssets(), amount);
        } else {
            _expectMaxDepositExceeded(owner, amount);
            vault.deposit(amount, owner);
            assertEq(vault.totalAssets(), 0);
        }
    }

    // -------------------- maxDeposit() --------------------

    /// @dev Returned value of `maxDeposit` should reflect the remaining limit.
    function test_MaxDeposit_ReturnsRemainingCapacity() public {
        vault.setMaxTvl(1_000);
        assertEq(vault.maxDeposit(owner), 1_000);
        assertEq(vault.maxDeposit(alice), 1_000, "limit is global, not per-receiver");

        vault.deposit(400, owner);
        assertEq(vault.maxDeposit(owner), 600);
        assertEq(vault.maxDeposit(alice), 600);
    }

    function test_MaxDeposit_ZeroWhenAtLimit() public {
        vault.setMaxTvl(1_000);
        vault.deposit(1_000, owner);
        assertEq(vault.maxDeposit(owner), 0);
    }

    /// @notice If the admin lowers the limit below current TVL, `maxDeposit`
    ///         must clamp to 0 rather than underflow, and new deposits must
    ///         revert. Existing TVL stays put — the limit is not retroactive.
    function test_MaxDeposit_ClampsToZeroWhenLimitLoweredBelowTvl() public {
        vault.setMaxTvl(1_000);
        vault.deposit(800, owner);

        vault.setMaxTvl(500);
        assertEq(vault.maxDeposit(owner), 0);
        assertEq(vault.totalAssets(), 800, "existing TVL must not be forcibly unwound");

        _expectMaxDepositExceeded(owner, 1);
        vault.deposit(1, owner);
    }

    /// @notice Raising the limit unblocks new deposits up to the new room.
    function test_MaxDeposit_TracksLimitChanges() public {
        vault.setMaxTvl(1_000);
        vault.deposit(1_000, owner);
        assertEq(vault.maxDeposit(owner), 0);

        vault.setMaxTvl(2_500);
        assertEq(vault.maxDeposit(owner), 1_500);

        vault.deposit(1_500, owner);
        assertEq(vault.totalAssets(), 2_500);
        assertEq(vault.maxDeposit(owner), 0);
    }

    // -------------------- mint() disabled --------------------

    function test_Mint_AlwaysReverts() public {
        // `mint` is disabled via `maxMint()` returning 0, independent of TVL limit.
        vault.setMaxTvl(10_000);
        vm.expectRevert();
        vault.mint(1, owner);
    }

    function test_MaxMint_AlwaysZero() public {
        // `maxMint` is independent of TVL limit.
        vault.setMaxTvl(10_000);
        assertEq(vault.maxMint(owner), 0);
    }
}
