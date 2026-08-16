// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "./IFCMVault.sol";

/// @title IFCMVaultFactory
/// @author Flow Foundation
/// @notice Interface for the FCMVaultFactory - deploys FCMVault instances deterministically via CREATE2.
interface IFCMVaultFactory {
    /// @notice Emitted when a vault is created.
    /// @param deployer The account that requested the deployment (msg.sender).
    /// @param salt The CREATE2 salt used.
    /// @param vault The deployed FCMVault address.
    event VaultCreated(address indexed deployer, bytes32 indexed salt, address indexed vault);

    /// @notice Deploy a new FCMVault with deterministic addressing via CREATE2.
    /// @param initParams Initialization parameters forwarded to FCMVault(initParams).
    /// @param salt CREATE2 salt.
    /// @return vault The deployed FCMVault address.
    function createVault(IFCMVault.InitParams calldata initParams, bytes32 salt) external returns (address vault);

    /// @notice Compute the CREATE2 address for a given salt and init params without deploying.
    /// @param initParams The initialization parameters that will be passed to FCMVault(initParams).
    /// @param salt The CREATE2 salt.
    /// @return predicted The predicted vault address.
    function computeAddress(IFCMVault.InitParams calldata initParams, bytes32 salt)
        external
        view
        returns (address predicted);
}
