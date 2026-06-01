// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FCMVault is ERC4626, Ownable {
    constructor(string memory name, string memory symbol, IERC20 asset_)
        ERC20(name, symbol)
        ERC4626(asset_)
        Ownable(msg.sender)
    {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @notice TVL limit, denominated in the vault's Asset token. Enforced by
    ///         the inherited `ERC4626.deposit`, which reverts
    ///         `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`.
    ///         Default 0 -> no deposits until admin raises it.
    uint256 public maxTvl;
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);

    /// @notice Set the TVL limit. Default at deploy time is 0 (no deposits).
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @notice Remaining headroom under the TVL limit, clamped to 0 when full.
    function maxDeposit(address) public view override returns (uint256) {
        uint256 cachedTotalAssets = totalAssets();
        return maxTvl > cachedTotalAssets ? maxTvl - cachedTotalAssets : 0;
    }

    /// @notice Mint is disabled in favor of deposit.
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }
}
