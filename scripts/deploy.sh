#!/usr/bin/env bash
#
# End-to-end deploy of the identity-contract suite to Sepolia:
#   - HistoricalBalanceVerifier  (caller held >= minBalance, N blocks ago)
#   - GithubIdentity             (Reclaim zkTLS: control a GitHub account)
#   - GoogleIdentity             (Reclaim zkTLS: control a Google/email account)
#
# Usage:
#   scripts/deploy.sh [lookbackBlocks] [minBalanceEth]
#
# Examples:
#   scripts/deploy.sh                # defaults: 100 blocks, 0.1 ETH
#   scripts/deploy.sh 100 0.1
#   scripts/deploy.sh 256 1
#
# Notes:
#   - lookbackBlocks (MIN_AGE) must be 1..8191. Block hashes come from the BLOCKHASH
#     opcode (last 256) and the EIP-2935 history contract (last 8191). Targets older
#     than ~128 blocks also need an ARCHIVE RPC for the proof service's eth_getProof.
#   - minBalanceEth may be fractional (e.g. 0.05); it's converted to wei.
#   - The Reclaim verifier is already deployed on Sepolia (RECLAIM_VERIFIER below).
#     Migrating networks: change RPC_URL + RECLAIM_VERIFIER (see the SDK Addresses lib
#     for each network's value).
#
set -euo pipefail

# Foundry on PATH (forge/cast).
export PATH="$HOME/.foundry/bin:$PATH"

# ---- baked-in config (throwaway Sepolia deployer) ----
RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
PRIVATE_KEY="0x78b0c03883c127949304f5c5e1598f63ba3b9a4e75afd966a2fd2aecc2a16c02"
DEPLOYER="0x1F58293409d007D88cC0065097145ca5e37c209d"
EXPLORER="https://sepolia.etherscan.io/address"

# Reclaim verifier on Sepolia (SDK Addresses.ETHEREUM_SEPOLIA).
RECLAIM_VERIFIER="0xAe94FB09711e1c6B057853a515483792d8e474d0"
# providerHash binding is unused (not present in Reclaim v5 context); leave empty.
RECLAIM_PROVIDER_HASH=""
# ArxivIdentity: 0 => rely on a captured paper id being present (>= 1 paper).
ARXIV_MIN_PAPERS=0

# ---- args (with defaults) ----
LOOKBACK="${1:-100}"
MIN_ETH="${2:-0.1}"
if ! [[ "$LOOKBACK" =~ ^[0-9]+$ ]] || (( LOOKBACK < 1 || LOOKBACK > 8191 )); then
  echo "error: lookbackBlocks must be an integer in 1..8191 (EIP-2935 window)" >&2
  exit 1
fi

# Run from the repo root (parent of this script's dir) so forge finds the sources.
cd "$(dirname "$0")/.."

MIN_WEI="$(cast to-wei "$MIN_ETH" ether)"

# deploy <sol:Contract> [constructor args...] -> prints the deployed address (stdout)
deploy() {
  local sol="$1"; shift
  local out
  out="$(forge create "$sol" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
    --constructor-args "$@" 2>&1)" || { echo "$out" >&2; return 1; }
  echo "$out" | awk '/Deployed to/{print $3}'
}

echo "Network   : Sepolia ($RPC_URL)"
echo "Deployer  : $DEPLOYER  ($(cast from-wei "$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")") ETH)"
echo "Params    : MIN_AGE=$LOOKBACK blocks, MIN_BALANCE=$MIN_ETH ETH ($MIN_WEI wei)"
echo "Reclaim   : $RECLAIM_VERIFIER"
echo
echo "Deploying HistoricalBalanceVerifier…"
BAL_ADDR="$(deploy "HistoricalBalanceVerifier.sol:HistoricalBalanceVerifier" "$LOOKBACK" "$MIN_WEI")"
echo "Deploying GithubIdentity…"
GH_ADDR="$(deploy "GithubIdentity.sol:GithubIdentity" "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH")"
echo "Deploying GoogleIdentity…"
GG_ADDR="$(deploy "GoogleIdentity.sol:GoogleIdentity" "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH")"
echo "Deploying ArxivIdentity…"
AX_ADDR="$(deploy "ArxivIdentity.sol:ArxivIdentity" "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH" "$ARXIV_MIN_PAPERS")"

echo
echo "✓ Deployed:"
printf "  %-26s %s\n" "HistoricalBalanceVerifier" "$BAL_ADDR"
printf "  %-26s %s\n" "GithubIdentity"            "$GH_ADDR"
printf "  %-26s %s\n" "GoogleIdentity"            "$GG_ADDR"
printf "  %-26s %s\n" "ArxivIdentity"             "$AX_ADDR"
echo
echo "Sanity checks:"
echo "  HBV.MIN_AGE         = $(cast call "$BAL_ADDR" 'MIN_AGE()(uint256)' --rpc-url "$RPC_URL")"
echo "  HBV.MIN_BALANCE_WEI = $(cast call "$BAL_ADDR" 'MIN_BALANCE_WEI()(uint256)' --rpc-url "$RPC_URL")"
echo "  Github.reclaim      = $(cast call "$GH_ADDR" 'reclaim()(address)' --rpc-url "$RPC_URL")"
echo "  Google.reclaim      = $(cast call "$GG_ADDR" 'reclaim()(address)' --rpc-url "$RPC_URL")"
echo "  Arxiv.minPapers     = $(cast call "$AX_ADDR" 'minPapers()(uint256)' --rpc-url "$RPC_URL")"
echo
echo "Etherscan:"
echo "  $EXPLORER/$BAL_ADDR"
echo "  $EXPLORER/$GH_ADDR"
echo "  $EXPLORER/$GG_ADDR"
echo "  $EXPLORER/$AX_ADDR"
echo
echo "Paste these into frontend/index.html (R_PROVIDERS) + balance contract field."
