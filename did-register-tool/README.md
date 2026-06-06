# did-register-tool

Client library + CLI for **`DIDRegistry`** — inspect the eligibility **mechanism**,
build the per-signal **Sparse Merkle Tree** insert proofs, and register.

## What the registry does

A registry is configured with `n` identity **signals** and a **mechanism** — a
negation-free DNF (a disjunction of conjunctive *terms*). Each signal is a verifier
exposing `identityWitness(address) view returns (bytes32)`:

| Slot | Signal             | Source contract            | Witness                       |
|------|--------------------|----------------------------|-------------------------------|
| 0    | Validator identity | `BeaconIdentityVerifier`   | validator index               |
| 1    | GitHub account     | `GithubIdentity` (Reclaim) | GitHub username               |
| 2    | Google account     | `GoogleIdentity` (Reclaim) | email                         |
| 3    | arXiv account      | `ArxivIdentity` (Reclaim)  | first paper title             |

**Mechanism (DNF).** Eligibility is `OR` of `AND`-terms, e.g.

- `[0b1111]` → `validator AND github AND gmail AND arxiv` (the default, all-AND).
- `[0b0011, 0b1100]` → `(validator AND github) OR (gmail AND arxiv)`.

To register you pick **one term** you satisfy and submit, for every signal in it, an
insert proof. `DIDRegistry`:

1. **Reads the witness** for each signal on-chain (the caller can't forge it).
2. **De-duplicates per signal** with a Sparse Merkle Tree keyed by the witness: the
   contract stores only the root, and a witness already in the tree is rejected. The
   same external account therefore registers at most once per signal — even from a
   different wallet.
3. **Issues** one non-transferable soulbound credential.

### The per-signal `(newRoot, siblings)` proof

For each signal in your chosen term you submit an `Insert { newRoot, siblings }`:

- `newRoot`  — the signal tree's root *after* your witness's leaf is filled.
- `siblings` — the sibling hashes along the leaf's path (length `TREE_DEPTH`).

The contract folds the proof twice: from the empty leaf (must equal the current root —
proves your witness is **not** already registered) and from the filled leaf (must equal
`newRoot`). The witness/key is read on-chain, so only the genuine insert verifies. This
tool computes `newRoot` and `siblings` by replaying the registry's `SignalInserted`
events into a local `SparseMerkleTree`.

## Install

```bash
cd did-register-tool
npm install
```

## CLI

```bash
# Show the mechanism (signals + DNF terms + human formula):
node cli.js mechanism --rpc $RPC --registry $REGISTRY

# Which signals does an account hold, and which terms can it register?
node cli.js signals   --rpc $RPC --registry $REGISTRY --account 0xYourAddr

# Build the per-signal insert proofs for the first satisfied term (no tx):
node cli.js prepare   --rpc $RPC --registry $REGISTRY --account 0xYourAddr [--term 1]

# Build + submit the registration tx:
node cli.js register  --rpc $RPC --registry $REGISTRY --pk 0xYourPrivKey [--term 1]
```

Flags can also come from env vars (`DID_RPC`, `DID_REGISTRY`, `DID_ACCOUNT`, …).

## Library

```js
import { getRegistry, prepareRegistration } from "did-register-tool/did-registry.js";

const registry = getRegistry(REGISTRY_ADDR, signer);
const plan = await prepareRegistration(registry, await signer.getAddress());
// plan.callArgs === [termIndex, inserts]; canRegister is false if no term is satisfied.
if (plan.canRegister) await registry.register(...plan.callArgs);
else console.log("cannot register:", plan.reason);
```

`sparse-merkle.js` is a standalone (ethers-only) mirror of the contract's per-signal
accumulator — use it to build proofs or to detect duplicates offline.

## Backend (prove-only service)

`backend.js` is an HTTP service that **backs the frontend**. It holds the *whole*
per-signal Sparse Merkle Tree in memory (synced from `SignalInserted` events) and
**generates** the insert proofs a user needs — it never verifies (the register contract
does that, and only stores roots). It also keeps a `address -> issued signals` hashtable
(from `Registered` events) for downstream use such as online voting.

```bash
RPC_URL=http://127.0.0.1:8545 REGISTRY=0xYourRegistry npm run backend   # PORT defaults to 8090
```

Endpoints (JSON, CORS-open):

| Method | Path | Returns |
|---|---|---|
| GET | `/mechanism` | signals, DNF terms, formula, depth |
| GET | `/account/:addr` | held signals, eligible terms, registered?, issued entry |
| GET | `/prove?account=0x..&term=0` | `{ termIndex, inserts:[{newRoot,siblings}], callArgs }` |
| GET | `/registry` | `{ count, entries:[{address, signals, termMask, tokenId}] }` |
| GET | `/recent?n=10` | the most recently registered N (newest first) |
| GET | `/registry/:addr` | one ledger entry (or `null`) |
| GET | `/roots` | in-memory vs on-chain root check |

The frontend (`register.html`) uses the backend when you fill the **Backend URL** field
(or pass `?backend=http://127.0.0.1:8090`): it fetches `/prove` to build the proof and
renders `/registry` as the credential ledger. With no backend it falls back to building
proofs client-side from events.

## Offline self-test

```bash
node selftest.js   # checks the SMT hashing matches the contract's constants
```

## Notes

- Two users registering the *same* signal in the **same block** race for that signal's
  root; the second tx reverts (`duplicate or stale proof`) — re-run `prepare` and
  resubmit. This is inherent to client-supplied `(newRoot, siblings)`.
- `incremental-merkle.js` remains for any append-only / membership-proof use; the
  registry itself now uses one Sparse Merkle Tree per signal.
