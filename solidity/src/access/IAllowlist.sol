// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IAllowlist
/// @notice Minimal interface that any allowlist implementation must satisfy.
/// @dev Consumer contracts depend only on `isAllowed`. Admin functions are
///      intentionally not part of this interface because different backings
///      (mapping, merkle root, signature) have different admin shapes.
interface IAllowlist {
    /// @notice Emitted when `account` is added to the allowlist.
    event AddressAllowed(address indexed account);

    /// @notice Emitted when `account` is removed from the allowlist.
    event AddressDisallowed(address indexed account);

    /// @notice Returns true if `account` is currently on the allowlist.
    function isAllowed(address account) external view returns (bool);
}
