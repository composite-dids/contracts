#!/usr/bin/env bash
#
# Deploy DIDRegistry with a CONFIGURABLE mechanism over n identity signals.
#
# A signal is a verifier exposing identityWitness(address) -> bytes32. The default set
# (n = 4):
#
#   signal 0  balance   -> HistoricalBalanceVerifier  (>= 0.1 ETH ~100 blocks ago)
#   signal 1  GitHub    -> GithubIdentity   (Reclaim)
#   signal 2  Google    -> GoogleIdentity   (Reclaim)
#   signal 3  arXiv     -> ArxivIdentity    (Reclaim)
#
# Mechanism is a negation-free DNF: OR of conjunctive terms, each a signal bitmap.
#   --terms 15            => 0b1111            : balance AND github AND google AND arxiv  (default)
#   --terms 3,12          => 0b0011, 0b1100    : (balance AND github) OR (google AND arxiv)
#
# De-duplication is an on-chain hashtable (witness -> registrant) per signal: reusing the
# same identity for a signal reverts. No Merkle proofs / off-chain tooling needed.
#
# Usage:
#   scripts/deploy-did-registry.sh \
#       --balance 0x... --github 0x... --google 0x... --arxiv 0x... \
#       [--signals 0x..,0x..,..]   # OR give the signal list explicitly (overrides named flags)
#       [--terms 15]               # DNF term bitmaps (default: single all-AND term)
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

# ---- baked-in config (same throwaway Sepolia deployer as scripts/deploy.sh) ----
RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${PRIVATE_KEY:-0x78b0c03883c127949304f5c5e1598f63ba3b9a4e75afd966a2fd2aecc2a16c02}"
EXPLORER="https://sepolia.etherscan.io/address"

BALANCE=""; GITHUB=""; GOOGLE=""; ARXIV=""; SIGNALS=""; TERMS="15"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --balance)  BALANCE="$2"; shift 2;;
    --github)   GITHUB="$2";  shift 2;;
    --google)   GOOGLE="$2";  shift 2;;
    --arxiv)    ARXIV="$2";   shift 2;;
    --signals)  SIGNALS="$2"; shift 2;;   # comma-separated, overrides named flags
    --terms)    TERMS="$2";   shift 2;;   # comma-separated DNF term bitmaps
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

cd "$(dirname "$0")/.."

# Assemble the signal list: explicit --signals wins; else the named flags in order.
if [[ -z "$SIGNALS" ]]; then
  for a in "$BALANCE" "$GITHUB" "$GOOGLE" "$ARXIV"; do
    [[ -n "$a" ]] && SIGNALS="${SIGNALS:+$SIGNALS,}$a"
  done
fi
[[ -z "$SIGNALS" ]] && { echo "no signals given (use --balance/--github/--google/--arxiv or --signals)" >&2; exit 1; }

IFS=',' read -r -a SIG_ARR <<< "$SIGNALS"
N="${#SIG_ARR[@]}"

# Each signal implements ISignalVerifier.verifyAndGetWitness(address,bytes); the registry
# uses a fixed interface, so no per-signal selectors are needed.

# Default mechanism = single all-AND term (2**N - 1) if --terms left at the literal default.
if [[ "$TERMS" == "15" && "$N" -ne 4 ]]; then
  TERMS="$(( (1 << N) - 1 ))"
fi

echo "Network : Sepolia ($RPC_URL)"
echo "Signals : n=$N"
for ((i=0; i<N; i++)); do printf "  signal%d  %s\n" "$i" "${SIG_ARR[$i]}"; done
echo "Mechanism (DNF terms, bit i = signal i): [$TERMS]"
echo

echo "Deploying DIDRegistry…"
OUT="$(forge create "DIDRegistry.sol:DIDRegistry" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "[$SIGNALS]" "[$TERMS]" 2>&1)" || { echo "$OUT" >&2; exit 1; }
REG="$(echo "$OUT" | awk '/Deployed to/{print $3}')"

echo "✓ DIDRegistry: $REG"
echo
echo "Sanity checks:"
echo "  numSignals = $(cast call "$REG" 'numSignals()(uint256)' --rpc-url "$RPC_URL")"
echo "  termCount  = $(cast call "$REG" 'termCount()(uint256)' --rpc-url "$RPC_URL")"
echo "  term[0]    = $(cast call "$REG" 'terms(uint256)(uint8)' 0 --rpc-url "$RPC_URL")  (bitmap of the first disjunct)"
echo
echo "Etherscan: $EXPLORER/$REG"
echo "Open the UI: frontend/index.html (Register tab) -> paste $REG"
