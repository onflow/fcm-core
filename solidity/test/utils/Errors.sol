// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

library Errors {
    function unauthorized() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.Unauthorized.selector);
    }

    function noAllowance(address spender, uint256 currentAllowance, uint256 requiredAllowance)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, spender, currentAllowance, requiredAllowance
        );
    }

    function emergencyRecoveryActive() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.EmergencyRecoveryActive.selector);
    }

    function insufficientAllowance(address spender, uint256 currentAllowance, uint256 requiredAllowance)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, spender, currentAllowance, requiredAllowance
        );
    }

    function ownableUnauthorizedAccount(address caller) public pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
    }

    function noEarlyAccess(address account) public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.NoEarlyAccess.selector, account);
    }

    function invalidSlippage() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.InvalidSlippage.selector);
    }

    function invalidFee() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.InvalidFee.selector);
    }

    function invalidLtv() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.InvalidLtv.selector);
    }

    function invalidYieldFactor() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.InvalidYieldFactor.selector);
    }

    function zeroAddress() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.ZeroAddress.selector);
    }

    function vaultUnderwater() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.VaultUnderwater.selector);
    }

    function vaultUnhealthy() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.VaultUnhealthy.selector);
    }

    function emergencyRecoveryNotReady() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.EmergencyRecoveryNotReady.selector);
    }

    function leftoverDebt() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.LeftoverDebt.selector);
    }

    function notImplemented() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.NotImplemented.selector);
    }

    function erc4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 maxDeposit)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, receiver, assets, maxDeposit);
    }
}
