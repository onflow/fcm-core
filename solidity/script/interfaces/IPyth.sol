// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IPyth {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
