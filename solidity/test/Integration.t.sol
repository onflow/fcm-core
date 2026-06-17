// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FCMVault, MORPHO} from "../src/FCMVault.sol";
import {SwapLib} from "../src/libraries/SwapLib.sol";
import {Id, MarketParams, Position, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockIrm} from "./mocks/MockIrm.sol";

/// @title FCMVault integration test
/// @notice Exercises the full happy-path lifecycle of the vault end to end in
///         a single flow — deposit, rebalance, redeem — rather than each leg
///         in isolation (those live in FCMVault.t.sol). The rebalance step is
///         deliberately set up to perform a real balancing operation (lever
///         up), not a no-op, so the test proves the three legs compose.
///
///         Uses the same etched-mock rig as the unit tests: real Flow EVM
///         token/Morpho/router addresses with mock bytecode etched in.
contract IntegrationTest is Test {
    // Real Flow EVM addresses; mocks are etched where the vault's constants point.
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
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;

    address internal admin = address(0x12345);
    address internal user = address(0xA11CE);

    /// @notice Mirrors the `Rebalanced` event so we can assert it fires.
    event Rebalanced(address indexed caller, uint256 healthFactorBefore, uint256 healthFactorAfter);

    function setUp() public {
        bytes memory erc20Code = address(new MockERC20()).code;
        vm.etch(address(WETH), erc20Code);
        vm.etch(address(PYUSD0), erc20Code);
        vm.etch(address(FUSDEV), erc20Code);
        vm.etch(address(MORPHO), address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
        vm.etch(MOCK_IRM, address(new MockIrm()).code);

        marketOracle = new MockOracle(WETH_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);

        vault = new FCMVault(
            FCMVault.InitParams({
                collateral: WETH,
                loanToken: PYUSD0,
                yieldToken: FUSDEV,
                marketOracle: address(marketOracle),
                marketIrm: MOCK_IRM,
                marketLltv: LLTV,
                feeYieldDebt: FEE,
                feeAssetDebt: FEE_ASSET_DEBT,
                healthFactorMin: HEALTH_FACTOR_MIN,
                healthFactorMax: HEALTH_FACTOR_MAX,
                healthFactorTarget: HEALTH_FACTOR_TARGET,
                yieldOracle: address(yieldOracle),
                admin: admin,
                name: "Flow Credit Markets WETH",
                symbol: "fcmWETH"
            })
        );

        vm.prank(admin);
        vault.setMaxTvl(1e21);

        // Allow-list the depositor so they can mint and hold shares.
        bytes32 role = vault.EARLY_ACCESS_ROLE();
        vm.prank(admin);
        vault.grantRole(role, user);
    }

    /// @notice Happy-path lifecycle: a user deposits, the position is
    ///         rebalanced after the collateral price rises (a genuine lever-up,
    ///         not a no-op), and the user redeems all shares back to the
    ///         underlying asset.
    ///
    ///         Step 1 (deposit): pulls WETH collateral into Morpho, borrows
    ///         PYUSD0 against it at the target health factor, and swaps that
    ///         into FUSDEV yield — landing the position exactly at target.
    ///
    ///         Step 2 (rebalance): a collateral price bump pushes the health
    ///         factor above max, so a non-forced rebalance levers the position
    ///         back up — borrowing more debt and buying more yield. We assert
    ///         the operation actually moved state (more debt, more yield, HF
    ///         pulled back to target) so this can never silently degrade into
    ///         a no-op.
    ///
    ///         Step 3 (redeem): burns all shares and unwinds the proportional
    ///         slice of the position back to WETH. With lossless 1:1 mock swaps
    ///         and matched oracle prices, the round-trip returns approximately
    ///         the original deposit.
    function test_Integration_DepositRebalanceRedeem() public {
        uint256 amount = 1 ether;

        // ---- Step 1: deposit -------------------------------------------
        MockERC20(address(WETH)).mint(user, amount);
        vm.startPrank(user);
        WETH.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        assertGt(shares, 0, "deposit minted shares");
        assertEq(vault.balanceOf(user), shares, "user holds shares");
        assertEq(WETH.balanceOf(address(MORPHO)), amount, "collateral supplied to morpho");
        assertGt(FUSDEV.balanceOf(address(vault)), 0, "yield bought with borrowed debt");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token after deposit");
        assertApproxEqRel(_healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "deposit lands at target HF");

        // ---- Step 2: rebalance (must perform real balancing) -----------
        // Collateral appreciates, lifting HF above the max band so a
        // non-forced rebalance is obligated to lever up.
        marketOracle.setPrice(2300e36);
        assertGt(_healthFactor(), HEALTH_FACTOR_MAX, "price rise pushed HF above max");

        uint256 debtBefore = _debt();
        uint256 yieldBefore = FUSDEV.balanceOf(address(vault));

        // The Rebalanced event must fire (proves the call was not a no-op
        // early-return). Data fields are left unchecked since the exact
        // post-rebalance HF depends on share-math rounding.
        vm.expectEmit(true, false, false, false);
        emit Rebalanced(address(this), 0, 0);
        vault.rebalance(false);

        assertGt(_debt(), debtBefore, "rebalance borrowed more debt");
        assertGt(FUSDEV.balanceOf(address(vault)), yieldBefore, "rebalance bought more yield");
        assertEq(PYUSD0.balanceOf(address(vault)), 0, "no idle loan token after rebalance");
        assertApproxEqRel(
            _healthFactor(), HEALTH_FACTOR_TARGET, 1e15, "rebalance restored target HF"
        );

        // ---- Step 3: redeem --------------------------------------------
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(vault.balanceOf(user), 0, "all shares burned");
        assertEq(vault.totalSupply(), 0, "supply back to zero");
        assertEq(WETH.balanceOf(user), assetsOut, "user received redeemed asset");
        // NAV is price-invariant in this rig (collateral measured in token
        // units; yield and debt legs scale together), so the round trip
        // returns approximately the original deposit despite the price move.
        assertApproxEqRel(assetsOut, amount, 1e15, "round-trip returns ~deposit");
    }

    // ---- helpers -----------------------------------------------------------

    function _debt() internal view returns (uint256) {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        Id marketId = MarketParamsLib.id(MarketParams(lt, ct, oracle, irm, lltv_));
        Position memory pos = MORPHO.position(marketId, address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = MORPHO.market(marketId);
        return (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1))
            / (uint256(mkt.totalBorrowShares) + 1e6);
    }

    function _healthFactor() internal view returns (uint256) {
        (address lt, address ct, address oracle, address irm, uint256 lltv_) = vault.market();
        Id marketId = MarketParamsLib.id(MarketParams(lt, ct, oracle, irm, lltv_));
        Position memory pos = MORPHO.position(marketId, address(vault));
        Market memory mkt = MORPHO.market(marketId);
        if (pos.borrowShares == 0) return type(uint256).max;
        uint256 debt = (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1))
            / (uint256(mkt.totalBorrowShares) + 1e6);
        uint256 maxBorrow = Math.mulDiv(
            uint256(pos.collateral), Math.mulDiv(marketOracle.priceValue(), lltv_, 1e36), 1e18
        );
        return Math.mulDiv(maxBorrow, 1e18, debt);
    }
}
