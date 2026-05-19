// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowlist} from "./IAllowlist.sol";

/// @title Allowlist
/// @notice Mapping-backed allowlist of addresses, administered by a single owner.
/// @dev Idempotent edits: re-adding an existing entry (or removing an absent
///      one) does not revert and does not emit. Matches OpenZeppelin
///      `_grantRole` semantics.
contract Allowlist is IAllowlist, Ownable {
    mapping(address account => bool) private _allowed;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IAllowlist
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }
}
