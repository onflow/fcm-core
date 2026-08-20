// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FCMVault} from "../../src/FCMVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMorpho, Market, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

library VaultHelpers {
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    using MarketParamsLib for MarketParams;
    using Math for uint256;

    function market(FCMVault vault) internal view returns (MarketParams memory _market) {
        _market.loanToken = address(vault.LOAN_TOKEN());
        _market.collateralToken = address(vault.COLLATERAL_TOKEN());
        _market.oracle = address(vault.MARKET_ORACLE());
        _market.irm = address(vault.MARKET_IRM());
        _market.lltv = vault.MARKET_LLTV();
        return _market;
    }

    /// @dev The vault's outstanding debt in its Morpho market. Mirrors `MorphoLib.debt`
    /// but queries the vault's position (`address(vault)`), not `address(this)`, so it
    /// is safe to call from a test contract. (`MorphoLib.debt` inlines `address(this)`,
    /// which from a test resolves to the test contract - the test has no Morpho position.)
    function debt(FCMVault vault) internal view returns (uint256) {
        MarketParams memory mp = market(vault);
        Position memory pos = IMorpho(address(vault.MORPHO())).position(mp.id(), address(vault));
        if (pos.borrowShares == 0) return 0;
        Market memory mkt = IMorpho(address(vault.MORPHO())).market(mp.id());
        return uint256(pos.borrowShares)
            .mulDiv(uint256(mkt.totalBorrowAssets) + 1, uint256(mkt.totalBorrowShares) + 1e6, Math.Rounding.Ceil);
    }

    /// @dev The vault's collateral supplied to its Morpho market, in raw collateral-token units.
    /// Mirrors `MorphoLib.collateral` but queries the vault's position (`address(vault)`),
    /// not `address(this)`, so it is safe to call from a test contract.
    function collateral(FCMVault vault) internal view returns (uint256) {
        return uint256(IMorpho(address(vault.MORPHO())).position(market(vault).id(), address(vault)).collateral);
    }

    /// @dev The vault's Morpho position (collateral + borrow shares).
    function position(FCMVault vault) internal view returns (Position memory) {
        return IMorpho(address(vault.MORPHO())).position(market(vault).id(), address(vault));
    }

    function grantFundApprove(FCMVault vault, address who, uint256 amount) internal {
        VM.prank(vault.owner());
        vault.grantEarlyAccess(who);

        MockERC20 token = MockERC20(address(vault.COLLATERAL_TOKEN()));
        token.mint(who, amount);

        VM.prank(who);
        token.approve(address(vault), amount);
    }
}
