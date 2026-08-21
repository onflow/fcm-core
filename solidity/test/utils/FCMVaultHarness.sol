// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {MarketLib} from "../../src/libraries/MarketLib.sol";

/// @dev Exposes the vault's internal price-limit math so the security-critical
///      oracle -> `sqrtPriceLimitX96` conversion can be asserted directly.
contract FCMVaultHarness is FCMVault {
    constructor(FCMVault.InitParams memory p) FCMVault(p) {}

    // forge-lint: disable-next-item(mixed-case-function)
    function exposed_debt() external view returns (uint256) {
        return MarketLib.debt(_market());
    }
}
