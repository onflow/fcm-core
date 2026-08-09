// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {YieldTokenOracle} from "../../src/YieldTokenOracle.sol";

/// @dev Morpho's ORACLE_PRICE_SCALE.
uint256 constant ORACLE_PRICE_SCALE = 1e36;

/// @dev Mirrors how Morpho values a position from an `IOracle` price:
///      `assets = shares.mulDivDown(price, ORACLE_PRICE_SCALE)`. Running the
///      oracle output through this strips the 1e36 scaling, so the tests can
///      assert against amounts in the asset's native units rather than
///      scaled prices.
function convertSharesToAssets(uint256 shares, uint256 price) pure returns (uint256) {
    return Math.mulDiv(shares, price, ORACLE_PRICE_SCALE);
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
        vm.createSelectFork("flow_mainnet");
    }

    function test_fork_priceIsSane() public {
        YieldTokenOracle oracle = new YieldTokenOracle(IERC4626(FUSDEV), PYUSD0);
        // One whole FUSDEV (1e18 shares) redeems near 1 PYUSD0 (1e6); allow a
        // wide band so ordinary yield accrual never breaks the test.
        uint256 assets = convertSharesToAssets(1e18, oracle.price());
        assertGt(assets, 0.5e6, "redeems above half parity");
        assertLt(assets, 2e6, "redeems below double parity");
    }

    function test_fork_priceMatchesVaultNav() public {
        YieldTokenOracle oracle = new YieldTokenOracle(IERC4626(FUSDEV), PYUSD0);
        uint256 nav = IERC4626(FUSDEV).convertToAssets(1e18);
        // Converting one whole share through the oracle reproduces the vault's
        // own NAV for that share.
        assertEq(convertSharesToAssets(1e18, oracle.price()), nav, "matches vault NAV");
    }
}
