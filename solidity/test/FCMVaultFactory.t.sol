// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {MORPHO_ADDRESS} from "../src/FCMVault.sol";
import {FCMVaultFactory} from "../src/FCMVaultFactory.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {IFCMVaultFactory} from "../src/interfaces/IFCMVaultFactory.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIrm} from "./mocks/MockIrm.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";

contract FCMVaultFactoryTest is Test {
    // Real Flow EVM addresses for mocking.
    address constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0 = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant FUSDEV = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;
    address constant MOCK_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;

    uint256 constant WETH_PRICE = 2000e36;
    uint256 constant YIELD_PRICE = 1e36;
    uint256 constant LLTV = 0.86e18;

    FCMVaultFactory internal factory;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;
    MockUniswapV3Pool internal yieldPool;
    MockUniswapV3Pool internal assetPool;
    IFCMVault.InitParams internal initParams;
    bytes32 internal salt = bytes32(uint256(0xA11CE));
    bytes32 internal salt2 = bytes32(uint256(0xB0B));
    address internal deployer = address(0xCA401);

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(WETH, erc20Code);
        vm.etch(PYUSD0, erc20Code);
        vm.etch(FUSDEV, erc20Code);
        vm.etch(address(MORPHO_ADDRESS), address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        marketOracle = new MockOracle(WETH_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);
        yieldPool = new MockUniswapV3Pool();
        assetPool = new MockUniswapV3Pool();

        factory = new FCMVaultFactory();

        initParams = IFCMVault.InitParams({
            collateral: IERC20(WETH),
            loanToken: IERC20(PYUSD0),
            yieldToken: IERC20(FUSDEV),
            marketOracle: address(marketOracle),
            marketIrm: MOCK_IRM,
            marketLltv: LLTV,
            feeYieldDebt: 100,
            feeAssetDebt: 3000,
            yieldDebtPool: address(yieldPool),
            assetDebtPool: address(assetPool),
            healthFactorMin: 1.25e18,
            healthFactorMax: 1.65e18,
            healthFactorMinTarget: 1.3e18,
            healthFactorMaxTarget: 1.6e18,
            yieldFactorMax: 1.01e18,
            yieldOracle: IOracle(address(yieldOracle)),
            admin: deployer,
            recoveryDelay: 7 days,
            name: "Flow Credit Markets WETH",
            symbol: "fcmWETH"
        });
    }

    function test_CreateVault_DeploysVault() public {
        vm.prank(deployer);
        address vault = factory.createVault(initParams, salt);

        // Deployed address is non-zero and has code.
        assertTrue(vault != address(0));
        assertGt(vault.code.length, 0);
    }

    function test_CreateVault_EmitsEvent() public {
        address expected = factory.computeAddress(initParams, salt);

        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IFCMVaultFactory.VaultCreated(deployer, salt, expected);

        factory.createVault(initParams, salt);
    }

    function test_ComputeAddress_MatchesDeployed() public {
        address predicted = factory.computeAddress(initParams, salt);

        vm.prank(deployer);
        address deployed = factory.createVault(initParams, salt);

        assertEq(predicted, deployed);
    }

    function test_ComputeAddress_DifferentSaltDifferentAddress() public view {
        address predicted1 = factory.computeAddress(initParams, salt);
        address predicted2 = factory.computeAddress(initParams, salt2);

        assertTrue(predicted1 != predicted2);
    }

    function test_CreateVault_SameSaltReverts() public {
        vm.prank(deployer);
        factory.createVault(initParams, salt);

        // CREATE2 with the same salt and bytecode reverts.
        vm.prank(deployer);
        vm.expectRevert();
        factory.createVault(initParams, salt);
    }
}
