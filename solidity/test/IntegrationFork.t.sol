// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {ISwapRouter02} from "../src/interfaces/external/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Id, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

/// @notice Full-lifetime integration test: a realistic $1M-TVL FCMVault built
///         up from 100 individual $10k deposits, on a Flow mainnet fork
///         against the REAL Morpho Blue market, REAL FlowSwap V3 pools
///         (including the shallow ~$20k-liquidity yield/debt pool), REAL
///         SwapRouter02, and REAL tokens (WBTC/PYUSD0/FUSDEV). Only the
///         market oracle is mocked (to simulate collateral price moves that
///         trigger rebalancing — the real Chainlink-style oracle can't be
///         manipulated).
///
///         Between every vault interaction that moves the shallow yield/debt
///         pool (deposit, rebalance, redeem), an external arbitrageur trades
///         the pool back to its "clean" starting spot price — exactly as a
///         profit-seeking arbitrageur would in production. This models the
///         real dynamic: a $1M position leaning on a $20k pool moves that
///         pool a lot per interaction, and the test verifies the vault's
///         partial-fill/rebalance design still converges (over possibly many
///         `rebalance()` calls) once the market re-equilibrates between them.
///
///         Lifecycle exercised:
///           1. 100 users each deposit $10k (0.1 WBTC) -> ~$1M TVL.
///           2. Collateral price +10% -> `rebalance()` repeatedly (with arb
///              in between) until the health factor is back in band.
///           3. Collateral price -10% (from the original price) ->
///              `rebalance()` repeatedly until back in band.
///           4. All 100 users slowly redeem (one at a time, arbed in
///              between) until the vault is fully wound down.
///
///         Forks Flow mainnet directly (no env var needed).
///         Run with: forge test --match-contract IntegrationForkTest -vv
contract IntegrationForkTest is Test {
    // Real Flow mainnet addresses (from deployments/mainnet.toml).
    IERC20 constant WBTC = IERC20(0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579);
    IERC20 constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
    IERC20 constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
    address constant MARKET_ORACLE = 0x5B3e0BA14443B444D557C0C2F85592d88B88f5c8;
    address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;
    IOracle constant YIELD_ORACLE = IOracle(0x144F613490DD55C9844Ef139CFB9B63433dD349F);
    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    // The yield/loan pool is the shallow (~$20k liquidity) pool the vault
    // leans on for every lever/delever/harvest/redeem swap.
    address constant YIELD_LOAN_POOL = 0x9196e243b7562B0866309013f2F9EB63F83A690f;

    // Real production band (from mainnet.toml).
    uint256 constant HEALTH_FACTOR_MIN = 1_228_571_428_571_428_571;
    uint256 constant HEALTH_FACTOR_MIN_TARGET = 1_230_329_041_487_839_771;
    uint256 constant HEALTH_FACTOR_MAX = 1_433_333_333_333_333_333;
    uint256 constant HEALTH_FACTOR_MAX_TARGET = 1_430_948_419_301_164_725;

    uint256 constant MARKET_LLTV = 0.86e18;
    uint256 constant YIELD_FACTOR_MAX = 1.01e18;
    uint24 constant YIELD_LOAN_POOL_FEE = 100;
    uint24 constant COLLATERAL_LOAN_POOL_FEE = 3000;

    // 100 deposits of 0.1 WBTC (~$10k each at ~$100k/BTC) -> ~$1M TVL.
    uint256 constant N_USERS = 100;
    uint256 constant DEPOSIT_AMOUNT = 0.1e8; // 0.1 WBTC (8 decimals)

    // Cap on rebalance() calls per price shock — a keeper would just keep
    // calling this over many blocks; we bound it here so the test itself
    // terminates, and report how many calls were actually needed.
    uint256 constant MAX_REBALANCE_ITERATIONS = 500;

    FCMVault internal vault;
    MarketParams internal mp;
    Id internal marketId;
    address internal collateralLoanPool;
    uint256 internal realPrice; // real oracle price before mocking
    uint160 internal cleanSpot; // yield/loan pool's starting (fair) spot

    address internal owner = address(this);
    address internal arb = makeAddr("arb");
    address[] internal users;

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        // ── Read the real oracle price (may be stale → fall back) ──────────
        try IOracle(MARKET_ORACLE).price() returns (uint256 p) {
            realPrice = p;
        } catch {
            // WBTC ~$100k: PYUSD0_per_WBTC = 100_000, scaled by 1e36 with
            // decimal adjustment (6 dec PYUSD0, 8 dec WBTC):
            // price = 100_000 * 1e6 / 1e8 * 1e36 = 1e39
            realPrice = 1e39;
        }
        // Mock the market oracle so we can change the price later.
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(realPrice));

        // ── Derive the collateral/loan pool from the factory
        // ────────────────────
        collateralLoanPool = _getPool(SWAP_FACTORY, address(WBTC), address(PYUSD0), COLLATERAL_LOAN_POOL_FEE);
        require(collateralLoanPool != address(0), "WBTC/PYUSD0 pool missing");

        // ── Market params
        // ──────────────────────────────────────────────────
        mp = MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WBTC),
            oracle: MARKET_ORACLE,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
        marketId = MarketParamsLib.id(mp);

        // ── Supply PYUSD0 to the real Morpho market so the vault can borrow ──
        // $1M TVL levers roughly $650k of debt at the deposit-target HF, plus
        // headroom for the lever-up rebalance — supply generously.
        // Market memory mkt = MarketLib.MORPHO.market(marketId);
        address supplier = makeAddr("supplier");
        deal(address(PYUSD0), supplier, 10_000_000e6);
        vm.startPrank(supplier);
        PYUSD0.approve(address(MarketLib.MORPHO), type(uint256).max);
        MarketLib.MORPHO.supply(mp, 10_000_000e6, 0, supplier, "");
        vm.stopPrank();
        console.log("Supplied $10M PYUSD0 to Morpho market");

        // ── Record the pool's starting ("clean") spot price ────────────────
        (cleanSpot,,,,,,) = IUniswapV3Pool(YIELD_LOAN_POOL).slot0();

        // ── Deploy FCMVault with real production config
        // ────────────────────
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
                owner: owner,
                name: "fcmWBTC-integration-fork",
                symbol: "fcmWBTC-IF"
            })
        );
        vault.setMaxTvl(type(uint256).max);
        // maxSlippageBps defaults to 0 (not in InitParams); set the 1% production
        // default here so rebalance swaps don't no-op against an off-oracle pool.
        vault.setMaxSlippageBps(100);

        // ── Create + fund 100 depositors
        // ────────────────────────────────────
        users = new address[](N_USERS);
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users[i] = u;
            vault.grantEarlyAccess(u);
            deal(address(WBTC), u, DEPOSIT_AMOUNT);
        }

        // ── Fund the arb bot with real tokens + approve the real router ─────
        deal(address(PYUSD0), arb, 100_000_000e6);
        deal(address(FUSDEV), arb, 100_000_000e18);
        vm.startPrank(arb);
        PYUSD0.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        FUSDEV.approve(address(SwapLib.SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();

        console.log("=== Integration fork test setup ===");
        console.log("Real WBTC oracle price:", realPrice);
        console.log("Yield oracle price:", IOracle(YIELD_ORACLE).price());
        console.log("Pool spot (clean):", uint256(cleanSpot));
        console.log("Pool liquidity:", uint256(IUniswapV3Pool(YIELD_LOAN_POOL).liquidity()));
        console.log("---");
        _arbPoolToSpot();
    }

    // =====================================================================
    // Test: full livetime lifecycle at realistic ($1M TVL vs $20k pool) scale
    // =====================================================================

    function test_Integration_FullLifecycle_Realistic() public {
        vm.startPrank(address(0x1337));
        deal(address(WBTC), address(0x1337), 1e18);
        WBTC.approve(address(MarketLib.MORPHO), type(uint256).max);
        MarketLib.MORPHO.supplyCollateral(mp, 1e18, address(0x1337), "");
        vm.stopPrank();
        // ── 1. Build up ~$1M TVL from 100 individual $10k deposits ─────────
        _depositAllUsers();
        uint256 tvlAfterDeposits = _tvlUsd();
        console.log("TVL after all deposits ($):", tvlAfterDeposits / 1e6);
        // Within 5% of the $1M target -- the exact figure depends on realized
        // swap execution and pool fees paid along the way.
        assertApproxEqRel(tvlAfterDeposits, 1_000_000e6, 0.05e18, "TVL ~ $1M after deposits");

        // ── 2. Collateral price +10% -> rebalance until back in band ───────
        (uint256 itersUp, uint256 hfUp) = _shockPriceAndRebalanceUntilOk(realPrice * 110 / 100);
        console.log("Lever rebalance: iterations =", itersUp, "| HF final =", hfUp / 1e15);
        assertGe(hfUp, HEALTH_FACTOR_MIN, "HF >= min after +10% shock rebalanced");
        assertLe(hfUp, HEALTH_FACTOR_MAX, "HF <= max after +10% shock rebalanced");

        // ── 3. Collateral price -10% (from original) -> rebalance until ok ─
        (uint256 itersDown, uint256 hfDown) = _shockPriceAndRebalanceUntilOk(realPrice * 90 / 100);
        console.log("Delever rebalance: iterations =", itersDown, "| HF final =", hfDown / 1e15);
        assertGe(hfDown, HEALTH_FACTOR_MIN, "HF >= min after -10% shock rebalanced");
        assertLe(hfDown, HEALTH_FACTOR_MAX, "HF <= max after -10% shock rebalanced");

        // ── 4. Restore price to original, then everyone slowly withdraws ───
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(realPrice));
        uint256 totalReturned = _withdrawAllUsersSlowly();
        console.log("Total WBTC returned to users (sats):", totalReturned);
        console.log("Total WBTC deposited (sats):", DEPOSIT_AMOUNT * N_USERS);

        // Everyone exits, all shares burned, vault left empty.
        assertEq(vault.totalSupply(), 0, "all shares burned");
        // Users get back close to what they put in (bounded loss to AMM
        // slippage/fees across the deposit/shock/redeem cycle).
        assertApproxEqRel(totalReturned, DEPOSIT_AMOUNT * N_USERS, 0.05e18, "users recovered ~their principal");
    }

    // =====================================================================
    // Phase helpers
    // =====================================================================

    /// @dev Each of the 100 users deposits `DEPOSIT_AMOUNT`, with the real
    ///      shallow pool arbed back to its clean spot after every deposit —
    ///      mirroring a market that re-equilibrates between trades.
    function _depositAllUsers() internal {
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = users[i];
            vm.startPrank(u);
            WBTC.approve(address(vault), DEPOSIT_AMOUNT);
            uint256 shares = vault.deposit(DEPOSIT_AMOUNT, u);
            vm.stopPrank();
            assertGt(shares, 0, "deposit minted shares");

            _arbPoolToSpot();
        }
        console.log("All", N_USERS, "deposits done. HF =", _hf() / 1e15);
    }

    /// @dev Mocks the collateral price to `newPrice`, then repeatedly calls
    ///      `rebalance()` (arbing the pool back to spot after each call) until
    ///      the health factor is back inside `[HF_MIN, HF_MAX]` or the
    ///      iteration cap is hit. Returns the iteration count and final HF.
    function _shockPriceAndRebalanceUntilOk(uint256 newPrice) internal returns (uint256 iterations, uint256 hfFinal) {
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(newPrice));
        hfFinal = _hf();
        console.log("HF right after price shock:", hfFinal / 1e15);

        for (uint256 i = 0; i < MAX_REBALANCE_ITERATIONS; i++) {
            if (hfFinal >= HEALTH_FACTOR_MIN && hfFinal <= HEALTH_FACTOR_MAX) break;
            vault.rebalance();
            _arbPoolToSpot();
            hfFinal = _hf();
            iterations = i + 1;
        }
    }

    /// @dev Every user redeems their full share balance, one at a time, with
    ///      the pool arbed back to spot between redemptions. Returns the sum
    ///      of assets returned across all users.
    function _withdrawAllUsersSlowly() internal returns (uint256 totalReturned) {
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = users[i];
            uint256 shares = vault.balanceOf(u);
            if (shares == 0) continue;

            vm.prank(u);
            uint256 assetsOut = vault.redeem(shares, u, u);
            totalReturned += assetsOut;

            _arbPoolToSpot();
        }
        console.log("All", N_USERS, "withdrawals done. HF =", _hf() / 1e15);
    }

    // =====================================================================
    // Arb helper — restore the yield/debt pool to its clean spot
    // =====================================================================

    /// @dev Simulates an external arbitrageur trading the shallow yield/debt
    ///      pool back to `cleanSpot` after a vault interaction has moved it.
    ///      Mirrors the pattern used by `SandwichFork.t.sol`.
    function _arbPoolToSpot() internal {
        (uint160 currentSpot,,,,,,) = IUniswapV3Pool(YIELD_LOAN_POOL).slot0();
        if (currentSpot < cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(FUSDEV),
                    tokenOut: address(PYUSD0),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 100_000_000e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        } else if (currentSpot > cleanSpot) {
            vm.prank(arb);
            ISwapRouter02(address(SwapLib.SWAP_ROUTER))
                .exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(PYUSD0),
                    tokenOut: address(FUSDEV),
                    fee: YIELD_LOAN_POOL_FEE,
                    recipient: arb,
                    amountIn: 100_000_000e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: cleanSpot
                })
                );
        }
    }

    // =====================================================================
    // Vault/market read helpers
    // =====================================================================

    function _tvlUsd() internal view returns (uint256) {
        return Math.mulDiv(vault.totalAssets(), IOracle(MARKET_ORACLE).price(), 1e36);
    }

    function _hf() internal view returns (uint256) {
        Position memory pos = MarketLib.MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return type(uint256).max;
        Market memory mkt = MarketLib.MORPHO.market(marketId);
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
        Position memory pos = MarketLib.MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MarketLib.MORPHO.market(marketId);
        return Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets) + 1,
            uint256(mkt.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
    }

    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(0x1698ee82, tokenA, tokenB, fee) // getPool(address,address,uint24)
        );
        require(ok, "factory call failed");
        return abi.decode(data, (address));
    }
}
