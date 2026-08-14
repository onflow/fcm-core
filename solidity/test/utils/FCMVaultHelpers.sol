// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FCMVault} from "../../src/FCMVault.sol";
import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

library VaultHelpers {
    function getMarket(FCMVault vault) internal view returns (MarketParams memory market) {
        market.loanToken = address(vault.LOAN_TOKEN());
        market.collateralToken = address(vault.COLLATERAL_TOKEN());
        market.oracle = address(vault.MARKET_ORACLE());
        market.irm = address(vault.MARKET_IRM());
        market.lltv = vault.MARKET_LLTV();
        return market;
    }
}
