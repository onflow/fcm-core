// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "./FCMVault.sol";
import {IFCMVault} from "./interfaces/IFCMVault.sol";
import {IFCMVaultFactory} from "./interfaces/IFCMVaultFactory.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title FCMVaultFactory
/// @author Flow Foundation
/// @notice Deploys FCMVault instances deterministically via CREATE2.
contract FCMVaultFactory is IFCMVaultFactory {
    /// @inheritdoc IFCMVaultFactory
    function createVault(IFCMVault.InitParams calldata initParams, bytes32 salt) external returns (address vault) {
        vault = address(new FCMVault{salt: salt}(initParams));
        emit VaultCreated(msg.sender, salt, vault);
    }

    /// @inheritdoc IFCMVaultFactory
    function computeAddress(IFCMVault.InitParams calldata initParams, bytes32 salt)
        external
        view
        returns (address predicted)
    {
        // forge-lint: disable-next-line(encode-packed-collision,asm-keccak256)
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(FCMVault).creationCode, abi.encode(initParams)));
        predicted = Create2.computeAddress(salt, bytecodeHash, address(this));
    }
}
