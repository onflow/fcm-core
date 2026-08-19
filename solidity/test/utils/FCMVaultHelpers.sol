// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FCMVault} from "../../src/FCMVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {Vm} from "forge-std/Vm.sol";

library VaultHelpers {
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function market(FCMVault vault) internal view returns (MarketParams memory _market) {
        _market.loanToken = address(vault.LOAN_TOKEN());
        _market.collateralToken = address(vault.COLLATERAL_TOKEN());
        _market.oracle = address(vault.MARKET_ORACLE());
        _market.irm = address(vault.MARKET_IRM());
        _market.lltv = vault.MARKET_LLTV();
        return _market;
    }

    function depositFor(FCMVault vault, address who, uint256 amount) internal returns (uint256 shares) {
        VM.startPrank(vault.owner());
        vault.setMaxTvl(1e21);
        vault.grantEarlyAccess(who);
        VM.stopPrank();

        MockERC20 token = MockERC20(address(vault.COLLATERAL_TOKEN()));
        token.mint(who, amount);
        VM.startPrank(who);
        token.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        VM.stopPrank();
    }
}
