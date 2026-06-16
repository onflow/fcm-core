// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Compile anchor only. The Alliance ERC4626Router is pinned to solc 0.8.10,
// which cannot share a compilation unit with the 0.8.20 vault. Importing it
// here (its own unit) forces the artifact to build so integration tests can
// deploy it via `vm.deployCode("ERC4626Router.sol:ERC4626Router", ...)`.
// NB: a filtered `forge test --match-*` run won't compile this file (nothing
// the matched test imports references it), so the artifact is missing and the
// integration tests fail with "no matching artifact". Run the full `forge test`.
import {ERC4626Router} from "erc4626-alliance/ERC4626Router.sol";
