# Historical balance proof service

Builds the proofs `HistoricalBalanceVerifier` needs to verify an address's ETH
balance ~100 blocks in the past: the block's canonical header RLP plus a
Merkle-Patricia account proof from `eth_getProof`.

## Requirements

- Node 18+
- An **execution-layer JSON-RPC** endpoint supporting `eth_getBlockByNumber` and
  `eth_getProof` (Geth, Nethermind, Erigon, Besu, and providers like Alchemy/Infura
  all do). No archive node needed — the target block is only ~100 blocks old.

## Run

```bash
cd balance-proof-service
npm install
# Sepolia by default. Point RPC_URL at a Sepolia execution RPC:
RPC_URL=https://sepolia.infura.io/v3/<KEY> npm start
# -> balance-proof-service on :8081  network=sepolia  blocksAgo=100
```

Environment:

| var          | default                  | meaning                                          |
|--------------|--------------------------|--------------------------------------------------|
| `RPC_URL`    | `http://localhost:8545`  | execution-layer JSON-RPC (must match `NETWORK`)  |
| `NETWORK`    | `sepolia`                | `sepolia`, `mainnet`, `holesky`                  |
| `PORT`       | `8081`                   | HTTP port                                        |
| `BLOCKS_AGO` | `100`                    | how far behind head to anchor the proof          |

Migrating networks = change `NETWORK` + `RPC_URL`. The contract's MIN_AGE and the
BLOCKHASH 256-block window are chain-independent.

## Endpoint

```
GET /balance-proof/:address
```

Returns:

```jsonc
{
  "address": "0x…",
  "currentBlock": 6123456,
  "targetBlock": 6123356,             // currentBlock - BLOCKS_AGO
  "age": 100,
  "stateRoot": "0x…",
  "headerRLP": "0x…",                 // keccak256 == blockhash(targetBlock) on-chain
  "accountProof": ["0x…", …],         // MPT nodes, root-first
  "reportedBalanceWei": "1000000000000000000",
  "reportedNonce": 3
}
```

## Why the header is rebuilt by hand

The contract checks `keccak256(headerRLP) == blockhash(targetBlock)`, so the header
must be **byte-exact**. The field set differs by fork (London added `baseFeePerGas`,
Shanghai `withdrawalsRoot`, Cancun the blob fields + `parentBeaconBlockRoot`, Prague
`requestsHash`). The service RLP-encodes the canonical field list directly from
`eth_getBlockByNumber` (optional fields included only when present, so Merge → Prague
all work) and **asserts the rebuilt hash equals the node's reported block hash** before
returning. This avoids depending on a library keeping pace with each fork — verified
working against post-Pectra mainnet. The only dependencies are `express` and the
audited `@noble/hashes` (for keccak).

## Window caveat

The contract resolves block hashes via the `BLOCKHASH` opcode (last 256 blocks) and
the EIP-2935 history contract (last **8191** blocks, ~27 h on mainnet) — so the proof
target may be up to 8191 blocks old. Anchoring at head-100 (`BLOCKS_AGO`) leaves ample
margin to land the transaction; submit before the target ages past 8191, or regenerate.

Practical limit: a deep target (older than ~128 blocks) also needs an **archive** RPC,
because `eth_getProof` requires the historical *state* and pruned full nodes only keep
~128 recent states. The default `BLOCKS_AGO=100` works on a normal full node.
