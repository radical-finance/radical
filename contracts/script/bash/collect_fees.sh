#!/usr/bin/env bash
set -euo pipefail

# source ../.keys/export.sh
source ../.env
# NEXT_PUBLIC_FARMING_CONTRACT_ADDRESS=$1

cast send $NEXT_PUBLIC_FARMING_CONTRACT_ADDRESS "collectFeesAndReinvest()" --private-key $PRIVATE_KEY --rpc-url https://forno.celo.org