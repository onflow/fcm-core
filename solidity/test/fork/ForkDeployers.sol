// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {IMorpho, Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract ForkDeployers is Test {
    IERC20 constant WBTC = IERC20(0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
    address constant MARKET_ORACLE = 0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8;
    address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;
    IOracle constant YIELD_ORACLE = IOracle(0x144F613490DD55C9844Ef139CFB9B63433dD349F);
    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);
    ISwapRouter02 constant SWAP_ROUTER = ISwapRouter02(0xeEDC6Ff75e1b10B903D9013c358e446a73d35341);

    address constant YIELD_LOAN_POOL = 0x9196e243b7562B0866309013f2F9EB63F83A690f;

    uint256 constant HEALTH_FACTOR_MIN = 1_228_571_428_571_428_571;
    uint256 constant HEALTH_FACTOR_MIN_TARGET = 1_230_329_041_487_839_771;
    uint256 constant HEALTH_FACTOR_MAX = 1_433_333_333_333_333_333;
    uint256 constant HEALTH_FACTOR_MAX_TARGET = 1_430_948_419_301_164_725;
    uint256 constant MARKET_LLTV = 0.86e18;
    uint256 constant YIELD_FACTOR_MAX = 1.01e18;
    uint24 constant COLLATERAL_LOAN_POOL_FEE = 3000;
    uint24 constant YIELD_LOAN_POOL_FEE = 100;

    uint256 constant ORACLE_PRICE = 100_000e36;
    uint256 constant YIELD_ORACLE_PRICE = 1e24;

    FCMVault internal vault;
    MarketParams internal mp;
    Id internal marketId;
    address internal collateralLoanPool;
    uint160 internal cleanSpot;

    address internal owner = address(this);
    address internal arb = makeAddr("arb");
    address internal alice = makeAddr("alice");

    function _forkSetup() internal {
        vm.createSelectFork("flow_mainnet");

        setCollateralPrice(ORACLE_PRICE);
        setYieldPrice(YIELD_ORACLE_PRICE);

        collateralLoanPool = _getPool(SWAP_FACTORY, address(WBTC), address(PYUSD0), COLLATERAL_LOAN_POOL_FEE);
        require(collateralLoanPool != address(0), "WBTC/PYUSD0 pool missing");

        mp = MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WBTC),
            oracle: MARKET_ORACLE,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
        marketId = MarketParamsLib.id(mp);

        _supplyMorphoLiquidity(100_000_000_000e6);

        (cleanSpot,,,,,,) = IUniswapV3Pool(YIELD_LOAN_POOL).slot0();

        vault = new FCMVault(
            IFCMVault.InitParams({
                collateralToken: WBTC,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
                yieldFactorMax: YIELD_FACTOR_MAX,
                collateralLoanPool: collateralLoanPool,
                collateralLoanPoolFee: COLLATERAL_LOAN_POOL_FEE,
                yieldLoanPool: YIELD_LOAN_POOL,
                yieldLoanPoolFee: YIELD_LOAN_POOL_FEE,
                marketOracle: MARKET_ORACLE,
                marketIrm: MARKET_IRM,
                marketLltv: MARKET_LLTV,
                yieldOracle: YIELD_ORACLE,
                morpho: MORPHO,
                swapRouter: SWAP_ROUTER,
                owner: owner,
                name: "fcmWBTC-fork",
                symbol: "fcmWBTC-F"
            })
        );
        vault.setMaxTvl(type(uint256).max);
        vault.setMaxSlippageBps(100);
    }

    function _supplyMorphoLiquidity(uint256 amount) internal {
        address supplier = makeAddr("supplier");
        deal(address(PYUSD0), supplier, amount);
        vm.startPrank(supplier);
        PYUSD0.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(mp, amount, 0, supplier, "");
        vm.stopPrank();
    }

    function _fundArb() internal {
        vm.prank(owner);
        vault.grantEarlyAccess(arb);
        deal(address(WBTC), arb, 100_000_000e8);
        deal(address(PYUSD0), arb, 100_000_000e6);
        deal(address(FUSDEV), arb, 100_000_000e18);
        vm.startPrank(arb);
        WBTC.approve(address(vault), type(uint256).max);
        PYUSD0.approve(address(SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();
    }

    function _depositUsers(uint256 nUsers, uint256 depositAmount) internal {
        for (uint256 i = 0; i < nUsers; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            vault.grantEarlyAccess(u);
            deal(address(WBTC), u, depositAmount);
            vm.startPrank(u);
            WBTC.approve(address(vault), depositAmount);
            vault.deposit(depositAmount, u);
            vm.stopPrank();
            _arbPoolToSpot();
        }
    }

    function setCollateralPrice(uint256 price) internal {
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(price));
    }

    function setYieldPrice(uint256 price) internal {
        vm.mockCall(address(YIELD_ORACLE), abi.encodeWithSelector(IOracle.price.selector), abi.encode(price));
    }

    function _arbPoolToSpot() internal {
        (uint160 currentSpot,,,,,,) = IUniswapV3Pool(YIELD_LOAN_POOL).slot0();
        if (currentSpot < cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(FUSDEV),
                    tokenOut: address(PYUSD0),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        } else if (currentSpot > cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 1e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        }
    }

    function _tvlUsd() internal view returns (uint256) {
        return Math.mulDiv(vault.totalAssets(), IOracle(MARKET_ORACLE).price(), 1e36);
    }

    function _hf() internal view returns (uint256) {
        Position memory pos = MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return type(uint256).max;
        Market memory mkt = MORPHO.market(marketId);
        uint256 debt = Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets) + 1,
            uint256(mkt.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
        uint256 maxBorrow =
            Math.mulDiv(uint256(pos.collateral), Math.mulDiv(IOracle(MARKET_ORACLE).price(), MARKET_LLTV, 1e36), 1e18);
        return Math.mulDiv(maxBorrow, 1e18, debt);
    }

    function _debt() internal view returns (uint256) {
        Position memory pos = MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MORPHO.market(marketId);
        return Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets) + 1,
            uint256(mkt.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
    }

    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSelector(0x1698ee82, tokenA, tokenB, fee));
        require(ok, "factory call failed");
        return abi.decode(data, (address));
    }
}
