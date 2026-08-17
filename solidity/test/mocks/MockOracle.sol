// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

contract MockOracle {
    uint256 public priceValue;

    constructor(uint256 priceValue_) {
        priceValue = priceValue_;
    }

    function price() external view returns (uint256) {
        return priceValue;
    }

    function setPrice(uint256 newPrice) external {
        priceValue = newPrice;
    }
}
