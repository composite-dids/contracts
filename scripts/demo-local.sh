#!/usr/bin/env bash
#
# One-command LOCAL demo of the composite-DID registration flow -- for a hackathon
# judge who just wants to open the HTML and click through it, without owning a
# validator, past ETH balance, or doing the Reclaim zkTLS QR flow.
#
# It boots a local Anvil chain, deploys MOCK signal verifiers you can toggle, deploys
# DIDRegistry wired to all four signals, grants a couple of signals to the standard
# Anvil test account, serves the frontend, and prints the URL + MetaMask steps.
#
#   scripts/demo-local.sh        # then open the printed URL; Ctrl-C to tear down
#
# Requirements: foundry (anvil/forge/cast) and python3 (for the static file server).
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC="http://127.0.0.1:8545"
PORT=8000
# Well-known Anvil/Foundry default account #0. LOCAL TEST KEY ONLY -- never use on a
# real network or send it anything of value.
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ACC="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

cd "$(dirname "$0")/.."

ANVIL_PID=""; WWW_PID=""; CLEANED=""
cleanup() {
  [ -n "$CLEANED" ] && return; CLEANED=1
  echo; echo "tearing down..."
  [ -n "$WWW_PID" ] && kill "$WWW_PID" 2>/dev/null || true
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "> starting anvil..."
anvil >/tmp/anvil-demo.log 2>&1 & ANVIL_PID=$!
for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.25; done

cf() { forge create "$1" --rpc-url "$RPC" --private-key "$PK" --broadcast 2>/dev/null | awk '/Deployed to/{print $3}'; }
echo "> deploying mock signal verifiers (toggleable)..."
BEACON=$(cf test/DIDRegistry.t.sol:MockBeacon)
BALANCE=$(cf test/DIDRegistry.t.sol:MockBalance)
GITHUB=$(cf test/DIDRegistry.t.sol:MockBeacon)
GOOGLE=$(cf test/DIDRegistry.t.sol:MockBeacon)

echo "> deploying DIDRegistry wired to all four signals..."
REG=$(RPC_URL="$RPC" PRIVATE_KEY="$PK" scripts/deploy-did-registry.sh \
        --beacon "$BEACON" --balance "$BALANCE" --github "$GITHUB" --google "$GOOGLE" --depth 8 \
        2>/dev/null | awk '/DIDRegistry:/{print $3}')

echo "> granting Beacon + GitHub signals to the test account (Balance + Google left off on purpose)..."
cast send "$BEACON" "set(address,bool)" "$ACC" true --rpc-url "$RPC" --private-key "$PK" >/dev/null
cast send "$GITHUB" "set(address,bool)" "$ACC" true --rpc-url "$RPC" --private-key "$PK" >/dev/null

echo "> serving frontend on port $PORT..."
( cd frontend && python3 -m http.server "$PORT" >/tmp/www-demo.log 2>&1 ) & WWW_PID=$!

cat <<EOF

=================================================================
  LOCAL DEMO READY
  DIDRegistry : $REG
  Open this   : http://localhost:$PORT/register.html?net=localhost&registry=$REG

  NO METAMASK NEEDED: the page detects the local chain and uses the built-in Anvil
  test account ($ACC) automatically. Just open the URL and click "Connect".
  (If you DO have MetaMask, it uses that instead; import key $PK and add the
   Localhost network RPC=http://127.0.0.1:8545 ChainId=31337.)

  IN THE PAGE:
   - Click Connect. You'll see: Beacon=held, GitHub=held, Balance/Google=not proven
     (each unheld row has a "prove" link).
   - Click Register -> the tx is sent -> a soulbound credential is minted. Done.

  WANT TO SHOW "a new proof mints a new token"? Flip another signal, then
  Refresh signals + Register again:
     cast send $BALANCE "set(address,bool)" $ACC true --rpc-url $RPC --private-key $PK
     cast send $GOOGLE  "set(address,bool)" $ACC true --rpc-url $RPC --private-key $PK

  Press Ctrl-C here to stop anvil + the web server.
=================================================================
EOF

wait "$ANVIL_PID"
