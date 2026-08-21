// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {Id, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {Script} from "forge-std/Script.sol";

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

        address collateralToken;
        address loanToken;
        address yieldToken;

        uint256 healthFactorMin;
        uint256 healthFactorMinTarget;
        uint256 healthFactorMax;
        uint256 healthFactorMaxTarget;
        uint256 yieldFactorMax;

        address swapFactory;
        address collateralLoanPool;
        uint24 collateralLoanPoolFee;
        address yieldLoanPool;
        uint24 yieldLoanPoolFee;

        address marketOracle;
        address marketIrm;
        uint256 marketLltv;
        address yieldOracle;
    }

    function _loadConfig() internal view returns (Config memory c) {
        string memory network = vm.envOr("DEPLOY_NETWORK", string("mainnet"));
        // necessary to load config from file
        // forge-lint: disable-next-item(unsafe-cheatcode)
        string memory toml = vm.readFile(string.concat("deployments/", network, ".toml"));

        c.chainId = vm.parseTomlUint(toml, ".chainId");
        require(
            c.chainId == block.chainid, string.concat("config chainId does not match RPC chain (network=", network, ")")
        );

        c.collateralToken = vm.parseTomlAddress(toml, ".collateralToken");
        c.loanToken = vm.parseTomlAddress(toml, ".loanToken");
        c.yieldToken = vm.parseTomlAddress(toml, ".yieldToken");

        c.healthFactorMin = vm.parseTomlUint(toml, ".healthFactorMin");
        c.healthFactorMax = vm.parseTomlUint(toml, ".healthFactorMax");
        c.healthFactorMinTarget = vm.parseTomlUint(toml, ".healthFactorMinTarget");
        c.healthFactorMaxTarget = vm.parseTomlUint(toml, ".healthFactorMaxTarget");
        c.yieldFactorMax = vm.parseTomlUint(toml, ".yieldFactorMax");

        c.swapFactory = vm.parseTomlAddress(toml, ".swapFactory");
        c.collateralLoanPool =
            IUniswapV3Factory(c.swapFactory).getPool(c.collateralToken, c.loanToken, c.collateralLoanPoolFee);
        c.collateralLoanPoolFee = uint24(vm.parseTomlUint(toml, ".collateralLoanPoolFee"));
        c.yieldLoanPool = IUniswapV3Factory(c.swapFactory).getPool(c.yieldToken, c.loanToken, c.yieldLoanPoolFee);
        c.yieldLoanPoolFee = uint24(vm.parseTomlUint(toml, ".yieldLoanPoolFee"));

        c.marketOracle = vm.parseTomlAddress(toml, ".marketOracle");
        c.marketIrm = vm.parseTomlAddress(toml, ".marketIrm");
        c.marketLltv = vm.parseTomlUint(toml, ".marketLltv");
        c.yieldOracle = vm.parseTomlAddress(toml, ".yieldOracle");
    }

    function _marketParams(Config memory c) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: c.loanToken,
            collateralToken: c.collateralToken,
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
    // function _requireMarketExists(Config memory c) internal view returns (Market memory m) {
    //     m = IMorpho(0x9a094eA4AbE343D908E1bDE9fC478D71b41D665f).market(_marketId(c));
    //     require(
    //         m.lastUpdate != 0, "Morpho market for config params does not exist; check marketOracle/marketIrm/marketLltv"
    //     );
    // }

    /// @dev Both FlowSwap pools the vault trades on must exist.
    function _requirePoolsExist(Config memory c) internal view {
        address yieldPool = IUniswapV3Factory(c.swapFactory).getPool(c.yieldToken, c.loanToken, c.yieldLoanPoolFee);
        require(yieldPool != address(0), "yield/debt pool missing");
        require(yieldPool == c.yieldLoanPool, "config yieldLoanPool does not match factory");
        require(c.collateralLoanPool != address(0), "asset/debt pool missing");
    }

    /// @dev The account whose key signs broadcast transactions. Must be
    ///      called inside a `vm.startBroadcast()` section.
    function _broadcaster() internal view returns (address sender) {
        (, sender,) = vm.readCallers();
    }
}
