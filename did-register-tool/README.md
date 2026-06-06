# did-register-tool

Client library + CLI for **`DIDRegistry`** — aggregate a user's identity *signals*
and build the registration tuple the contract expects.

## What the registry does

A user registers by aggregating one or more identity **signals** that already live
in other verifier contracts:

| Slot | Signal                    | Source contract              | Accessor               |
|------|---------------------------|------------------------------|------------------------|
| 0    | Beacon validator identity | `BeaconIdentityVerifier`     | `isVerified(address)`  |
| 1    | Historical balance        | `HistoricalBalanceVerifier`  | `isEligible(address)`  |
| 2    | GitHub account            | `GithubIdentity` (Reclaim)   | `isVerified(address)`  |
| 3    | Google account            | `GoogleIdentity` (Reclaim)   | `isVerified(address)`  |

All four slots are now wired by `scripts/deploy-did-registry.sh`. Slots accept any
verifier exposing a `someAccessor(address) view returns (bool)`; a 5th+ signal would
need a new registry (the slot count is fixed at 4) or could replace an existing slot
via `setSignalSource`.

`DIDRegistry`:

1. **Verifies** the signals on-chain by calling those verifier contracts.
2. **De-duplicates** with an append-only Merkle tree + a `used` set, so the *same*
   proof registers only once.
3. **Issues** one non-transferable credential (a soulbound token) per registered
   proof. Presenting a *new* proof (a different signal-set) mints another credential,
   so an account can accumulate several over time.

### The `(x, r', π)` scheme

To register you submit `(x, r', π)`:

- `x`  — the identity commitment (leaf): `previewCommitment(account, signalBitmap)`.
- `r'` — `newRoot`, the Merkle root *after* `x` is appended.
- `π`  — `insertionPath`, the sibling hashes along `x`'s path.

The contract checks, against the public current root `r`, that the next free slot is
empty and that inserting `x` along `π` yields exactly `r'`. This tool computes `r'`
and `π` for you by replaying the registry's `Registered` events.

## Install

```bash
cd did-register-tool
npm install
```

## CLI

```bash
# What signals does this account hold?
node cli.js signals  --rpc $RPC --registry $REGISTRY --account 0xYourAddr

# Build the (signalBitmap, newRoot, insertionPath) tuple (no tx):
node cli.js prepare  --rpc $RPC --registry $REGISTRY --account 0xYourAddr

# Aggregate + submit the registration tx:
node cli.js register --rpc $RPC --registry $REGISTRY --pk 0xYourPrivKey

# Inspect the tree:
node cli.js root     --rpc $RPC --registry $REGISTRY
```

Flags can also come from env vars (`DID_RPC`, `DID_REGISTRY`, `DID_ACCOUNT`, …).

## Library

```js
import { getRegistry, prepareRegistration } from "did-register-tool/did-registry.js";

const registry = getRegistry(REGISTRY_ADDR, signer);
const plan = await prepareRegistration(registry, await signer.getAddress());
// plan.callArgs === [signalBitmap, newRoot, insertionPath]
if (plan.bitmap !== 0) await registry.register(...plan.callArgs);
```

`incremental-merkle.js` is a standalone, dependency-light (ethers only) mirror of the
contract's accumulator — handy if you want to generate membership proofs of a leaf
against a historical root for downstream "I am a registered DID" proofs.

## Offline self-test

```bash
node selftest.js   # checks the tree hashing matches the contract's constants
```

## Notes

- Two users registering in the **same block** race for the next leaf index; the
  second tx reverts with `stale root / bad path` — just re-run `prepare` and resubmit.
  This is inherent to client-supplied `(r', π)`.
- The empty-tree root and every root the tree has ever had are kept `isKnownRoot`, so
  membership proofs against historical roots stay valid.
