# Beacon identity proof service

Generates the SSZ merkle proofs that `BeaconIdentityVerifier` needs, from a beacon
node. Given a validator index it returns everything the contract call requires plus a
few convenience fields the frontend uses.

## Requirements

- Node 18+
- Access to a **beacon node** with the standard REST API and the `debug` namespace
  enabled (it serves the full `BeaconState`). No execution node is needed — the
  EIP-4788 timestamp is read from the beacon block's execution payload.
  - Lighthouse: run with `--http` (debug endpoints are on by default).
  - Nimbus/Teku/Lodestar/Prysm: enable the standard + debug REST API.

> ⚠ `/eth/v2/debug/beacon/states/{id}` downloads the **entire** beacon state
> (hundreds of MB on mainnet). Point `BEACON_URL` at a node you control.

## Run

```bash
cd proof-service
npm install
# Sepolia is the default. Point BEACON_URL at a Sepolia beacon node:
BEACON_URL=http://localhost:5052 npm start
# -> proof-service on :8080  network=sepolia
```

Environment:

| var          | default                  | meaning                                    |
|--------------|--------------------------|--------------------------------------------|
| `BEACON_URL` | `http://localhost:5052`  | beacon node REST endpoint (must match `NETWORK`) |
| `NETWORK`    | `sepolia`                | chain config (`sepolia`, `mainnet`, `hoodi`…) |
| `PORT`       | `8080`                   | HTTP port                                  |
| `SLOT_LAG`   | `4`                      | slots behind head to anchor (reorg margin) |

**Migrating to another network** is a single env change, e.g. `NETWORK=mainnet`
with a mainnet `BEACON_URL`. The EIP-4788 beacon-roots contract is at the same
address on every chain, and Sepolia is on Electra (state-tree depth 6) just like
mainnet, so the deployed contract's depth is unchanged.

## Endpoint

```
GET /proof/:validatorIndex
```

Returns:

```jsonc
{
  "validatorIndex": 123456,
  "targetSlot": 9876543,
  "beaconTimestamp": 1750000000,      // EIP-4788 key; beacon_roots(t) == beaconBlockRoot
  "beaconStateTreeDepth": 6,          // DEPLOY THE CONTRACT WITH THIS VALUE
  "beaconStateRoot": "0x…",
  "validatorFields": ["0x…", … 8],    // the 8 Validator container leaves
  "validatorProof":  ["0x…", … 47],   // validatorRoot -> beaconStateRoot
  "stateRootProof":  ["0x…", "0x…", "0x…"], // beaconStateRoot -> beaconBlockRoot
  "withdrawalAddress": "0x…",         // recovered from 0x01/0x02 creds
  "credsType": 1,
  "effectiveBalanceGwei": 32000000000,
  "exited": false
}
```

## Notes on correctness

- **Fork sensitivity.** The proof's `beaconStateTreeDepth` (5 for Deneb, 6 for
  Electra) must match the value `BeaconIdentityVerifier` was deployed with. The
  service derives it from the proof length and the frontend warns on mismatch.
- **Anchoring.** We prove against target block `TB` (root `R`). The next beacon
  block `CB` carries `parent_beacon_block_root == R` in its execution payload, so
  `beacon_roots(CB.timestamp)` returns `R` on-chain. `beaconTimestamp` is that
  payload timestamp.
- **Window.** EIP-4788 keeps only ~8191 slots (~27h). Proofs must be submitted
  within that window of the target slot; otherwise the on-chain lookup reverts.
