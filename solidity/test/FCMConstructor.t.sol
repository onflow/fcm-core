// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import {FCMHelpers} from "../src/libraries/FCMHelpers.sol";
import {MorphoLib} from "../src/libraries/MorphoLib.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Errors} from "./utils/Errors.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract FCMConstructorTest is Test, Deployers {
    using FCMHelpers for FCMVault;
    using Math for uint256;

    function setUp() public {
        etchMocks();
    }

    function test_constructor_revertsWhenHealthFactorMinBelowWad() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.healthFactorMin = MorphoLib.WAD - 1;
        vm.expectRevert(Errors.belowMinWad(p.healthFactorMin));
        new FCMVault(p);
    }

    function test_constructor_healthFactorMinAtWadIsAllowed() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.healthFactorMin = MorphoLib.WAD;
        p.healthFactorMinTarget = MorphoLib.WAD;
        p.healthFactorMaxTarget = MorphoLib.WAD;
        p.healthFactorMax = MorphoLib.WAD;
        FCMVault v = new FCMVault(p);
        assertEq(v.HEALTH_FACTOR_MIN(), MorphoLib.WAD);
    }

    function test_constructor_revertsWhenHealthFactorMinAboveMinTarget() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.healthFactorMinTarget = p.healthFactorMin - 1;
        vm.expectRevert(Errors.invalidHealthFactorBounds(p.healthFactorMin, p.healthFactorMinTarget));
        new FCMVault(p);
    }

    function test_constructor_revertsWhenHealthFactorMinTargetAboveMaxTarget() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.healthFactorMaxTarget = p.healthFactorMinTarget - 1;
        vm.expectRevert(Errors.invalidHealthFactorBounds(p.healthFactorMinTarget, p.healthFactorMaxTarget));
        new FCMVault(p);
    }

    function test_constructor_revertsWhenHealthFactorMaxTargetAboveMax() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.healthFactorMax = p.healthFactorMaxTarget - 1;
        vm.expectRevert(Errors.invalidHealthFactorBounds(p.healthFactorMaxTarget, p.healthFactorMax));
        new FCMVault(p);
    }

    function test_constructor_healthFactorBoundsCanAllBeEqual() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        uint256 hf = 1.5e18;
        p.healthFactorMin = hf;
        p.healthFactorMinTarget = hf;
        p.healthFactorMaxTarget = hf;
        p.healthFactorMax = hf;
        FCMVault v = new FCMVault(p);

        assertEq(v.HEALTH_FACTOR_MIN(), hf);
        assertEq(v.HEALTH_FACTOR_MIN_TARGET(), hf);
        assertEq(v.HEALTH_FACTOR_MAX_TARGET(), hf);
        assertEq(v.HEALTH_FACTOR_MAX(), hf);
    }

    function test_constructor_revertsWhenYieldFactorMaxBelowWad() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.yieldFactorMax = MorphoLib.WAD - 1;
        vm.expectRevert(Errors.belowMinWad(p.yieldFactorMax));
        new FCMVault(p);
    }

    function test_constructor_yieldFactorMaxAtWadIsAllowed() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.yieldFactorMax = MorphoLib.WAD;
        FCMVault v = new FCMVault(p);
        assertEq(v.YIELD_FACTOR_MAX(), MorphoLib.WAD);
    }

    function test_constructor_revertsWhenYieldLoanPoolIsZeroAddress() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.yieldLoanPool = address(0);
        vm.expectRevert(Errors.zeroAddress());
        new FCMVault(p);
    }

    function test_constructor_revertsWhenCollateralLoanPoolIsZeroAddress() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.collateralLoanPool = address(0);
        vm.expectRevert(Errors.zeroAddress());
        new FCMVault(p);
    }

    function test_constructor_setsImmutablesFromInitParams() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        FCMVault v = new FCMVault(p);

        assertEq(address(v.COLLATERAL_TOKEN()), address(p.collateralToken));
        assertEq(address(v.LOAN_TOKEN()), address(p.loanToken));
        assertEq(address(v.YIELD_TOKEN()), address(p.yieldToken));

        assertEq(v.HEALTH_FACTOR_MIN(), p.healthFactorMin);
        assertEq(v.HEALTH_FACTOR_MIN_TARGET(), p.healthFactorMinTarget);
        assertEq(v.HEALTH_FACTOR_MAX(), p.healthFactorMax);
        assertEq(v.HEALTH_FACTOR_MAX_TARGET(), p.healthFactorMaxTarget);
        assertEq(v.YIELD_FACTOR_MAX(), p.yieldFactorMax);

        assertEq(v.COLLATERAL_LOAN_POOL(), p.collateralLoanPool);
        assertEq(v.COLLATERAL_LOAN_POOL_FEE(), p.collateralLoanPoolFee);
        assertEq(v.YIELD_LOAN_POOL(), p.yieldLoanPool);
        assertEq(v.YIELD_LOAN_POOL_FEE(), p.yieldLoanPoolFee);

        // assertEq(v.MARKET_ORACLE(), p.marketOracle);
        // assertEq(v.MARKET_IRM(), p.marketIrm);
        // assertEq(v.MARKET_LLTV(), p.marketLltv);
        // assertEq(address(v.YIELD_ORACLE()), address(p.yieldOracle));
    }

    function test_constructor_setsErc20MetadataAndOwner() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        FCMVault v = new FCMVault(p);

        assertEq(v.name(), p.name);
        assertEq(v.symbol(), p.symbol);
        assertEq(v.owner(), p.owner);
        assertEq(v.pendingOwner(), address(0));
    }

    function test_constructor_setsInitialAdminAndFeeState() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        FCMVault v = new FCMVault(p);

        assertEq(v.maxTvl(), 0);
        assertEq(v.maxSlippageBps(), 0);
        assertEq(v.managementFeeBps(), 0);
        assertEq(v.performanceFeeBps(), 0);
        assertEq(v.feeRecipient(), address(0));
        assertEq(v.lastFeeAccrual(), block.timestamp);

        assertFalse(v.emergencyRecoveryActive());
        assertFalse(v.emergencyRecovered());
        assertEq(v.emergencyRecoveryValidAt(), 0);
    }

    function test_constructor_approvesMorphoAndSwapRouterMaxAllowance() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        FCMVault v = new FCMVault(p);

        assertEq(COLLATERAL_TOKEN.allowance(address(v), address(MORPHO)), type(uint256).max);
        assertEq(LOAN_TOKEN.allowance(address(v), address(MORPHO)), type(uint256).max);
        assertEq(LOAN_TOKEN.allowance(address(v), address(v.SWAP_ROUTER())), type(uint256).max);
        assertEq(YIELD_TOKEN.allowance(address(v), address(v.SWAP_ROUTER())), type(uint256).max);
        assertEq(COLLATERAL_TOKEN.allowance(address(v), address(v.SWAP_ROUTER())), type(uint256).max);
    }
}
