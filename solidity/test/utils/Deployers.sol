pragma solidity ^0.8.20;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {MarketLib} from "../../src/libraries/MarketLib.sol";
import {SwapLib} from "../../src/libraries/SwapLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIrm} from "../mocks/MockIrm.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract Deployers is Test {
    MockERC20 immutable COLLATERAL_TOKEN = MockERC20(makeAddr("COLLATERAL_TOKEN"));
    MockERC20 immutable LOAN_TOKEN = MockERC20(makeAddr("LOAN_TOKEN"));
    MockERC20 immutable YIELD_TOKEN = MockERC20(makeAddr("YIELD_TOKEN"));
    MockIrm immutable MOCK_IRM = MockIrm(makeAddr("MOCK_IRM"));

    uint256 internal constant COLLATERAL_PRICE = 2000e36;
    uint256 internal constant YIELD_PRICE = 1e36;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant HEALTH_FACTOR_MIN = 1.25e18;
    uint256 internal constant HEALTH_FACTOR_MAX = 1.65e18;
    // Re-entry targets just inside each bound: a delever lands at minTarget
    // (just above min), a lever lands at maxTarget (just below max).
    // Ordering: min <= minTarget <= maxTarget <= max.
    uint256 internal constant HEALTH_FACTOR_MIN_TARGET = 1.3e18;
    uint256 internal constant HEALTH_FACTOR_MAX_TARGET = 1.6e18;
    // Deposits lever fresh collateral to the midpoint of the band; rebalance
    // acts only at the bounds.
    uint256 internal constant DEPOSIT_TARGET_HF = (HEALTH_FACTOR_MIN + HEALTH_FACTOR_MAX) / 2;
    // Upper edge of the yield-factor band (rho = yieldValue/debt): harvest fires only
    // when rho > YIELD_FACTOR_MAX. Placeholder (1% band) pending the yield-factor sim.
    uint256 internal constant YIELD_FACTOR_MAX = 1.01e18;
    uint24 internal constant YIELD_LOAN_POOL_FEE = 100;
    uint24 internal constant COLLATERAL_LOAN_POOL_FEE = 3000;
    IMorpho internal constant MORPHO = MarketLib.MORPHO;

    FCMVault internal vault;
    MockOracle internal marketOracle;
    MockOracle internal yieldOracle;
    MockUniswapV3Pool internal collateralPool;
    MockUniswapV3Pool internal yieldPool;

    address internal owner = address(makeAddr("owner"));
    address internal alice = address(makeAddr("alice"));
    address internal bob = address(makeAddr("bob"));
    address internal carol = address(makeAddr("carol"));
    address internal stranger = address(makeAddr("stranger"));

    function deployVault() public {
        marketOracle = new MockOracle(COLLATERAL_PRICE);
        yieldOracle = new MockOracle(YIELD_PRICE);
        collateralPool = new MockUniswapV3Pool();
        yieldPool = new MockUniswapV3Pool();
        etchMocks();
        vault = new FCMVault(defaultInitParams());
        vm.prank(owner);
        vault.setMaxSlippageBps(100);
    }

    function etchMocks() internal {
        vm.etch(address(COLLATERAL_TOKEN), address(new MockERC20("COLLATERAL_TOKEN", "COLLATERAL_TOKEN")).code);
        vm.etch(address(LOAN_TOKEN), address(new MockERC20("LOAN_TOKEN", "LOAN_TOKEN")).code);
        vm.etch(address(YIELD_TOKEN), address(new MockERC20("YIELD_TOKEN", "YIELD_TOKEN")).code);
        vm.etch(address(MOCK_IRM), address(new MockIrm()).code);
        vm.etch(address(MORPHO), address(new MockMorpho()).code);
        vm.etch(address(SwapLib.SWAP_ROUTER), address(new MockSwapRouter()).code);
    }

    function defaultInitParams() public view returns (IFCMVault.InitParams memory initParams) {
        return IFCMVault.InitParams({
            collateralToken: COLLATERAL_TOKEN,
            loanToken: LOAN_TOKEN,
            yieldToken: YIELD_TOKEN,
            healthFactorMin: HEALTH_FACTOR_MIN,
            healthFactorMinTarget: HEALTH_FACTOR_MIN_TARGET,
            healthFactorMax: HEALTH_FACTOR_MAX,
            healthFactorMaxTarget: HEALTH_FACTOR_MAX_TARGET,
            yieldFactorMax: YIELD_FACTOR_MAX,
            collateralLoanPool: address(collateralPool),
            collateralLoanPoolFee: COLLATERAL_LOAN_POOL_FEE,
            yieldLoanPool: address(yieldPool),
            yieldLoanPoolFee: YIELD_LOAN_POOL_FEE,
            marketOracle: address(marketOracle),
            marketIrm: address(MOCK_IRM),
            marketLltv: LLTV,
            yieldOracle: IOracle(address(yieldOracle)),
            owner: owner,
            name: "Flow Credit Markets WETH",
            symbol: "fcmWETH"
        });
    }

    function setCollateralPrice(uint256 price) public {
        collateralPool.setSqrtPriceX96(uint160(_sqrtPriceX96(price, 1e18)));
    }

    function setYieldPrice(uint256 price) public {
        yieldPool.setSqrtPriceX96(uint160(_sqrtPriceX96(price, 1e18)));
    }

    function _priceX192(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.mulDiv(num, 1 << 192, den);
    }

    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint256) {
        return Math.sqrt(_priceX192(num, den));
    }
}
