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
}
