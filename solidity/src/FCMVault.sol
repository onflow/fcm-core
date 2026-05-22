// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title FCMVault
/// @notice ERC-4626 vault for Flow Credit Markets, with role-gated participation.
///         Holders of `ALLOWED_ROLE` may deposit, hold, and transfer shares.
///         Burns (withdrawals/redeems) are always permitted so a removed holder
///         can still exit.
contract FCMVault is ERC4626, AccessControl {
    /// @notice Members of this role may deposit assets, hold shares, and
    ///         transfer shares.
    bytes32 public constant ALLOWED_ROLE = keccak256("ALLOWED_ROLE");

    constructor(string memory name, string memory symbol, IERC20 asset_, address admin)
        ERC20(name, symbol)
        ERC4626(asset_)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!hasRole(ALLOWED_ROLE, receiver)) return 0;
        return super.maxDeposit(receiver);
    }

    /// @inheritdoc IERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        if (!hasRole(ALLOWED_ROLE, receiver)) return 0;
        return super.maxMint(receiver);
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn).
    ///      - Mint (`from == 0`): the receiver must be allowlisted.
    ///      - Transfer (both non-zero): both sender and receiver must be allowlisted.
    ///      - Burn (`to == 0`): always allowed, preserving the exit path for
    ///        de-allowlisted holders.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (!hasRole(ALLOWED_ROLE, to)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(to, ALLOWED_ROLE);
            }
            if (from != address(0) && !hasRole(ALLOWED_ROLE, from)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(from, ALLOWED_ROLE);
            }
        }
        super._update(from, to, value);
    }
}
