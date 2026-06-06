#!/usr/bin/env bash
#
# One-command LOCAL demo of the composite-DID registration flow -- for a hackathon
# judge who just wants to open the HTML and click through it, without owning a
# validator or doing the Reclaim zkTLS QR flow.
#
# It boots a local Anvil chain, deploys MOCK signal verifiers (each exposes
# identityWitness(address) and is toggleable), deploys DIDRegistry with the default
# mechanism (AND of validator + GitHub + Google + arXiv), grants three of the four
# signals to the standard Anvil test account (so you can watch the AND gate, then flip
# the last one to register), serves the frontend, and prints the URL + MetaMask steps.
#
#   scripts/demo-local.sh        # then open the printed URL; Ctrl-C to tear down
#
# Requirements: foundry (anvil/forge/cast) and python3 (for the static file server).
#
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC="http://127.0.0.1:8545"
PORT=8000
BACKEND_PORT=8090
# Well-known Anvil/Foundry default account #0. LOCAL TEST KEY ONLY -- never use on a
# real network or send it anything of value.
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ACC="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

cd "$(dirname "$0")/.."

ANVIL_PID=""; WWW_PID=""; BACKEND_PID=""; CLEANED=""
cleanup() {
  [ -n "$CLEANED" ] && return; CLEANED=1
  echo; echo "tearing down..."
  [ -n "$WWW_PID" ] && kill "$WWW_PID" 2>/dev/null || true
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "> starting anvil..."
anvil >/tmp/anvil-demo.log 2>&1 & ANVIL_PID=$!
for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.25; done

cf() { forge create "$1" --rpc-url "$RPC" --private-key "$PK" --broadcast 2>/dev/null | awk '/Deployed to/{print $3}'; }
echo "> deploying mock signal verifiers (identityWitness, toggleable)..."
VALIDATOR=$(cf test/DIDRegistry.t.sol:MockSignal)
GITHUB=$(cf test/DIDRegistry.t.sol:MockSignal)
GOOGLE=$(cf test/DIDRegistry.t.sol:MockSignal)
ARXIV=$(cf test/DIDRegistry.t.sol:MockSignal)

echo "> deploying DIDRegistry (default mechanism = AND of all four signals)..."
REG=$(RPC_URL="$RPC" PRIVATE_KEY="$PK" scripts/deploy-did-registry.sh \
        --validator "$VALIDATOR" --github "$GITHUB" --google "$GOOGLE" --arxiv "$ARXIV" --depth 16 \
        2>/dev/null | awk '/DIDRegistry:/{print $3}')

# Each signal's witness is any non-zero bytes32. Grant three; leave arXiv off so the AND
# gate is visible in the UI.
WV=$(cast keccak "validator:$ACC"); WG=$(cast keccak "github:$ACC"); WM=$(cast keccak "google:$ACC"); WA=$(cast keccak "arxiv:$ACC")
echo "> granting validator + GitHub + Google to the test account (arXiv left off on purpose)..."
cast send "$VALIDATOR" "set(address,bytes32)" "$ACC" "$WV" --rpc-url "$RPC" --private-key "$PK" >/dev/null
cast send "$GITHUB"    "set(address,bytes32)" "$ACC" "$WG" --rpc-url "$RPC" --private-key "$PK" >/dev/null
cast send "$GOOGLE"    "set(address,bytes32)" "$ACC" "$WM" --rpc-url "$RPC" --private-key "$PK" >/dev/null

echo "> starting the prove-only backend on port $BACKEND_PORT..."
( cd did-register-tool && RPC_URL="$RPC" REGISTRY="$REG" PORT="$BACKEND_PORT" node backend.js >/tmp/did-backend.log 2>&1 ) & BACKEND_PID=$!
for _ in $(seq 1 20); do curl -s "http://127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1 && break; sleep 0.25; done

echo "> serving frontend on port $PORT..."
( cd frontend && python3 -m http.server "$PORT" >/tmp/www-demo.log 2>&1 ) & WWW_PID=$!

cat <<EOF

=================================================================
  LOCAL DEMO READY
  DIDRegistry : $REG
  Backend     : http://127.0.0.1:$BACKEND_PORT  (prove-only; holds the per-signal trees + ledger)
  Mechanism   : validator AND github AND google AND arxiv  (single all-AND term)
  Open this   : http://localhost:$PORT/register.html?net=localhost&registry=$REG&backend=http://127.0.0.1:$BACKEND_PORT

  NO METAMASK NEEDED: the page detects the local chain and uses the built-in Anvil
  test account ($ACC) automatically. Just open the URL and click "Connect".
  (If you DO have MetaMask, it uses that instead; import key $PK and add the
   Localhost network RPC=http://127.0.0.1:8545 ChainId=31337.)

  IN THE PAGE:
   - Click Connect. The mechanism shows the AND formula; validator/github/google are
     held ✓, arxiv is "required — missing", so Register is disabled.
   - Flip the missing arXiv signal on, then Refresh + Register:
        cast send $ARXIV "set(address,bytes32)" $ACC $WA --rpc-url $RPC --private-key $PK
   - Now all four show held ✓ -> click Register. The frontend asks the BACKEND to build
     the per-signal insert proofs (it holds the whole trees), submits them, and one
     soulbound credential is minted. The "Registered identities (ledger)" card then shows
     the address -> issued-signals hashtable the backend keeps (reusable for voting).
     Re-registering the same witnesses is rejected on-chain (per-signal SMT dedup).

  BACKEND API (curl):
     curl http://127.0.0.1:$BACKEND_PORT/mechanism
     curl http://127.0.0.1:$BACKEND_PORT/account/$ACC
     curl "http://127.0.0.1:$BACKEND_PORT/prove?account=$ACC"
     curl http://127.0.0.1:$BACKEND_PORT/registry      # address -> signals ledger

  TRY AN OR MECHANISM: redeploy with two disjuncts, e.g.
     scripts/deploy-did-registry.sh --validator $VALIDATOR --github $GITHUB \\
       --google $GOOGLE --arxiv $ARXIV --terms 3,12 --depth 16
     => (validator AND github) OR (google AND arxiv); the UI lets you pick a term.

  Press Ctrl-C here to stop anvil + the web server.
=================================================================
EOF

wait "$ANVIL_PID"
