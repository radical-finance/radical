#!/usr/bin/env bash
set -euo pipefail

killall anvil || true

# sleep 2

anvil --steps-tracing > /dev/null 2>&1 &
# --block-time 1

# Wait for anvil to start on port 8545
while ! nc -z localhost 8545; do
    sleep 0.01
done

forge script script/solidity/DeployUniswap.s.sol --rpc-url http://localhost:8545 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --legacy --unlocked --broadcast --slow --skip-simulation --non-interactive --tc DeployUniswap -s "run()" -vvvv

# Doing this foundry can't have the same file with write and read perms
cp artifacts/uniswap_addresses_dev.json artifacts/uniswap_addresses_dev_read.json
cat artifacts/uniswap_addresses_dev.json

