// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FCMVault, MORPHO_ADDRESS} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIrm} from "./mocks/MockIrm.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests for the TVL limit on FCMVault.
contract TvlLimitTest is Test {
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
    uint256 internal constant HEALTH_FACTOR_MIN_TARGET = 1.3e18;
    uint256 internal constant HEALTH_FACTOR_MAX_TARGET = 1.6e18;
    uint256 internal constant YIELD_FACTOR_MAX = 1.01e18;
    uint24 internal constant FEE = 100;
    uint24 internal constant FEE_ASSET_DEBT = 3000;

    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;

    MockERC20 internal asset;

    address internal admin;
    address internal owner;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant USER_BAL = 10_000;

    // Mirror the contract's events so we can use vm.expectEmit.
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        owner = admin = address(this);
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(address(WETH), erc20Code);
        vm.etch(address(PYUSD0), erc20Code);
        vm.etch(address(FUSDEV), erc20Code);
        vm.etch(MORPHO_ADDRESS, address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        marketOracle = new MockOracle(WETH_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);

        vault = new FCMVault(
            IFCMVault.InitParams({
                collateral: WETH,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                marketOracle: address(marketOracle),
                marketIrm: MOCK_IRM,
                marketLltv: LLTV,
                feeYieldDebt: FEE,
                feeAssetDebt: FEE_ASSET_DEBT,
                yieldDebtPool: address(new MockUniswapV3Pool()),
                assetDebtPool: address(new MockUniswapV3Pool()),
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
                healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
                yieldFactorMax: YIELD_FACTOR_MAX,
                yieldOracle: IOracle(address(yieldOracle)),
                admin: admin,
                recoveryDelay: 7 days,
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );
        asset = MockERC20(address(WETH));

        _fund(owner, USER_BAL);
        _allow(owner);

        _fund(alice, USER_BAL);
        _allow(alice);

        _fund(bob, USER_BAL);
        _allow(bob);
    }

    /// @dev Mint asset to `account` and approve the vault to pull it.
    function _fund(address account, uint256 amount) internal {
        asset.mint(account, amount);
        vm.prank(account);
        asset.approve(address(vault), amount);
    }

    /// @dev Grant EARLY_ACCESS_ROLE to `account`.
    function _allow(address account) internal {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.grantRole(role, account);
    }

    /// @dev Revoke EARLY_ACCESS_ROLE from `account`.
    function _disallow(address account) internal {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.revokeRole(role, account);
    }

    function _expectMaxDepositExceeded(address receiver, uint256 assets) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector, receiver, assets, vault.maxDeposit(receiver)
            )
        );
    }

    // -------------------- defaults --------------------

    function test_MaxTvlDefaultsToZero() public view {
        assertEq(vault.maxTvl(), 0, "maxTvl should default to 0");
    }

    function test_OwnerDefaultsToAdmin() public view {
        assertEq(vault.owner(), admin);
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
        vault.setMaxTvl(1000);
    }

    function test_SetMaxTvl_OwnerCanRaiseAndLower() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        assertEq(vault.maxTvl(), 1000);

        vm.prank(owner);
        vault.setMaxTvl(500);
        assertEq(vault.maxTvl(), 500);

        vm.prank(owner);
        vault.setMaxTvl(0);
        assertEq(vault.maxTvl(), 0);
    }

    function test_SetMaxTvl_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MaxTvlSet(0, 1000);
        vault.setMaxTvl(1000);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MaxTvlSet(1000, 500);
        vault.setMaxTvl(500);
    }

    // -------------------- transferOwnership --------------------

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.transferOwnership(alice);
    }

    function test_TransferOwnership_TransfersControl() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice);

        // Previous owner can no longer adjust the limit.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMaxTvl(1000);

        // New owner can.
        vm.prank(alice);
        vault.setMaxTvl(1000);
        assertEq(vault.maxTvl(), 1000);
    }

    function test_TransferOwnership_EmitsEvent() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferred(owner, alice);
        vault.acceptOwnership();
    }

    function test_RenounceOwnership_LocksLimitForever() public {
        vm.startPrank(owner);
        vault.setMaxTvl(1000);
        vault.renounceOwnership();
        assertEq(vault.owner(), address(0));

        // The limit is now frozen — no caller can change it.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setMaxTvl(2000);
        vm.stopPrank();
    }

    // -------------------- deposit() limit enforcement --------------------

    function test_Deposit_BelowLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        uint256 shares = vault.deposit(500, owner);
        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 500);
    }

    function test_Deposit_ExactlyAtLimitSucceeds() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vault.deposit(1000, owner);
        assertEq(vault.totalAssets(), 1000);
    }

    function test_Deposit_OneOverLimitReverts() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        _expectMaxDepositExceeded(owner, 1001);
        vault.deposit(1001, owner);
    }

    /// @notice Limit is global, not user-specific: alice's deposit reduces
    ///         bob's headroom. Also exercises sequential accumulation toward
    ///         the limit.
    function test_Deposit_LimitIsGlobalAcrossUsers() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);

        vm.prank(alice);
        vault.deposit(600, alice);

        _expectMaxDepositExceeded(bob, 500);
        vm.prank(bob);
        vault.deposit(500, bob);

        // Bob can still deposit up to the remaining 400.
        vm.prank(bob);
        vault.deposit(400, bob);
        assertEq(vault.totalAssets(), 1000);
    }

    function testFuzz_Deposit_RespectsLimit(uint96 limit, uint96 amount) public {
        // Bound inputs so we isolate limit enforcement from balance/allowance
        // failures. Amount is >= 1: a zero deposit reverts in Morpho (ZERO_ASSETS),
        // unrelated to limit enforcement.
        limit = uint96(bound(uint256(limit), 0, USER_BAL));
        amount = uint96(bound(uint256(amount), 1, USER_BAL));

        vm.prank(owner);
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
        vm.prank(owner);
        vault.setMaxTvl(1000);
        assertEq(vault.maxDeposit(owner), 1000);
        assertEq(vault.maxDeposit(alice), 1000, "limit is global, not per-receiver");

        vault.deposit(400, owner);
        assertEq(vault.maxDeposit(owner), 600);
        assertEq(vault.maxDeposit(alice), 600);
    }

    function test_MaxDeposit_ZeroWhenAtLimit() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vault.deposit(1000, owner);
        assertEq(vault.maxDeposit(owner), 0);
    }

    /// @notice If the admin lowers the limit below current TVL, `maxDeposit`
    ///         must clamp to 0 rather than underflow, and new deposits must
    ///         revert. Existing TVL stays put — the limit is not retroactive.
    function test_MaxDeposit_ClampsToZeroWhenLimitLoweredBelowTvl() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vault.deposit(800, owner);

        vm.prank(owner);
        vault.setMaxTvl(500);
        assertEq(vault.maxDeposit(owner), 0);
        assertEq(vault.totalAssets(), 800, "existing TVL must not be forcibly unwound");

        _expectMaxDepositExceeded(owner, 1);
        vault.deposit(1, owner);
    }

    /// @notice Raising the limit unblocks new deposits up to the new room.
    function test_MaxDeposit_TracksLimitChanges() public {
        vm.prank(owner);
        vault.setMaxTvl(1000);
        vault.deposit(1000, owner);
        assertEq(vault.maxDeposit(owner), 0);

        vm.prank(owner);
        vault.setMaxTvl(2500);
        assertEq(vault.maxDeposit(owner), 1500);

        vault.deposit(1500, owner);
        assertEq(vault.totalAssets(), 2500);
        assertEq(vault.maxDeposit(owner), 0);
    }

    // -------------------- mint() disabled --------------------

    function test_Mint_AlwaysReverts() public {
        // `mint` is disabled via `maxMint()` returning 0, independent of TVL limit.
        vm.prank(owner);
        vault.setMaxTvl(10_000);
        vm.expectRevert();
        vault.mint(1, owner);
    }

    function test_MaxMint_AlwaysZero() public {
        // `maxMint` is independent of TVL limit.
        vm.prank(owner);
        vault.setMaxTvl(10_000);
        assertEq(vault.maxMint(owner), 0);
    }
}
