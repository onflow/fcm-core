// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FCMVault} from "../../src/FCMVault.sol";
import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

library VaultHelpers {
    function getMarket(FCMVault vault) internal view returns (MarketParams memory market) {
        (market.loanToken, market.collateralToken, market.oracle, market.irm, market.lltv) = vault.market();
        return market;
    }
}
