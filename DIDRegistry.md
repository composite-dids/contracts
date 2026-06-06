# DIDRegistry — composite DID with per-signal Sparse Merkle Trees + a DNF mechanism

`DIDRegistry` registers a decentralised identity by evaluating a configurable boolean
**mechanism** over `n` identity **signals**, de-duplicating each signal with its own
**Sparse Merkle Tree** (SMT), and issuing one non-transferable **soulbound credential**.

---

## 1. System architecture

```
                Signals — each a verifier exposing identityWitness(address) -> bytes32
 ┌────────────────────────┐ ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
 │ BeaconIdentityVerifier │ │ GithubIdentity │ │ GoogleIdentity │ │  ArxivIdentity │
 │  witness=validatorIndex│ │ witness=user   │ │ witness=email  │ │ witness=paper  │
 └───────────┬────────────┘ └───────┬────────┘ └───────┬────────┘ └───────┬────────┘
       signal 0             signal 1│          signal 2 │           signal 3│
             └───────────────┬──────┴───────────┬───────┴───────────────────┘
                             │  witnessOf(s, msg.sender) -> bytes32 (0 = not held)
                    ┌────────▼────────────────────────────────────────────────┐
                    │                      DIDRegistry                         │
                    │                                                          │
                    │  mechanism = terms[]  (DNF: OR of AND-term bitmaps)       │
                    │  register(termIndex, inserts[]):                         │
                    │    for each signal s in terms[termIndex]:                │
                    │      key = witnessOf(s, caller)   (read on-chain)        │
                    │      SMT-insert key into signalRoot[s]  (reject dup)     │
                    │    mint one soulbound token                              │
                    └───────────────────────────┬──────────────────────────────┘
                                                │ _mint
                                     ┌──────────▼───────────┐
                                     │   SoulboundToken     │  non-transferable
                                     └──────────────────────┘
```

Signals, depth and mechanism are all set at deploy time (`scripts/deploy-did-registry.sh`,
configurable via `--signals`/`--terms`/`--depth`). Up to `MAX_SIGNALS = 8` signals (so a
term bitmap fits in a `uint8`).

---

## 2. The mechanism (negation-free DNF)

Eligibility is a disjunction (OR) of conjunctive **terms**, each a `uint8` bitmap of
signals that must ALL hold:

```
 terms = [0b1111]              =>  validator AND github AND gmail AND arxiv   (default, all-AND)
 terms = [0b0011, 0b1100]      =>  (validator AND github) OR (gmail AND arxiv)
```

- Pure AND (one term) ⇒ the user must prove every signal.
- With OR (multiple terms) ⇒ the user picks any one term they satisfy.

Views: `requiredBitmap` is gone; instead `terms(i)` / `termCount()` expose the DNF,
`satisfiesTerm(account, i)` and `eligibleTerms(account)` (a bitmap of satisfiable terms)
drive the UI. The owner can swap the whole mechanism with `setMechanism(uint8[])`.

---

## 3. Registration

```
 OFF-CHAIN (did-register-tool / register.html)
 ─────────────────────────────────────────────
   choose a term t the account satisfies (eligibleTerms)
   for each signal s in terms[t]:
     key_s   = witnessOf(s, account)                 # the on-chain witness
     rebuild signal s's SMT from `SignalInserted` events -> root must match signalRoot(s)
     (r'_s, π_s) = tree_s.preview(key_s)              # post-insert root + sibling path
   submit  register(t, [ {newRoot: r'_s, siblings: π_s} ... ])

 ON-CHAIN  register(termIndex, inserts[])
 ──────────────────────────────────────────────────────
   mask = terms[termIndex]
   j = 0
   for s in 0..n-1 where bit s of mask is set:
     key = witnessOf(s, msg.sender) ; require key != 0          # signal held (authoritative)
     _smtInsert(s, key, inserts[j].newRoot, inserts[j].siblings); j++
   require j == inserts.length
   tokenId = _mint(msg.sender)
   emit Registered(msg.sender, termIndex, mask, tokenId)
```

