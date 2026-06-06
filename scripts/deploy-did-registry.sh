#!/usr/bin/env bash
#
# Deploy DIDRegistry, wired to the four identity signals so a user can aggregate
# them all and register for one (or more) non-transferable credential(s):
#
#   slot 0  Beacon validator identity   -> isVerified(address)   (BeaconIdentityVerifier)
#   slot 1  Historical balance          -> isEligible(address)   (HistoricalBalanceVerifier)
#   slot 2  GitHub account              -> isVerified(address)   (GithubIdentity, Reclaim)
#   slot 3  Google account              -> isVerified(address)   (GoogleIdentity, Reclaim)
#
# This consumes the addresses produced by scripts/deploy.sh (which deploys the balance +
# Reclaim identity contracts). Deploy those first, then pass their addresses here.
#
# Usage:
#   scripts/deploy-did-registry.sh \
#       --beacon  0x...   \   # BeaconIdentityVerifier (optional; 0x0 placeholder if omitted)
#       --balance 0x...   \   # HistoricalBalanceVerifier
#       --github  0x...   \   # GithubIdentity
#       --google  0x...   \   # GoogleIdentity
#       [--depth 20]          # Merkle tree depth (capacity 2**depth identities)
#
# Any slot left unset is wired to address(0) (the 0x0000 placeholder) and simply
# contributes no signal until configured later via setSignalSource(slot, addr, selector).
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

# ---- baked-in config (same throwaway Sepolia deployer as scripts/deploy.sh) ----
RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
PRIVATE_KEY="${PRIVATE_KEY:-0x78b0c03883c127949304f5c5e1598f63ba3b9a4e75afd966a2fd2aecc2a16c02}"
EXPLORER="https://sepolia.etherscan.io/address"

ZERO="0x0000000000000000000000000000000000000000"
Z4="0x00000000"

BEACON="$ZERO"; BALANCE="$ZERO"; GITHUB="$ZERO"; GOOGLE="$ZERO"; DEPTH=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --beacon)  BEACON="$2";  shift 2;;
    --balance) BALANCE="$2"; shift 2;;
    --github)  GITHUB="$2";  shift 2;;
    --google)  GOOGLE="$2";  shift 2;;
    --depth)   DEPTH="$2";   shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

cd "$(dirname "$0")/.."

# Selectors: balance exposes isEligible(address); the other three expose isVerified(address).
SEL_VERIFIED="$(cast sig 'isVerified(address)')"
SEL_ELIGIBLE="$(cast sig 'isEligible(address)')"
sel() { [[ "$1" == "$ZERO" ]] && echo "$Z4" || echo "$2"; }
S0="$(sel "$BEACON"  "$SEL_VERIFIED")"
S1="$(sel "$BALANCE" "$SEL_ELIGIBLE")"
S2="$(sel "$GITHUB"  "$SEL_VERIFIED")"
S3="$(sel "$GOOGLE"  "$SEL_VERIFIED")"

echo "Network : Sepolia ($RPC_URL)"
echo "Depth   : $DEPTH  (capacity 2**$DEPTH)"
printf "  slot0 beacon  %s  %s\n" "$BEACON"  "$S0"
printf "  slot1 balance %s  %s\n" "$BALANCE" "$S1"
printf "  slot2 github  %s  %s\n" "$GITHUB"  "$S2"
printf "  slot3 google  %s  %s\n" "$GOOGLE"  "$S3"
echo

echo "Deploying DIDRegistry…"
OUT="$(forge create "DIDRegistry.sol:DIDRegistry" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$DEPTH" \
    "[$BEACON,$BALANCE,$GITHUB,$GOOGLE]" \
    "[$S0,$S1,$S2,$S3]" 2>&1)" || { echo "$OUT" >&2; exit 1; }
REG="$(echo "$OUT" | awk '/Deployed to/{print $3}')"

echo "✓ DIDRegistry: $REG"
echo
echo "Sanity checks:"
echo "  TREE_DEPTH = $(cast call "$REG" 'TREE_DEPTH()(uint256)' --rpc-url "$RPC_URL")"
echo "  root       = $(cast call "$REG" 'root()(bytes32)' --rpc-url "$RPC_URL")"
echo "  slot2      = $(cast call "$REG" 'signals(uint256)(address,bytes4)' 2 --rpc-url "$RPC_URL")"
echo "  slot3      = $(cast call "$REG" 'signals(uint256)(address,bytes4)' 3 --rpc-url "$RPC_URL")"
echo
echo "Etherscan: $EXPLORER/$REG"
echo "Open the UI: frontend/register.html?net=sepolia&registry=$REG"
