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

// Morpho Blue singleton — same address on every EVM chain.
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue. Three-leg leveraged position:
///         1. Asset leg: collateral token supplied to Morpho.
///         2. Debt leg: loan token borrowed from the market.
///         3. Yield leg: yield token bought with the borrowed loan token.
contract FCMVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    uint8 internal constant DECIMALS_OFFSET = 6;

    IERC20 public immutable loanToken;
    IERC20 public immutable yieldToken;
    uint24 public immutable feeYieldDebt;
    uint256 public immutable healthFactorUpperTarget;
    address public immutable yieldOracle;

    MarketParams public market;

    struct InitParams {
        IERC20 collateral;
        IERC20 loanToken;
        IERC20 yieldToken;
        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        uint24 feeYieldDebt;
        uint256 healthFactorUpperTarget;
        address yieldOracle;
        string name;
        string symbol;
    }

    constructor(
        InitParams memory p
    ) ERC20(p.name, p.symbol) ERC4626(p.collateral) {
        loanToken = p.loanToken;
        yieldToken = p.yieldToken;
        feeYieldDebt = p.feeYieldDebt;
        healthFactorUpperTarget = p.healthFactorUpperTarget;
        yieldOracle = p.yieldOracle;

        market = MarketParams({
            loanToken: address(p.loanToken),
            collateralToken: address(p.collateral),
            oracle: p.marketOracle,
            irm: p.marketIrm,
            lltv: p.marketLltv
        });

        uint256 maxAllowance = type(uint256).max;
        p.collateral.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(MORPHO), maxAllowance);
        p.loanToken.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
        p.yieldToken.forceApprove(address(SwapLib.SWAP_ROUTER), maxAllowance);
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
        uint256 yieldInAsset = _yieldToAsset(
            yieldToken.balanceOf(address(this))
        );
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

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(
                address(loanToken),
                address(yieldToken),
                feeYieldDebt,
                toBorrow
            );
        }

        uint256 contributed = totalAssets() - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev How much loan token to borrow against `newAssets` while keeping
    ///      the position at `healthFactorUpperTarget`.
    function _targetBorrowAgainst(
        uint256 newAssets
    ) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset = market.maxBorrowFor(newAssets).mulDiv(
            1e18,
            healthFactorUpperTarget
        );
        uint256 capFromTargetDebt = market.maxBorrowAtHealthFactor(
            healthFactorUpperTarget
        );
        if (capFromNewAsset < capFromTargetDebt) {
            return capFromNewAsset;
        }
        return capFromTargetDebt;
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
