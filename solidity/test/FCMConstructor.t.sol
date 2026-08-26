// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../src/FCMVault.sol";
import {IFCMVault} from "../src/interfaces/IFCMVault.sol";
import "../src/libraries/ConstantsLib.sol";
import {FCMHelpers} from "../src/libraries/periphery/FCMHelpers.sol";
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

    function test_constructor_revertsWhenLtvMinZero() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.ltvMin = uint128(LTV_SCALE - 1);
        vm.expectRevert(Errors.invalidLtv());
        new FCMVault(p);
    }

    function test_constructor_revertsWhenLtvMaxAboveMarketLltv() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        p.ltvMax = uint128(p.marketLltv);
        vm.expectRevert(Errors.invalidLtv());
        new FCMVault(p);
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

        assertEq(v.LTV_MIN(), p.ltvMin);
        assertEq(v.LTV_MAX(), p.ltvMax);

        assertEq(address(v.COLLATERAL_LOAN_POOL()), p.collateralLoanPool);
        assertEq(address(v.YIELD_LOAN_POOL()), p.yieldLoanPool);

        assertEq(address(v.COLLATERAL_ORACLE()), address(p.collateralOracle));
        assertEq(v.MARKET_IRM(), p.marketIrm);
        assertEq(v.MARKET_LLTV(), p.marketLltv);
        assertEq(address(v.YIELD_ORACLE()), address(p.yieldOracle));
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

        assertFalse(v.emergencyRecoveryActive());
        assertFalse(v.emergencyRecovered());
        assertEq(v.emergencyRecoveryValidAt(), 0);
    }

    function test_constructor_approvesMorphoMaxAllowance() public {
        IFCMVault.InitParams memory p = defaultInitParams();
        FCMVault v = new FCMVault(p);

        assertEq(COLLATERAL_TOKEN.allowance(address(v), address(MORPHO)), type(uint256).max);
        assertEq(LOAN_TOKEN.allowance(address(v), address(MORPHO)), type(uint256).max);
    }
}
