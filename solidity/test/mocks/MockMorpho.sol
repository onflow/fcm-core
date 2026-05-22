// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, MarketParams, Position, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "./MockERC20.sol";

/// @dev Minimal Morpho Blue mock used by the test rig. Exposes `position`
///      and `market` as public mappings; the vault reads via these auto-
///      getters instead of going through Morpho's periphery `extSloads`.
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => Market) public market;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function accrueInterest(MarketParams memory mp) external {
        market[mp.id()].lastUpdate = uint128(block.timestamp);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes calldata)
        external
    {
        Id id = mp.id();
        position[id][onBehalf].collateral += uint128(assets);
        IERC20(mp.collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    function borrow(
        MarketParams memory mp,
        uint256 assets,
        uint256 /*shares*/,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = mp.id();
        Market storage m = market[id];

        uint256 newShares = _mulDivUp(
            assets,
            uint256(m.totalBorrowShares) + VIRTUAL_SHARES,
            uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS
        );

        position[id][onBehalf].borrowShares += uint128(newShares);
        m.totalBorrowShares += uint128(newShares);
        m.totalBorrowAssets += uint128(assets);

        MockERC20(mp.loanToken).mint(receiver, assets);

        return (assets, newShares);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
