// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IOracle {
    function price() external view returns (uint256);
}
