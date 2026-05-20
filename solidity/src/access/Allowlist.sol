// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAllowlistEnumerable} from "./IAllowlistEnumerable.sol";

/// @title Allowlist
/// @notice Enumerable allowlist of addresses, administered by a single owner.
/// @dev Idempotent edits: re-adding an existing entry (or removing an absent
///      one) does not revert and does not emit. Matches OpenZeppelin
///      `_grantRole` semantics.
contract Allowlist is IAllowlistEnumerable, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _allowed;

    /// @dev The zero address cannot be allow-listed. (Disallowing the zero address is a no-op.)
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function isAllowed(address account) external view returns (bool) {
        return _allowed.contains(account);
    }

    /// @inheritdoc IAllowlistEnumerable
    function length() external view returns (uint256) {
        return _allowed.length();
    }

    /// @inheritdoc IAllowlistEnumerable
    function addressAt(uint256 index) external view returns (address) {
        return _allowed.at(index);
    }

    /// @inheritdoc IAllowlistEnumerable
    function values() external view returns (address[] memory) {
        return _allowed.values();
    }

    function allow(address account) external onlyOwner {
        _allow(account);
    }

    function disallow(address account) external onlyOwner {
        _disallow(account);
    }

    function allowBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            _allow(accounts[i]);
        }
    }

    function disallowBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            _disallow(accounts[i]);
        }
    }

    function _allow(address account) internal {
        if (account == address(0)) revert ZeroAddress();
        if (_allowed.add(account)) {
            emit AddressAllowed(account);
        }
    }

    function _disallow(address account) internal {
        if (_allowed.remove(account)) {
            emit AddressDisallowed(account);
        }
    }
}
