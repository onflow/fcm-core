// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {IMorpho, MarketParams, Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MORPHO} from "../src/FCMVault.sol";

/// @dev Minimal factory interface (FlowSwap V3 is a Uniswap V3 fork).
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title ConfiguredScript
/// @notice Shared base for deployment scripts. Loads the per-network config
///         from `deployments/<network>.json` (default network: mainnet) and
///         guards against running it on the wrong chain.
///
///         All scripts support a free rehearsal: run them WITHOUT
///         `--broadcast` and forge fork-simulates every transaction against
///         the live chain state.
abstract contract ConfiguredScript is Script {
    using MarketParamsLib for MarketParams;

    struct Config {
        uint256 chainId;
        address collateral;
        address loanToken;
        address yieldToken;
        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        uint24 feeYieldDebt;
        uint24 feeAssetDebt;
        uint256 healthFactorMin;
        uint256 healthFactorMax;
        uint256 healthFactorMinTarget;
        uint256 healthFactorMaxTarget;
        address yieldOracle;
        address swapFactory;
        address yieldDebtPool;
        uint256 recoveryDelay;
    }

    function _loadConfig() internal view returns (Config memory c) {
        string memory network = vm.envOr("DEPLOY_NETWORK", string("mainnet"));
        string memory toml = vm.readFile(string.concat("deployments/", network, ".toml"));

        c.chainId = vm.parseTomlUint(toml, ".chainId");
        require(
            c.chainId == block.chainid,
            string.concat("config chainId does not match RPC chain (network=", network, ")")
        );

        c.collateral = vm.parseTomlAddress(toml, ".collateral");
        c.loanToken = vm.parseTomlAddress(toml, ".loanToken");
        c.yieldToken = vm.parseTomlAddress(toml, ".yieldToken");
        c.marketOracle = vm.parseTomlAddress(toml, ".marketOracle");
        c.marketIrm = vm.parseTomlAddress(toml, ".marketIrm");
        c.marketLltv = vm.parseTomlUint(toml, ".marketLltv");
        c.feeYieldDebt = uint24(vm.parseTomlUint(toml, ".feeYieldDebt"));
        c.feeAssetDebt = uint24(vm.parseTomlUint(toml, ".feeAssetDebt"));
        c.healthFactorMin = vm.parseTomlUint(toml, ".healthFactorMin");
        c.healthFactorMax = vm.parseTomlUint(toml, ".healthFactorMax");
        c.healthFactorMinTarget = vm.parseTomlUint(toml, ".healthFactorMinTarget");
        c.healthFactorMaxTarget = vm.parseTomlUint(toml, ".healthFactorMaxTarget");
        c.yieldOracle = vm.parseTomlAddress(toml, ".yieldOracle");
        c.swapFactory = vm.parseTomlAddress(toml, ".swapFactory");
        c.yieldDebtPool = vm.parseTomlAddress(toml, ".yieldDebtPool");
        c.recoveryDelay = vm.parseTomlUint(toml, ".recoveryDelay");
    }

    function _marketParams(Config memory c) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: c.loanToken,
            collateralToken: c.collateral,
            oracle: c.marketOracle,
            irm: c.marketIrm,
            lltv: c.marketLltv
        });
    }

    function _marketId(Config memory c) internal pure returns (Id) {
        return _marketParams(c).id();
    }

    /// @dev The Morpho market referenced by the config must already exist on
    ///      chain (its id is the hash of the exact params, so existence also
    ///      proves the params match).
    function _requireMarketExists(Config memory c) internal view returns (Market memory m) {
        m = MORPHO.market(_marketId(c));
        require(
            m.lastUpdate != 0,
            "Morpho market for config params does not exist; check marketOracle/marketIrm/marketLltv"
        );
    }

    /// @dev Both FlowSwap pools the vault trades on must exist.
    function _requirePoolsExist(Config memory c) internal view {
        address yieldPool =
            IUniswapV3Factory(c.swapFactory).getPool(c.yieldToken, c.loanToken, c.feeYieldDebt);
        require(yieldPool != address(0), "yield/debt pool missing");
        require(yieldPool == c.yieldDebtPool, "config yieldDebtPool does not match factory");
        require(
            IUniswapV3Factory(c.swapFactory).getPool(c.collateral, c.loanToken, c.feeAssetDebt)
                != address(0),
            "asset/debt pool missing"
        );
    }

    /// @dev The account whose key signs broadcast transactions. Must be
    ///      called inside a `vm.startBroadcast()` section.
    function _broadcaster() internal returns (address sender) {
        (, sender,) = vm.readCallers();
    }
}
