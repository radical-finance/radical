#!/usr/bin/env bash
set -euo pipefail


echo $PWD

source ../.env

# RPC="localhost:8545"
RPC="https://forno.celo.org"
# UNLOCKED="--unlocked"
UNLOCKED=""

forge script script/solidity/DeployUniswapFarming.s.sol --broadcast --rpc-url $RPC --sender $FROM_ADDRESS --private-key $PRIVATE_KEY $UNLOCKED -vvv