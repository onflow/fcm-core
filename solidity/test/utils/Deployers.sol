// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../../src/libraries/periphery/FCMHelpers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIrm} from "../mocks/MockIrm.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {Test, Vm} from "forge-std/Test.sol";

// forge-lint: disable-start(internal-function-used-once,unused-return)

contract Deployers is Test {
    using FCMHelpers for FCMVault;

    MockERC20 immutable COLLATERAL_TOKEN = new MockERC20("COLLATERAL_TOKEN", "COLLATERAL_TOKEN");
    MockERC20 immutable LOAN_TOKEN = new MockERC20("LOAN_TOKEN", "LOAN_TOKEN");
    MockERC20 immutable YIELD_TOKEN = new MockERC20("YIELD_TOKEN", "YIELD_TOKEN");

    uint128 constant LTV_MIN = 0.6e18;
    uint128 constant LTV_MAX = 0.7e18;

    MockPool immutable COLLATERAL_LOAN_POOL = new MockPool();
    MockPool immutable YIELD_LOAN_POOL = new MockPool();

    MockMorpho immutable MORPHO = new MockMorpho();
    MockOracle immutable COLLATERAL_ORACLE = new MockOracle(COLLATERAL_PRICE);
    MockIrm immutable MARKET_IRM = new MockIrm();
    uint256 constant MARKET_LLTV = 0.86e18;
    MockOracle immutable YIELD_ORACLE = new MockOracle(YIELD_PRICE);

    uint256 constant COLLATERAL_PRICE = 2000e36;
    uint256 constant YIELD_PRICE = 1e36;

    FCMVault internal vault;

    address internal owner = address(makeAddr("owner"));
    address internal alice = address(makeAddr("alice"));
    address internal bob = address(makeAddr("bob"));
    address internal carol = address(makeAddr("carol"));
    address internal stranger = address(makeAddr("stranger"));

    function deployVault() public {
        labelMocks();
        setCollateralPrice(COLLATERAL_PRICE);
        setYieldPrice(YIELD_PRICE);
        vault = new FCMVault(defaultInitParams());
    }

    function labelMocks() internal {
        vm.label(address(COLLATERAL_TOKEN), "COLLATERAL_TOKEN");
        vm.label(address(LOAN_TOKEN), "LOAN_TOKEN");
        vm.label(address(YIELD_TOKEN), "YIELD_TOKEN");
        vm.label(address(COLLATERAL_LOAN_POOL), "COLLATERAL_LOAN_POOL");
        vm.label(address(YIELD_LOAN_POOL), "YIELD_LOAN_POOL");
        vm.label(address(COLLATERAL_ORACLE), "COLLATERAL_ORACLE");
        vm.label(address(MARKET_IRM), "MARKET_IRM");
        vm.label(address(YIELD_ORACLE), "YIELD_ORACLE");
        vm.label(address(MORPHO), "MORPHO");
    }

    function defaultInitParams() public view returns (IFCMVault.InitParams memory initParams) {
        return IFCMVault.InitParams({
            collateralToken: address(COLLATERAL_TOKEN),
            loanToken: address(LOAN_TOKEN),
            yieldToken: address(YIELD_TOKEN),
            ltvMin: LTV_MIN,
            ltvMax: LTV_MAX,
            collateralLoanPool: address(COLLATERAL_LOAN_POOL),
            yieldLoanPool: address(YIELD_LOAN_POOL),
            collateralOracle: address(COLLATERAL_ORACLE),
            marketIrm: address(MARKET_IRM),
            marketLltv: MARKET_LLTV,
            yieldOracle: address(YIELD_ORACLE),
            morpho: address(MORPHO),
            name: "Flow Credit Market Mock",
            symbol: "fcmMock",
            owner: owner
        });
    }

    function setCollateralPrice(uint256 price) public {
        setCollateralPoolPrice(price);
        MockOracle(address(COLLATERAL_ORACLE)).setPrice(price);
    }

    function setCollateralPoolPrice(uint256 price) public {
        COLLATERAL_LOAN_POOL.setPrice(COLLATERAL_TOKEN, LOAN_TOKEN, price);
        COLLATERAL_LOAN_POOL.setPrice(LOAN_TOKEN, COLLATERAL_TOKEN, 1e36 * 1e36 / price);
    }

    function setYieldPrice(uint256 price) public {
        setYieldPoolPrice(price);
        MockOracle(address(YIELD_ORACLE)).setPrice(price);
    }

    function setYieldPoolPrice(uint256 price) public {
        YIELD_LOAN_POOL.setPrice(YIELD_TOKEN, LOAN_TOKEN, price);
        YIELD_LOAN_POOL.setPrice(LOAN_TOKEN, YIELD_TOKEN, 1e36 * 1e36 / price);
    }

    function setCollateralLoanPoolPriceImpact(uint256 reserveIn, uint256 reserveOut) public {
        COLLATERAL_LOAN_POOL.enablePriceImpact();
        COLLATERAL_LOAN_POOL.setReserves(COLLATERAL_TOKEN, reserveIn);
        COLLATERAL_LOAN_POOL.setReserves(LOAN_TOKEN, reserveOut);
    }

    function setYieldLoanPoolPriceImpact(uint256 reserveIn, uint256 reserveOut) public {
        YIELD_LOAN_POOL.enablePriceImpact();
        YIELD_LOAN_POOL.setReserves(YIELD_TOKEN, reserveIn);
        YIELD_LOAN_POOL.setReserves(LOAN_TOKEN, reserveOut);
    }

    function grantFundApprove(address who, uint256 amount) internal {
        vm.prank(owner);
        vault.grantEarlyAccess(who);

        COLLATERAL_TOKEN.mint(who, amount);

        vm.prank(who);
        COLLATERAL_TOKEN.approve(address(vault), amount);
    }
}
