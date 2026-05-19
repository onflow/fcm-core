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

    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IAllowlist
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }

    function allow(address account) external onlyOwner {
        _allow(account);
    }

    function disallow(address account) external onlyOwner {
        _disallow(account);
    }

    function _allow(address account) internal {
        if (account == address(0)) revert ZeroAddress();
        if (!_allowed[account]) {
            _allowed[account] = true;
            emit AddressAllowed(account);
        }
    }

    function _disallow(address account) internal {
        if (_allowed[account]) {
            _allowed[account] = false;
            emit AddressDisallowed(account);
        }
    }
}
