// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCMVault} from "../src/FCMVault.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FCMVaultTest is Test {
    FCMVault public vault;
    MockERC20 public asset;

    function setUp() public {
        asset = new MockERC20();
        vault = new FCMVault("Flow Credit Markets Vault", "fcmV", IERC20(address(asset)));
    }

    function test_AssetIsSet() public view {
        assertEq(vault.asset(), address(asset));
    }
}
