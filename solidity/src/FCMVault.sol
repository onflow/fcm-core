// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";

import {MarketLib} from "./libraries/MarketLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";

// ---- Flow EVM mainnet addresses ----------------------------------------

IERC20  constant WETH   = IERC20(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
IERC20  constant PYUSD0 = IERC20(0x99aF3EeA856556646C98c8B9b2548Fe815240750);
IERC20  constant FUSDEV = IERC20(0xd069d989e2F44B70c65347d1853C0c67e10a9F8D);
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);
address constant MARKET_IRM = 0xdFC4f7951EcDd2D505b6406e9c886c0dB9393546;

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue. Three-leg leveraged position:
///         1. Asset leg: WETH supplied as Morpho collateral.
///         2. Debt leg: PYUSD0 borrowed from that market.
///         3. Yield leg: FUSDEV bought with the borrowed PYUSD0.
contract FCMVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    uint256 public constant MARKET_LLTV = 0.86e18;
    uint24 public constant FEE_YIELD_DEBT = 100; // PYUSD0/FUSDEV pool
    uint256 public constant HF_UPPER_TARGET = 1.45e18; // 1e18-scaled target HF for deposit sizing
    uint24 public constant FEE_YIELD_DEBT = 100; // PYUSD0/FUSDEV pool
    uint256 public constant HF_UPPER_TARGET = 1.45e18; // 1e18-scaled target HF for deposit sizing
    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    MarketParams public market;
    address public immutable yieldOracle;

    constructor(
        address marketOracle,
        address yieldOracle_
    ) ERC20("Flow Credit Markets WETH", "fcmWETH") ERC4626(WETH) {
        market = MarketParams({
            loanToken: address(PYUSD0),
            collateralToken: address(WETH),
            oracle: marketOracle,
            irm: MARKET_IRM,
            lltv: MARKET_LLTV
        });
        yieldOracle = yieldOracle_;

        uint256 maxAllowance = type(uint256).max;
        WETH.forceApprove(address(MORPHO), maxAllowance);
        PYUSD0.forceApprove(address(MORPHO), maxAllowance);
        PYUSD0.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
        FUSDEV.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
    }

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 assetAmount = market.collateral();
        uint256 yieldInAsset = _yieldToAsset(FUSDEV.balanceOf(address(this)));
        uint256 debtInAsset = market.debtToCollateral(market.debt());
        uint256 gross = assetAmount + yieldInAsset;
        if (gross > debtInAsset) {
            return gross - debtInAsset;
        }
        return 0;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        market.accrueInterest();

        uint256 navBefore = totalAssets();

        WETH.safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(
                address(PYUSD0),
                address(FUSDEV),
                FEE_YIELD_DEBT,
                toBorrow
            );
        }

        uint256 contributed = totalAssets() - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev How much PYUSD0 to borrow against `newAssets` while keeping the
    ///      position at `HF_UPPER_TARGET`.
    function _targetBorrowAgainst(
        uint256 newAssets
    ) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset = market.maxBorrowFor(newAssets).mulDiv(
            1e18,
            HF_UPPER_TARGET
        );
        uint256 capFromTargetDebt = market.maxBorrowAtHf(HF_UPPER_TARGET);
        return
            capFromNewAsset < capFromTargetDebt
                ? capFromNewAsset
                : capFromTargetDebt;
    }

    /// @dev Routes yield → debt → asset. The two 1e36 oracle scales cancel.
    function _yieldToAsset(
        uint256 yieldAmount
    ) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return
            yieldAmount.mulDiv(
                IOracle(yieldOracle).price(),
                market.oraclePrice()
            );
    }
}
