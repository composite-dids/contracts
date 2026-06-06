#!/usr/bin/env bash
#
# Deploy DIDRegistry with a CONFIGURABLE mechanism over n identity signals.
#
# A signal is a verifier exposing identityWitness(address) -> bytes32. The default set
# (n = 4) is the AND of all four:
#
#   signal 0  Validator identity  -> BeaconIdentityVerifier
#   signal 1  GitHub account      -> GithubIdentity   (Reclaim)
#   signal 2  Google / gmail      -> GoogleIdentity   (Reclaim)
#   signal 3  arXiv account       -> ArxivIdentity    (Reclaim)
#
# The mechanism is a negation-free DNF: a disjunction (OR) of conjunctive terms, each a
# signal bitmap (bit i = signal i). Pass it with --terms:
#
#   --terms 15            => 0b1111            : validator AND github AND gmail AND arxiv  (default)
#   --terms 3,12          => 0b0011, 0b1100    : (validator AND github) OR (gmail AND arxiv)
#
# Usage:
#   scripts/deploy-did-registry.sh \
#       --validator 0x... --github 0x... --google 0x... --arxiv 0x... \
#       [--signals 0x..,0x..,..]   # OR give the signal list explicitly (overrides the named flags)
#       [--terms 15]               # DNF term bitmaps (default: single all-AND term)
#       [--depth 24]               # Sparse Merkle Tree depth per signal
#
# Each signal uses the identityWitness(address) selector. The witness is read on-chain,
# and each signal's Sparse Merkle Tree forbids registering the same witness twice.
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

# ---- baked-in config (same throwaway Sepolia deployer as scripts/deploy.sh) ----
RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${PRIVATE_KEY:-0x78b0c03883c127949304f5c5e1598f63ba3b9a4e75afd966a2fd2aecc2a16c02}"
EXPLORER="https://sepolia.etherscan.io/address"

VALIDATOR=""; GITHUB=""; GOOGLE=""; ARXIV=""; SIGNALS=""; TERMS="15"; DEPTH=24
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validator) VALIDATOR="$2"; shift 2;;
    --github)    GITHUB="$2";    shift 2;;
    --google)    GOOGLE="$2";    shift 2;;
    --arxiv)     ARXIV="$2";     shift 2;;
    --signals)   SIGNALS="$2";   shift 2;;   # comma-separated, overrides named flags
    --terms)     TERMS="$2";     shift 2;;   # comma-separated DNF term bitmaps
    --depth)     DEPTH="$2";     shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

cd "$(dirname "$0")/.."

# Assemble the signal list: explicit --signals wins; else the named flags in order.
if [[ -z "$SIGNALS" ]]; then
  for a in "$VALIDATOR" "$GITHUB" "$GOOGLE" "$ARXIV"; do
    [[ -n "$a" ]] && SIGNALS="${SIGNALS:+$SIGNALS,}$a"
  done
fi
[[ -z "$SIGNALS" ]] && { echo "no signals given (use --validator/--github/--google/--arxiv or --signals)" >&2; exit 1; }

IFS=',' read -r -a SIG_ARR <<< "$SIGNALS"
N="${#SIG_ARR[@]}"

# Every signal uses identityWitness(address).
WSEL="$(cast sig 'identityWitness(address)')"
SELS=""
for ((i=0; i<N; i++)); do SELS="${SELS:+$SELS,}$WSEL"; done

# Default mechanism = single all-AND term (2**N - 1) if --terms left at the literal default.
if [[ "$TERMS" == "15" && "$N" -ne 4 ]]; then
  TERMS="$(( (1 << N) - 1 ))"
fi

echo "Network : Sepolia ($RPC_URL)"
echo "Signals : n=$N  depth=$DEPTH"
for ((i=0; i<N; i++)); do printf "  signal%d  %s\n" "$i" "${SIG_ARR[$i]}"; done
echo "Mechanism (DNF terms, bit i = signal i): [$TERMS]"
echo

echo "Deploying DIDRegistry…"
OUT="$(forge create "DIDRegistry.sol:DIDRegistry" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$DEPTH" \
    "[$SIGNALS]" \
    "[$SELS]" \
    "[$TERMS]" 2>&1)" || { echo "$OUT" >&2; exit 1; }
REG="$(echo "$OUT" | awk '/Deployed to/{print $3}')"

echo "✓ DIDRegistry: $REG"
echo
echo "Sanity checks:"
echo "  TREE_DEPTH = $(cast call "$REG" 'TREE_DEPTH()(uint256)' --rpc-url "$RPC_URL")"
echo "  numSignals = $(cast call "$REG" 'numSignals()(uint256)' --rpc-url "$RPC_URL")"
echo "  termCount  = $(cast call "$REG" 'termCount()(uint256)' --rpc-url "$RPC_URL")"
echo "  term[0]    = $(cast call "$REG" 'terms(uint256)(uint8)' 0 --rpc-url "$RPC_URL")  (bitmap of the first disjunct)"
echo
echo "Etherscan: $EXPLORER/$REG"
echo "Open the UI: frontend/register.html?net=sepolia&registry=$REG"
