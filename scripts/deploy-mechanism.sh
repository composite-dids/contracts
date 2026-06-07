#!/usr/bin/env bash
#
# Deploy a composite-DID mechanism in one shot:
#   1. a FRESH signal verifier per assigned source (in slot order), then
#   2. an atomic DIDRegistry(address[] verifiers, uint8[] terms) over them.
#
# This is what the developer tool (Evaluation_UI) calls so its "Deploy" returns a real
# REGISTRY address (not a bare verifier). The REGISTRY etherscan link is printed FIRST so
# the backend's `links.get(0)` is the registry.
#
# Usage:
#   scripts/deploy-mechanism.sh --sources github,google,arxiv,balance --terms 15
#
#   --sources : comma list in SLOT ORDER; each of: github | google | arxiv | balance
#               (the dev tool maps GitHub->github, Gmail->google, arXiv->arxiv, Ether->balance)
#   --terms   : comma list of DNF term bitmaps, bit i = slot i
#               e.g. 15 => 0b1111 (slot0 AND slot1 AND slot2 AND slot3)
#                    3,12 => (slot0 AND slot1) OR (slot2 AND slot3)
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

# ---- baked-in config (same throwaway Sepolia deployer as scripts/deploy.sh) ----
RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${PRIVATE_KEY:-0x78b0c03883c127949304f5c5e1598f63ba3b9a4e75afd966a2fd2aecc2a16c02}"
EXPLORER="https://sepolia.etherscan.io/address"
RECLAIM_VERIFIER="${RECLAIM_VERIFIER:-0xAe94FB09711e1c6B057853a515483792d8e474d0}"
RECLAIM_PROVIDER_HASH=""          # "" => skip provider binding (any proof for the provider)
LOOKBACK="${LOOKBACK:-100}"        # HistoricalBalanceVerifier MIN_AGE (blocks)
MIN_ETH="${MIN_ETH:-0.1}"          # HistoricalBalanceVerifier threshold
ARXIV_MIN_PAPERS="${ARXIV_MIN_PAPERS:-0}"

SOURCES=""; TERMS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sources) SOURCES="$2"; shift 2;;
    --terms)   TERMS="$2";   shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -z "$SOURCES" ]] && { echo "missing --sources (e.g. github,google,arxiv,balance)" >&2; exit 1; }
[[ -z "$TERMS"   ]] && { echo "missing --terms (e.g. 15)" >&2; exit 1; }

# Run from the repo root (parent of scripts/) so forge finds the sources.
cd "$(dirname "$0")/.."
MIN_WEI="$(cast to-wei "$MIN_ETH" ether)"

# deploy <sol:Contract> [constructor args...] -> prints deployed address on stdout
deploy() {
  local sol="$1"; shift
  local out
  out="$(forge create "$sol" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
    --constructor-args "$@" 2>&1)" || { echo "$out" >&2; return 1; }
  echo "$out" | awk '/Deployed to/{print $3}'
}

IFS=',' read -r -a SRC_ARR <<< "$SOURCES"
ADDRS=()
LABELS=()
for src in "${SRC_ARR[@]}"; do
  src="$(echo "$src" | tr '[:upper:]' '[:lower:]' | xargs)"   # normalise/trim
  case "$src" in
    github)        a="$(deploy "GithubIdentity.sol:GithubIdentity" "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH")";;
    google|gmail)  a="$(deploy "GoogleIdentity.sol:GoogleIdentity" "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH")";;
    arxiv)         a="$(deploy "ArxivIdentity.sol:ArxivIdentity"  "$RECLAIM_VERIFIER" "$RECLAIM_PROVIDER_HASH" "$ARXIV_MIN_PAPERS")";;
    balance|ether) a="$(deploy "HistoricalBalanceVerifier.sol:HistoricalBalanceVerifier" "$LOOKBACK" "$MIN_WEI")";;
    *) echo "unknown source: '$src' (want github|google|arxiv|balance)" >&2; exit 1;;
  esac
  [[ -z "$a" ]] && { echo "verifier deploy failed for source: $src" >&2; exit 1; }
  ADDRS+=("$a"); LABELS+=("$src")
done

SIGNALS="$(IFS=,; echo "${ADDRS[*]}")"

REG_OUT="$(forge create "DIDRegistry.sol:DIDRegistry" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "[$SIGNALS]" "[$TERMS]" 2>&1)" || { echo "$REG_OUT" >&2; exit 1; }
REG="$(echo "$REG_OUT" | awk '/Deployed to/{print $3}')"
[[ -z "$REG" ]] && { echo "$REG_OUT" >&2; exit 1; }

# --- REGISTRY etherscan link FIRST (backend returns links.get(0)) ---
echo "$EXPLORER/$REG"
for a in "${ADDRS[@]}"; do echo "$EXPLORER/$a"; done

# --- human-readable summary (non-URL lines; ignored by the link parser) ---
echo "DIDRegistry : $REG"
for i in "${!ADDRS[@]}"; do printf "slot %d (%s) : %s\n" "$i" "${LABELS[$i]}" "${ADDRS[$i]}"; done
echo "numSignals  = $(cast call "$REG" 'numSignals()(uint256)' --rpc-url "$RPC_URL")"
echo "termCount   = $(cast call "$REG" 'termCount()(uint256)' --rpc-url "$RPC_URL")"
