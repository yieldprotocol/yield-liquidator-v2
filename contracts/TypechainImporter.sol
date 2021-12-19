// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.1;

import "@yield-protocol/vault-v2/contracts/Cauldron.sol";
import "@yield-protocol/vault-v2/contracts/Join.sol";
import "@yield-protocol/vault-v2/contracts/oracles/compound/CompoundMultiOracle.sol";
import "@yield-protocol/vault-v2/contracts/oracles/chainlink/ChainlinkMultiOracle.sol";
import "@yield-protocol/vault-v2/contracts/FYToken.sol";
import "@yield-protocol/vault-v2/contracts/Witch.sol";
import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";