The witness/key is **read on-chain** from the verifier, never supplied by the caller —
so a registration can only insert the genuine witness for `msg.sender`.

---

## 4. Per-signal Sparse Merkle Tree (de-duplication)

Each signal owns a fixed-depth SMT; the contract stores **only the root**
(`signalRoot[s]`). A key's leaf position is the low `TREE_DEPTH` bits of the key, so the
*same witness always lands on the same leaf*. Hashing: internal node =
`keccak256(left,right)`, empty leaf = `0`, stored leaf = `keccak256("DIDRegistry.smt-leaf", key)`.

```
 _smtInsert(s, key, newRoot, siblings):
   leaf = leafHash(key)
   idx  = low TREE_DEPTH bits of key                 # leaf position (LSB-first)
   fold EMPTY leaf (0) along siblings   ==  signalRoot[s]   # (a) proves key ABSENT + π genuine
   fold leaf          along siblings    ==  newRoot         # (b) proves the claimed new root
   signalRoot[s] = newRoot
```

Check (a) is the duplicate guard: if `key` were already registered its leaf would be
non-empty, so folding the empty leaf could not reproduce the current root. By Merkle
collision-resistance the only `siblings` that satisfy (a) is the genuine cofactor, so
`newRoot` is the unique honest insert. Re-submitting any witness already in the tree
reverts `duplicate or stale proof`.

Clients (the JS lib and the frontend) mirror this exactly and rebuild each signal's tree
from `SignalInserted(signal, key, newRoot)` events.

---

## 5. State

| Storage | Meaning |
|---|---|
| `signals[]` | the `n` `{verifier, witnessSelector}` signal sources |
| `signalRoot[]` | per-signal SMT root (the *only* tree state kept on-chain) |
| `terms[]` | DNF mechanism: OR of `uint8` AND-term bitmaps |
| `_zeros` | empty-subtree roots (clients need them to build π) |
| `_ownerOf / _balance / lastId` | the soulbound token (SoulboundToken base) |

De-dup is **per-signal, by witness**: a witness registers into its signal's tree at most
once. Because the key is the underlying witness (validator index, GitHub username, email,
arXiv id) and not the wallet, the same external account can't be registered from two
different wallets.

---

## 6. Soulbound credential (SoulboundToken)

- ERC-721 **read** surface (`ownerOf`, `balanceOf`, `tokenURI`); ERC-165 advertises 721 +
  metadata + EIP-5192.
- **All** transfers/approvals revert; `locked(id) == true` for every token (EIP-5192).
- No `_burn`: a credential is permanent.

---

## 7. Backend (prove-only service)

The register contract verifies and stores **only roots**; it never holds the whole tree.
A small backend (`did-register-tool/backend.js`) backs the frontend and complements this:

- **Proves, doesn't verify.** It keeps the full per-signal Sparse Merkle Tree in memory
  (synced from `SignalInserted` events) and, given an account + a chosen term, returns the
  `(newRoot, siblings)` insert proofs ready for `register(...)`. The contract verifies them.
- **Ledger hashtable.** From `Registered` events it maintains `address -> issued signals`
  (`/registry`) — the credential ledger, reusable downstream (e.g. online voting).

```
 frontend ──/prove?account&term──▶ backend (holds whole trees) ──▶ {inserts}
 frontend ──register(term, inserts)──▶ DIDRegistry (verifies, stores roots) ──▶ SignalInserted
 backend ◀── polls SignalInserted/Registered ── keeps trees + ledger in sync
```

See `did-register-tool/README.md` for the endpoint list.

---

## 8. Trust & uniqueness

The registry reads each verifier **for `msg.sender` only**, so a registration aggregates
witnesses that all belong to the same account. "One witness = one registration" is enforced
by the per-signal SMT here, and the witness's global uniqueness (one validator / GitHub /
Google / arXiv account ↦ one identity) is inherited from each source contract
(`BeaconIdentityVerifier.boundIdentityOf`, Reclaim's `usedNullifier`). Any signal added
later must also expose `identityWitness(address)` returning a stable, unique witness.
