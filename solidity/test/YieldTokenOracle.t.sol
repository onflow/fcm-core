// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {YieldTokenOracle} from "../src/YieldTokenOracle.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract YieldTokenOracleTest is Test {
    address internal constant ASSET = address(0xBBB2);

    MockERC4626 internal vault;

    function setUp() public {
        vault = new MockERC4626(ASSET, 18);
    }

    function _oracle() internal returns (YieldTokenOracle) {
        return new YieldTokenOracle(IERC4626(address(vault)), ASSET);
    }

    function test_priceAtParity() public {
        // 18-decimal shares, 6-decimal asset, rate 1:1 => Morpho price 1e24
        // (the 10^(6-18) decimal adjustment is embedded in the conversion).
        vault.setRate(1e6);
        assertEq(_oracle().price(), 1e24, "1:1 rate, 18->6 decimals");
    }

    function test_priceTracksExchangeRate() public {
        vault.setRate(1.05e6);
        assertEq(_oracle().price(), 1.05e24, "rate above parity");

        vault.setRate(0.97e6);
        assertEq(_oracle().price(), 0.97e24, "rate below parity");
    }

    function test_priceWithEqualDecimals() public {
        vault = new MockERC4626(ASSET, 6);
        vault.setRate(2e6);
        // 6-decimal shares and asset: parity would be 1e36, double is 2e36.
        assertEq(_oracle().price(), 2e36, "equal decimals, 2x rate");
    }

    function test_constructorRejectsAssetMismatch() public {
        vm.expectRevert(YieldTokenOracle.AssetMismatch.selector);
        new YieldTokenOracle(IERC4626(address(vault)), address(0xDEAD));
    }
}

/// @dev Fork tests against the real FUSDEV vault. Skipped unless
///      FLOW_MAINNET_RPC_URL is set, so the offline test suite stays
///      self-contained:
///      FLOW_MAINNET_RPC_URL=https://mainnet.evm.nodes.onflow.org forge test
contract YieldTokenOracleForkTest is Test {
    address internal constant FUSDEV = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;
    address internal constant PYUSD0 = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;

    bool internal forking;

    function setUp() public {
        string memory rpc = vm.envOr("FLOW_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forking = true;
    }

    modifier onlyFork() {
        vm.skip(!forking);
        _;
    }

    function test_fork_priceIsSane() public onlyFork {
        YieldTokenOracle oracle = new YieldTokenOracle(IERC4626(FUSDEV), PYUSD0);
        uint256 p = oracle.price();
        // FUSDEV (18 dec) priced in PYUSD0 (6 dec) near $1 => ~1e24, allow a
        // wide band so ordinary yield accrual never breaks the test.
        assertGt(p, 0.5e24, "price above half parity");
        assertLt(p, 2e24, "price below double parity");
    }

    function test_fork_priceMatchesVaultNav() public onlyFork {
        YieldTokenOracle oracle = new YieldTokenOracle(IERC4626(FUSDEV), PYUSD0);
        uint256 nav = IERC4626(FUSDEV).convertToAssets(1e18);
        assertEq(oracle.price(), nav * 1e18, "price is the 1e36-scaled NAV");
    }
}
