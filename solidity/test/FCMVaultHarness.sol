// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {FCMVault} from "../src/FCMVault.sol";

/// @dev Exposes the vault's internal price-limit math so the security-critical
///      oracle -> `sqrtPriceLimitX96` conversion can be asserted directly.
contract FCMVaultHarness is FCMVault {
    constructor(FCMVault.InitParams memory p) FCMVault(p) {}

    // forge-lint: disable-next-item(mixed-case-function)
    function exposed_yieldDebtSwapLimit(address tokenIn) external view returns (uint160, bool) {
        return _yieldDebtSwapLimit(tokenIn);
    }
}
