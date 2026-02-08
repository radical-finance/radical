#!/usr/bin/env bash
set -euo pipefail

# Build first, so it fails fast if there are errors
forge build

# TODO rename to scripts
./script/bash/start_devchain.sh

forge test --fork-url http://localhost:8545 -v --match-path test/UniswapV3Vault.t.sol #--match-contract UniswapV3VaultTest_Integration

# TODO, mae anvil run all unit tests (and pass) by default
forge test --fork-url http://localhost:8545 --match-path "test/oracles/*"

#forge test --fork-url http://localhost:8545 -vvv --fail-fast #--match-contract UniswapV3VaultTest_depositExact