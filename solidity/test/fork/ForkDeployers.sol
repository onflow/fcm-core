// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {FCMVaultFactory} from "../../src/FCMVaultFactory.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/external/IUniswapV3SwapCallback.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";

contract ForkDeployers is Test, IUniswapV3SwapCallback {
    using FCMHelpers for FCMVault;
    using SafeERC20 for IERC20;
    uint256 internal constant Q96 = 1 << 96;
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    IERC20 constant WBTC = IERC20(0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);

    uint128 constant LTV_MIN = 0.6e18;
    uint128 constant LTV_MAX = 0.7e18;

    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    uint24 constant COLLATERAL_LOAN_POOL_FEE = 3000;
    uint24 constant YIELD_LOAN_POOL_FEE = 100;

    IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);
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

        FCMVaultFactory factory = new FCMVaultFactory();
        vault = FCMVault(
            factory.createVault(
                IFCMVault.InitParams({
                    collateralToken: address(WBTC),
                    loanToken: address(PYUSD0),
                    yieldToken: address(FUSDEV),
                    ltvMin: LTV_MIN,
                    ltvMax: LTV_MAX,
                    collateralLoanPool: address(collateralLoanPool),
                    yieldLoanPool: address(yieldLoanPool),
                    collateralOracle: address(COLLATERAL_ORACLE),
                    marketIrm: address(MARKET_IRM),
                    marketLltv: MARKET_LLTV,
                    yieldOracle: address(YIELD_ORACLE),
                    morpho: address(MORPHO),
                    name: "Flow Credit Market WBTC/FUSDEV",
                    symbol: "fcmWBTC-FUSDEV",
                    owner: owner
                }),
                "salt"
            )
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
            // Price needs to rise (oneForZero): buy WBTC with PYUSD0. Chunk sized within the arbitrager's PYUSD
            // funding.
            _directArbSwap(collateralLoanPool, address(PYUSD0), address(WBTC), 1e10, targetSpot, arbitrager);
        } else if (currentSpot > targetSpot) {
            // Price needs to fall (zeroForOne): sell WBTC for PYUSD0.
            _directArbSwap(collateralLoanPool, address(WBTC), address(PYUSD0), 1e10, targetSpot, arbitrager);
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
            _directArbSwap(yieldLoanPool, address(FUSDEV), address(PYUSD0), 1e10, targetSpot, arbitrager);
        } else if (currentSpot > targetSpot) {
            _directArbSwap(yieldLoanPool, address(PYUSD0), address(FUSDEV), 1e10, targetSpot, arbitrager);
        }
    }

    /// @dev Swap `amountIn` of `tokenIn` for `tokenOut` directly on `pool` (no router), stopping at
    /// `sqrtPriceLimitX96`. The `funder` supplies the input tokens and receives the output; this contract mediates the
    /// swap and pays the
    /// pool via `uniswapV3SwapCallback`. `sqrtPriceLimitX96 = 0` means no limit (substituted with the tick-math bounds,
    // which the router used to do internally and `pool.swap` requires).
    function _directArbSwap(
        IUniswapV3Pool pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        address funder
    ) internal {
        bool zeroForOne = tokenIn < tokenOut;
        uint160 limit =
            sqrtPriceLimitX96 == 0 ? (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1) : sqrtPriceLimitX96;

        // Pull the input from the funder into this contract so the callback can pay the pool from here.
        vm.prank(funder);
        IERC20(tokenIn).transfer(address(this), amountIn);

        (int256 amount0, int256 amount1) = pool.swap({
            recipient: funder,
            zeroForOne: zeroForOne,
            amountSpecified: SafeCast.toInt256(amountIn),
            sqrtPriceLimitX96: limit,
            data: abi.encode(tokenIn)
        });
        // Output goes directly to `funder` (recipient above). A dust swap may produce 0 output when the input is too
        // small relative to the price (valid V3 partial fill) - that's fine for arb purposes, the marginal price still
        // moves toward the target.
        amount0; // suppress unused-var warning
        amount1;
    }

    /// @inheritdoc IUniswapV3SwapCallback
    /// @dev Only callable by the two configured pools during a swap this contract initiated. Pays the owed `tokenIn`
    /// from this contract's balance (funded by the funder via `_directArbSwap`).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(msg.sender == address(collateralLoanPool) || msg.sender == address(yieldLoanPool), "bad pool");
        address tokenIn = abi.decode(data, (address));
        uint256 amountToPay = amount0Delta > 0 ? SafeCast.toUint256(amount0Delta) : SafeCast.toUint256(amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
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
