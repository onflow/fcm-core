// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @dev Minimal ERC4626 stub: fixed asset/decimals, configurable exchange
///      rate expressed as assets per one whole share.
contract MockERC4626 {
    address public asset;
    uint8 public decimals;
    uint256 internal assetsPerWholeShare;

    constructor(address asset_, uint8 decimals_) {
        asset = asset_;
        decimals = decimals_;
    }

    function setRate(uint256 assetsPerWholeShare_) external {
        assetsPerWholeShare = assetsPerWholeShare_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerWholeShare / 10 ** decimals;
    }
}
