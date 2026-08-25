// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVaultFactory} from "../src/FCMVaultFactory.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {IFCMVaultFactory} from "../src/interfaces/IFCMVaultFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIrm} from "./mocks/MockIrm.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {Test} from "forge-std/Test.sol";

contract FCMVaultFactoryTest is Test {
    // Real Flow EVM addresses for mocking.
    address constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0 = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant FUSDEV = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;

    uint256 constant WETH_PRICE = 2000e36;
    uint256 constant YIELD_PRICE = 1e36;

    uint256 constant MARKET_LLTV = 0.86e18;

    address constant MOCK_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;
    address constant MORPHO = 0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f;
    address constant SWAP_ROUTER = 0xeEDC6Ff75e1b10B903D9013c358e446a73d35341;

    FCMVaultFactory internal factory;
    address internal marketOracle;
    address internal yieldOracle;
    address internal collateralLoanPool;
    address internal yieldLoanPool;
    IFCMVault.InitParams internal initParams;
    bytes32 internal salt = bytes32(uint256(0xA11CE));
    bytes32 internal salt2 = bytes32(uint256(0xB0B));
    address internal deployer = address(0xCA401);

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20("erc20", "erc20")).code;
        vm.etch(WETH, erc20Code);
        vm.etch(PYUSD0, erc20Code);
        vm.etch(FUSDEV, erc20Code);
        vm.etch(MORPHO, address(new MockMorpho()).code);
        vm.etch(SWAP_ROUTER, address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        marketOracle = address(new MockOracle(WETH_PRICE));
        yieldOracle = address(new MockOracle(YIELD_PRICE));
        yieldLoanPool = address(new MockPool());
        collateralLoanPool = address(new MockPool());

        factory = new FCMVaultFactory();

        initParams = IFCMVault.InitParams({
            collateralToken: WETH,
            loanToken: PYUSD0,
            yieldToken: FUSDEV,
            ltvMin: 0.6e18,
            ltvMax: 0.7e18,
            collateralLoanPool: collateralLoanPool,
            yieldLoanPool: yieldLoanPool,
            collateralOracle: marketOracle,
            marketIrm: MOCK_IRM,
            marketLltv: MARKET_LLTV,
            yieldOracle: yieldOracle,
            morpho: MORPHO,
            swapRouter: SWAP_ROUTER,
            owner: deployer,
            name: "Flow Credit Markets WETH",
            symbol: "fcmWETH"
        });
    }

    function test_vaultFactory_createVaultDeploysVault() public {
        vm.prank(deployer);
        address vault = factory.createVault(initParams, salt);

        assertTrue(vault != address(0));
        assertGt(vault.code.length, 0);
    }

    function test_vaultFactory_createVaultEmitsEvent() public {
        address expected = factory.computeAddress(initParams, salt);

        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IFCMVaultFactory.VaultCreated(deployer, salt, expected);

        factory.createVault(initParams, salt);
    }

    function test_vaultFactory_computeAddressMatchesDeployed() public {
        address predicted = factory.computeAddress(initParams, salt);

        vm.prank(deployer);
        address deployed = factory.createVault(initParams, salt);

        assertEq(predicted, deployed);
    }

    function test_vaultFactory_computeAddressDifferentSaltDifferentAddress() public view {
        address predicted1 = factory.computeAddress(initParams, salt);
        address predicted2 = factory.computeAddress(initParams, salt2);

        assertTrue(predicted1 != predicted2);
    }

    function test_vaultFactory_createVaultSameSaltReverts() public {
        vm.prank(deployer);
        factory.createVault(initParams, salt);

        vm.prank(deployer);
        vm.expectRevert();
        factory.createVault(initParams, salt);
    }
}
