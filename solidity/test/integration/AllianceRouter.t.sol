// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FCMVault, MORPHO} from "../../src/FCMVault.sol";
import {SwapLib} from "../../src/libraries/SwapLib.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockIrm} from "../mocks/MockIrm.sol";

/// @dev Minimal view of the Alliance `ERC4626Router` we exercise. Declared
///      locally because the router is pinned to solc 0.8.10 and cannot share a
///      compilation unit with this 0.8.20 test; `IERC4626`/`ERC20` params
///      canonicalize to `address`, so these selectors match the real contract.
///      The router itself is deployed from its real bytecode via `vm.deployCode`
///      (the artifact is built by `_AllianceRouterCompile.sol`).
interface IAllianceRouter {
    function approve(address token, address to, uint256 amount) external payable;
    function depositToVault(address vault, address to, uint256 amount, uint256 minSharesOut)
        external
        payable
        returns (uint256 sharesOut);
    function redeem(address vault, address to, uint256 shares, uint256 minAmountOut)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Integration tests proving FCMVault works behind the off-chain
///         Alliance ERC4626 router (the user-facing slippage layer, issue #5):
///         the user-supplied min-out is enforced on both deposit and redeem,
///         and the allowlist is not bypassed (a deposit crediting a
///         non-allowlisted receiver reverts), all against the router's real
///         deployed bytecode.
/// @dev    Run via a full `forge test`; a filtered run skips the 0.8.10 router
///         compile anchor (see `_AllianceRouterCompile.sol`).
contract AllianceRouterIntegrationTest is Test {
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
    IAllianceRouter internal router;

    address internal admin = address(0x12345);
    address internal user = address(0xA11CE);
    address internal stranger = address(0x5_7A); // never allowlisted

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(address(WETH), erc20Code);
        vm.etch(address(PYUSD0), erc20Code);
        vm.etch(address(FUSDEV), erc20Code);
        vm.etch(address(MORPHO), address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        vault = new FCMVault(
            FCMVault.InitParams({
                collateral: WETH,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                marketOracle: address(new MockOracle(WETH_PRICE)),
                marketIrm: MOCK_IRM,
                marketLltv: LLTV,
                feeYieldDebt: FEE,
                feeAssetDebt: FEE_ASSET_DEBT,
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorTarget: HEALTH_FACTOR_TARGET,
                yieldOracle: address(new MockOracle(YIELD_PRICE)),
                admin: admin,
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );

        // `maxTvl` defaults to 0, which makes `maxDeposit` return 0; lift it so
        // deposits are allowed (owner-gated, mirrors the unit-test setup).
        vm.prank(admin);
        vault.setMaxTvl(type(uint256).max);

        _allow(user);

        // Deploy the real router bytecode. Empty name skips the ENS reverse
        // record; the WETH9 arg is only used by unused wrap/unwrap paths.
        router = IAllianceRouter(
            deployCode("ERC4626Router.sol:ERC4626Router", abi.encode("", address(WETH)))
        );
        // One-time: let the router supply the asset into the vault on deposits.
        router.approve(address(WETH), address(vault), type(uint256).max);
    }

    // ---- deposit: user-supplied floor is enforced --------------------------

    function test_Router_Deposit_RevertsBelowMinShares() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(router), amount);
        // First deposit mints exactly amount * 1e6 shares; ask for one more.
        vm.expectRevert();
        router.depositToVault(address(vault), user, amount, amount * 1e6 + 1);
        vm.stopPrank();
    }

    function test_Router_Deposit_SucceedsAtFloor() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(router), amount);
        uint256 shares = router.depositToVault(address(vault), user, amount, amount * 1e6);
        vm.stopPrank();

        assertEq(shares, amount * 1e6, "shares minted");
        assertEq(vault.balanceOf(user), shares, "shares to user, not router");
        assertEq(vault.balanceOf(address(router)), 0, "router holds no shares");
        assertEq(WETH.balanceOf(address(router)), 0, "no asset dust left in router");
    }

    // ---- redeem: user-supplied floor is enforced, via the allowance path ---

    function test_Router_Redeem_RevertsBelowMinAssets() public {
        uint256 amount = 1 ether;
        uint256 shares = _deposit(user, amount);
        vm.startPrank(user);
        vault.approve(address(router), shares); // approve the ROUTER to spend shares
        // Round-trip returns ~amount; demand far more.
        vm.expectRevert();
        router.redeem(address(vault), user, shares, amount + 1 ether);
        vm.stopPrank();
    }

    function test_Router_Redeem_SucceedsAtFloor() public {
        uint256 amount = 1 ether;
        uint256 shares = _deposit(user, amount);
        vm.startPrank(user);
        vault.approve(address(router), shares);
        uint256 out = router.redeem(address(vault), user, shares, 0);
        vm.stopPrank();

        assertApproxEqAbs(out, amount, 1, "assets out ~ deposit");
        assertEq(WETH.balanceOf(user), out, "user received the asset");
        assertEq(vault.balanceOf(user), 0, "shares burned");
    }

    // ---- allowlist interaction ---------------------------------------------

    /// @notice Minting is still gated through the router: a deposit crediting a
    ///         non-allowlisted receiver reverts, so the router can't bypass it.
    function test_Router_Deposit_ToNonAllowlistedReverts() public {
        uint256 amount = 1 ether;
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(router), amount);
        vm.expectRevert(); // AccessControlUnauthorizedAccount on the mint to `stranger`
        router.depositToVault(address(vault), stranger, amount, 0);
        vm.stopPrank();
    }

    // ---- helpers -----------------------------------------------------------

    function _allow(address account) internal {
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.grantRole(role, account);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        MockERC20(address(WETH)).mint(who, amount);
        vm.startPrank(who);
        WETH.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }
}
