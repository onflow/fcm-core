// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FCMVault
/// @notice ERC-4626 vault for Flow Credit Markets, with role-gated participation.
///         Holders of `EARLY_ACCESS_ROLE` may deposit, hold, and transfer shares.
///         Burns (withdrawals/redeems) are always permitted so a removed holder
///         can still exit.
contract FCMVault is ERC4626, AccessControl, Ownable {
    /// @notice Members of this role may deposit assets, hold shares, and
    ///         transfer shares.
    bytes32 public constant EARLY_ACCESS_ROLE = keccak256("EARLY_ACCESS_ROLE");

    /// @notice TVL limit, denominated in the vault's Asset token.
    ///         Enforced by `super.deposit`, which reverts with
    ///         `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`.
    ///         Default 0 -> no deposits until admin raises it.
    ///         - This constraint prevents all deposits/mints which would cause the vault to exceed
    ///           the configured TVL limit after the deposit/mint completes.
    ///         - This constraint does not prevent any withdrawals/redeems under any circumstances.
    ///         - This constraint does not prevent the vault from holding more assets than its configured TVL.
    ///           This can happen if:
    ///            - The owner sets maxTvl to a value lower than the current totalAssets
    ///            - The value of vault holdings increases above the TVL limit due to market conditions.
    ///              This can occur without any direct interactions with the vault.
    uint256 public maxTvl;

    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);

    constructor(string memory name, string memory symbol, IERC20 asset_, address admin)
        ERC20(name, symbol)
        ERC4626(asset_)
        Ownable(msg.sender)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    /// @param newMaxTvl the new TVL limit; applies only to new deposits.
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @inheritdoc IERC4626
    /// @notice Remaining headroom under the TVL limit, clamped to 0 when full.
    /// @dev Even if the inner vault has hit its own deposit limit, we may still
    ///      be able to obtain shares of it on the AMM to satisfy the deposit.
    ///      However, if we implement 'direct deposit' to the inner vault,
    ///      its own maxDeposit() will bind.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        uint256 cachedTotalAssets = totalAssets();
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @inheritdoc IERC4626
    /// @notice Mint is disabled in favor of deposit.
    function maxMint(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        return 0;
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn).
    ///      - Mint (`from == 0`): the receiver must be allowlisted.
    ///      - Transfer (both non-zero): both sender and receiver must be allowlisted.
    ///      - Burn (`to == 0`): always allowed, preserving the exit path for
    ///        de-allowlisted holders.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (!hasRole(EARLY_ACCESS_ROLE, to)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(to, EARLY_ACCESS_ROLE);
            }
            if (from != address(0) && !hasRole(EARLY_ACCESS_ROLE, from)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(from, EARLY_ACCESS_ROLE);
            }
        }
        super._update(from, to, value);
    }
}
