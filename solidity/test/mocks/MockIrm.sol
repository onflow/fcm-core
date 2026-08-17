// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

/// @dev Zero-interest IRM.
contract MockIrm {
    function borrowRate(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }
}
