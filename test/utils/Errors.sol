// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IFCMVault} from "../../src/interfaces/IFCMVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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

    function maxSlippageExceeded() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.MaxSlippageExceeded.selector);
    }

    function maxFeeRateExceeded() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.MaxFeeRateExceeded.selector);
    }

    function invalidLtv() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.InvalidLtv.selector);
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

    function leftoverLoanTokens() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.LeftoverLoanTokens.selector);
    }

    function notImplemented() public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.NotImplemented.selector);
    }

    function erc4626ExceededMaxDeposit(uint256 assets, uint256 maxDeposit) public pure returns (bytes memory) {
        return abi.encodeWithSelector(IFCMVault.ERC4626ExceededMaxDeposit.selector, assets, maxDeposit);
    }
}
