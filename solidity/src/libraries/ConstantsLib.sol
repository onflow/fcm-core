// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@morpho-blue/libraries/ConstantsLib.sol" as MorphoConstants;

/// @dev Basis points scale.
uint256 constant BPS = 10_000;

/// @dev Oracle price scale.
uint256 constant ORACLE_PRICE_SCALE = MorphoConstants.ORACLE_PRICE_SCALE;

/// @dev LTV scale (1e18).
uint128 constant LTV_SCALE = 1e18;
