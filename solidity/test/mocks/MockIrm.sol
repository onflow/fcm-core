// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

/// @dev Zero-interest IRM. Lets the tests focus on deposit math without
///      having to model accrual.
contract MockIrm {
    function borrowRate(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }
}
