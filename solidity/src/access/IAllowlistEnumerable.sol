// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAllowlist} from "./IAllowlist.sol";

/// @title IAllowlistEnumerable
/// @notice Extends IAllowlist with on-chain enumeration of allowed addresses.
/// @dev Optional capability — consumers that only need membership checks
///      (`isAllowed`) should depend on the narrower {IAllowlist} interface.
interface IAllowlistEnumerable is IAllowlist {
    /// @notice Returns the number of currently allowed addresses.
    function length() external view returns (uint256);

    /// @notice Returns the allowed address at `index`.
    /// @dev Reverts on out-of-bounds. Index order is not stable across edits:
    ///      removing an entry moves the last element into the freed slot
    ///      (swap-and-pop), so indices should not be treated as identifiers.
    function addressAt(uint256 index) external view returns (address);

    /// @notice Returns the full set of currently allowed addresses.
    /// @dev Gas-expensive for large sets. Prefer paginated reads via
    ///      `length` + `addressAt` from on-chain callers. Safe off-chain via eth_call.
    function values() external view returns (address[] memory);
}
