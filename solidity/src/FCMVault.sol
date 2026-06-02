// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";

import {MarketLib} from "./libraries/MarketLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";

// Morpho Blue singleton — same address on every EVM chain.
IMorpho constant MORPHO = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f);

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue with role-gated participation.
///         Three-leg leveraged position:
///         1. Asset leg: collateral token supplied to Morpho.
///         2. Debt leg: loan token borrowed from the market.
///         3. Yield leg: yield token bought with the borrowed loan token.
///
///         Holders of `EARLY_ACCESS_ROLE` may deposit, hold, and transfer
///         shares. Burns (withdrawals/redeems) are always permitted so a
///         removed holder can still exit.
contract FCMVault is ERC4626, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketLib for MarketParams;

    /// @notice Members of this role may deposit assets, hold shares, and
    ///         transfer shares.
    bytes32 public constant EARLY_ACCESS_ROLE = keccak256("EARLY_ACCESS_ROLE");

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
        address admin;
        string name;
        string symbol;
    }

    constructor(InitParams memory p) ERC20(p.name, p.symbol) ERC4626(p.collateral) {
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

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
    }

    // @dev Defines the decimal offset between vault assets and shares. Larger offsets make inflation attacks more expensive.
    // @dev See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol#L32-L39
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    /// @notice Returns the vault's net asset value (NAV) denominated in the
    ///         underlying asset (collateral token).
    /// @dev    NAV = collateral + yield − debt, with both yield and debt
    ///         converted into asset units using oracle prices:
    ///         - collateral: read directly from the Morpho position.
    ///         - yield: balance of `yieldToken` held by the vault, priced
    ///           through `yieldOracle` and the market oracle (see
    ///           `_yieldToAsset`).
    ///         - debt: outstanding loan-token debt on the Morpho market,
    ///           valued at the market oracle price (see `MarketLib.debt`).
    ///
    ///         Returns 0 if debt exceeds gross value (an underwater
    ///         position). This is a stale read by default — callers that
    ///         need an up-to-the-block NAV must accrue interest on the
    ///         market in the same tx first (see `deposit`).
    function totalAssets() public view override returns (uint256) {
        uint256 assetAmount = market.collateral();
        uint256 yieldInAsset = _yieldToAsset(yieldToken.balanceOf(address(this)));
        uint256 debtInAsset = market.debtToCollateral(market.debt());
        uint256 gross = assetAmount + yieldInAsset;
        if (gross > debtInAsset) {
            return gross - debtInAsset;
        }
        return 0;
    }

    /// @notice Deposit `assets` of the underlying asset into the vault and
    ///         mint vault shares to `receiver`.
    /// @dev    Expansion sequence (see docs/architecture.md §A). Let
    ///         `navBefore` be the vault NAV before this deposit:
    ///         1. Accrue market interest so `navBefore` and the post-deposit
    ///            NAV measurement are both fresh.
    ///         2. Pull `assets` from the caller and supply them as
    ///            collateral to the Morpho market.
    ///         3. Borrow `toBorrow = _targetBorrowAgainst(assets)` loan
    ///            token and swap it into yield token on FlowSwap V3. The
    ///            borrow is capped so this deposit cannot drag the existing
    ///            position's health factor down to the target — small
    ///            deposits never rebalance the whole protocol.
    ///         4. Mint shares pro-rata to the NAV contribution
    ///
    ///         Rounding favors the vault: the share computation rounds
    ///         down, so any residual NAV accrues to existing shareholders
    ///         rather than the new depositor.
    /// @param  assets   Amount of underlying asset to deposit.
    /// @param  receiver Account to credit with newly minted shares.
    /// @return shares   Vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        market.accrueInterest();

        uint256 navBefore = totalAssets();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        market.supplyCollateral(assets);
        uint256 toBorrow = _targetBorrowAgainst(assets);
        if (toBorrow > 0) {
            market.borrow(toBorrow);
            SwapLib.swapExactIn(address(loanToken), address(yieldToken), feeYieldDebt, toBorrow);
        }

        // the depositor's contribution to NAV, denominated in outer vault assets
        uint256 contributed = totalAssets() - navBefore;
        // mint shares in proportion to the depositor's contribution
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1); // +1 rounds in favour of the vaults
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Not implemented. Use `deposit` instead.
    /// @dev    `mint` would need to invert the borrow-and-swap leg to solve
    ///         for the asset input that produces an exact share output —
    ///         non-trivial because the yield leg goes through an AMM whose
    ///         realized price is only known after execution.
    function mint(
        uint256,
        /*shares*/
        address /*receiver*/
    )
        public
        pure
        override
        returns (uint256)
    {
        revert("not implemented");
    }

    /// @dev How much loan token to borrow against `newAssets` while keeping
    ///      the position at `healthFactorUpperTarget`. Returns the smaller
    ///      of two caps:
    ///      - `capFromNewAsset`: the borrow `newAssets` of fresh collateral
    ///        could support on its own at the target HF.
    ///      - `capFromTargetDebt`: the additional borrow that, combined
    ///        with existing debt and existing collateral, would land the
    ///        whole position at the target HF.
    ///
    ///      Taking the min means each deposit borrows at most its own
    ///      proportional share of headroom: small deposits cannot
    ///      rebalance an over-collateralized protocol back to target, and
    ///      no deposit can push an already-too-leveraged position past the
    ///      target HF (`capFromTargetDebt` clamps to 0 in that case).
    function _targetBorrowAgainst(uint256 newAssets) internal view returns (uint256) {
        if (newAssets == 0) return 0;
        uint256 capFromNewAsset = market.maxBorrowFor(newAssets).mulDiv(1e18, healthFactorUpperTarget);
        uint256 capFromTargetDebt = market.maxBorrowAtHealthFactor(healthFactorUpperTarget);
        if (capFromNewAsset < capFromTargetDebt) {
            return capFromNewAsset;
        }
        return capFromTargetDebt;
    }

    /// @dev Routes yield → debt → asset. The two 1e36 oracle scales cancel.
    function _yieldToAsset(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        return yieldAmount.mulDiv(IOracle(yieldOracle).price(), market.oraclePrice());
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        return super.maxDeposit(receiver);
    }

    /// @inheritdoc IERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        if (!hasRole(EARLY_ACCESS_ROLE, receiver)) return 0;
        return super.maxMint(receiver);
    }

    /// @dev Hook fires on every share movement (mint / transfer / burn).
    ///      - Mint (`from == 0`): the receiver must be allowlisted.
    ///      - Transfer (both non-zero): both sender and receiver must be allowlisted.
    ///      - Burn (`to == 0`): always allowed, preserving the exit path for
    ///        de-allowlisted holders.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (!hasRole(EARLY_ACCESS_ROLE, to)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(to, EARLY_ACCESS_ROLE);
            }
            if (from != address(0) && !hasRole(EARLY_ACCESS_ROLE, from)) {
                revert IAccessControl.AccessControlUnauthorizedAccount(from, EARLY_ACCESS_ROLE);
            }
        }
        super._update(from, to, value);
    }
}
