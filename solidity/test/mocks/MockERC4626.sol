// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockERC4626 {
    address public asset;
    uint8 public decimals;
    uint256 internal numerator;
    uint256 internal denominator;

    constructor(address asset_, uint8 decimals_) {
        asset = asset_;
        decimals = decimals_;
    }

    function setRate(uint256 assetsPerWholeShare) external {
        numerator = assetsPerWholeShare;
        denominator = 10 ** decimals;
    }

    function setFractionalRate(uint256 numerator_, uint256 denominator_) external {
        numerator = numerator_;
        denominator = denominator_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, numerator, denominator);
    }
}
