// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract ForkDeployers is Test {
    using FCMHelpers for FCMVault;
    uint256 internal constant Q96 = 1 << 96;

    IERC20 constant WBTC = IERC20(0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);

    uint128 constant LTV_MIN = 0.6e18;
    uint128 constant LTV_MIN_TARGET = 0.61e18;
    uint128 constant LTV_MAX = 0.7e18;
    uint128 constant LTV_MAX_TARGET = 0.69e18;
    uint128 constant YIELD_TO_LOAN_MAX = 1.01e18;

    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    uint24 constant COLLATERAL_LOAN_POOL_FEE = 3000;
    uint24 constant YIELD_LOAN_POOL_FEE = 100;

    IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);
    ISwapRouter02 constant SWAP_ROUTER = ISwapRouter02(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);
    IOracle constant COLLATERAL_ORACLE = IOracle(0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8);
    address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;
    uint256 constant MARKET_LLTV = 0.86e18;
    IOracle constant YIELD_ORACLE = IOracle(0x144F613490DD55C9844Ef139CFB9B63433dD349F);

    uint256 constant COLLATERAL_PRICE = 80_000e34;
    uint256 constant YIELD_PRICE = 1e24;

    FCMVault internal vault;
    IUniswapV3Pool internal collateralLoanPool;
    IUniswapV3Pool internal yieldLoanPool;

    address internal owner = address(makeAddr("owner"));
    address internal alice = address(makeAddr("alice"));
    address internal bob = address(makeAddr("bob"));
    address internal carol = address(makeAddr("carol"));
    address internal stranger = address(makeAddr("stranger"));
    address internal arbitrager = address(makeAddr("arbitrager"));

    function setupFork() public {
        vm.createSelectFork("flow_mainnet");

        _supplyMorphoLiquidity(100_000_000_000e6);

        collateralLoanPool = _getPool(SWAP_FACTORY, address(WBTC), address(PYUSD0), COLLATERAL_LOAN_POOL_FEE);
        yieldLoanPool = _getPool(SWAP_FACTORY, address(FUSDEV), address(PYUSD0), YIELD_LOAN_POOL_FEE);
        require(address(collateralLoanPool) != address(0), "WBTC/PYUSD0 pool missing");
        require(address(yieldLoanPool) != address(0), "FUSDEV/PYUSD0 pool missing");

        _fundArbitrager();
        setCollateralPrice(COLLATERAL_PRICE);
        setYieldPrice(YIELD_PRICE);

        vault = new FCMVault(
            IFCMVault.InitParams({
                collateralToken: address(WBTC),
                loanToken: address(PYUSD0),
                yieldToken: address(FUSDEV),
                ltvMin: LTV_MIN,
                ltvMinTarget: LTV_MIN_TARGET,
                ltvMax: LTV_MAX,
                ltvMaxTarget: LTV_MAX_TARGET,
                yieldToLoanMax: YIELD_TO_LOAN_MAX,
                collateralLoanPool: address(collateralLoanPool),
                yieldLoanPool: address(yieldLoanPool),
                collateralOracle: address(COLLATERAL_ORACLE),
                marketIrm: address(MARKET_IRM),
                marketLltv: MARKET_LLTV,
                yieldOracle: address(YIELD_ORACLE),
                morpho: address(MORPHO),
                swapRouter: address(SWAP_ROUTER),
                name: "Flow Credit Market WBTC/FUSDEV",
                symbol: "fcmWBTC-FUSDEV",
                owner: owner
            })
        );
        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
    }

    function grantFundApprove(address who, uint256 amount) internal {
        vm.prank(owner);
        vault.grantEarlyAccess(who);

        deal(address(WBTC), who, amount);

        vm.prank(who);
        WBTC.approve(address(vault), amount);
    }

    function depositUsers(uint256 nUsers, uint256 depositAmount) internal {
        for (uint256 i = 0; i < nUsers; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            grantFundApprove(u, depositAmount);
            vm.prank(u);
            vault.deposit(depositAmount, u);
            arbPoolToSpot();
        }
    }

    function setCollateralPrice(uint256 price) internal {
        vm.mockCall(address(COLLATERAL_ORACLE), abi.encodeWithSelector(IOracle.price.selector), abi.encode(price));
        _arbCollateralToSpot();
    }

    function setYieldPrice(uint256 price) internal {
        vm.mockCall(address(YIELD_ORACLE), abi.encodeWithSelector(IOracle.price.selector), abi.encode(price));
        _arbYieldPoolToSpot();
    }

    function arbPoolToSpot() internal {
        _arbCollateralToSpot();
        _arbYieldPoolToSpot();
    }

    function _arbCollateralToSpot() internal {
        uint256 collateralPrice = COLLATERAL_ORACLE.price();
        (uint160 currentSpot,,,,,,) = collateralLoanPool.slot0();
        // sqrtPriceX96 = sqrt(token1/token0) * Q96. The collateral oracle prices collateral-per-loan
        // (1e36-scaled), so the sqrt limit depends on which token is token0.
        uint160 targetSpot = address(WBTC) < address(PYUSD0)
            ? uint160(Math.mulDiv(Math.sqrt(collateralPrice), Q96, 1e18))
            : uint160(Math.mulDiv(1e18, Q96, Math.sqrt(collateralPrice)));
        if (currentSpot < targetSpot) {
            vm.prank(arbitrager);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(WBTC),
                    fee: COLLATERAL_LOAN_POOL_FEE,
                    recipient: arbitrager,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        } else if (currentSpot > targetSpot) {
            vm.prank(arbitrager);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(WBTC),
                    tokenOut: address(PYUSD0),
                    fee: COLLATERAL_LOAN_POOL_FEE,
                    recipient: arbitrager,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        }
    }

    function _arbYieldPoolToSpot() internal {
        uint256 yieldPrice = YIELD_ORACLE.price();
        (uint160 currentSpot,,,,,,) = yieldLoanPool.slot0();
        // sqrtPriceX96 = sqrt(token1/token0) * Q96. The yield oracle prices loan-per-yield
        // (1e36-scaled), so the sqrt limit depends on which token is token0.
        uint160 targetSpot = address(FUSDEV) < address(PYUSD0)
            ? uint160(Math.mulDiv(Math.sqrt(yieldPrice), Q96, 1e18))
            : uint160(Math.mulDiv(1e18, Q96, Math.sqrt(yieldPrice)));
        if (currentSpot < targetSpot) {
            vm.prank(arbitrager);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(FUSDEV),
                    tokenOut: address(PYUSD0),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arbitrager,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        } else if (currentSpot > targetSpot) {
            vm.prank(arbitrager);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arbitrager,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: targetSpot
                })
                );
        }
    }

    function _market() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WBTC),
            oracle: address(COLLATERAL_ORACLE),
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
    }

    function _fundArbitrager() internal {
        deal(address(WBTC), arbitrager, 100_000_000e8);
        deal(address(PYUSD0), arbitrager, 100_000_000e6);
        deal(address(FUSDEV), arbitrager, 100_000_000e18);
        vm.startPrank(arbitrager);
        WBTC.approve(address(SWAP_ROUTER), type(uint256).max);
        PYUSD0.approve(address(SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();
    }

    function _supplyMorphoLiquidity(uint256 amount) internal {
        address supplier = makeAddr("supplier");
        deal(address(PYUSD0), supplier, amount);
        vm.startPrank(supplier);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(_market(), amount, 0, supplier, "");
        vm.stopPrank();
    }

    function _getPool(address factory, address tokenA, address tokenB, uint24 fee)
        internal
        view
        returns (IUniswapV3Pool)
    {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSelector(0x1698ee82, tokenA, tokenB, fee));
        require(ok, "factory call failed");
        return IUniswapV3Pool(abi.decode(data, (address)));
    }
}
