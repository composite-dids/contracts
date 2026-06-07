# contracts

On-chain verification of various types of identity.

## Composite DID registration (live on Sepolia)

`DIDRegistry` mints one **soulbound** credential when your wallet satisfies a configurable
boolean **mechanism** (negation-free DNF) over the identity signals — in a **single
transaction**. `register(termIndex, proofs[])`:

1. verifies each signal's proof via that signal's `verifyAndGetWitness(claimant, proofData)`
   (reverts on an invalid proof or one not bound to the caller),
2. **de-duplicates** against an on-chain hashtable — reusing an identity already registered
   for a signal (same GitHub handle, paper title, email, address) reverts
   (`"signal identity already used"`),
3. records the readable identity and mints the credential — all atomic.

No off-chain proof service: the **balance proof is generated in the browser**
(`eth_getProof` + header-RLP/keccak), the Reclaim proofs come from the Reclaim SDK.

Deployed on Sepolia (mechanism = `balance AND github AND google AND arxiv`):

| | address |
|---|---|
| **DIDRegistry** | `0x4c1E944F9775DF54DeE0D9f084301dAB83812208` |
| signal0 balance — HistoricalBalanceVerifier | `0x3928Ec21D7Ea56E06d46852ff826fc0b960Dfd67` |
| signal1 github  — GithubIdentity | `0xD0C38555d4856F5e2E527C05BB37144C7b1F67a0` |
| signal2 google  — GoogleIdentity | `0x94DBC69099741feC95A9B0EF24daAd469761f962` |
| signal3 arxiv   — ArxivIdentity  | `0x7508005264343121D1b748Eef7DA313e74e0560a` |

Each signal implements `ISignalVerifier.verifyAndGetWitness(address,bytes) → string`.
Deploy with `scripts/deploy.sh` (the 4 signals) + `scripts/deploy-did-registry.sh` (registry).

**Frontend:** `frontend/index.html` is a 3-step flow — **Home** (connect; registry from
`config.json`) → **Choose signals** (shows the AND/OR mechanism; tells you if your selection
is enough) → **Prove & register** (generate each proof locally, then one tx; success shows a
QR + Etherscan link). Serve `frontend/` over http and open it.

> Legacy/stale (predate this rewrite, not wired to the new flow): `frontend/balance.html`,
> `frontend/reclaim.html` (standalone single-signal testers, old addresses), and the merged
> `frontend/register.html`, `did-register-tool/`, `scripts/demo-local.sh` (SMT-era). Safe to
> remove — superseded by the 3-step `index.html`.

## Deploying (Sepolia)

`scripts/deploy.sh` deploys the whole suite in one run — `HistoricalBalanceVerifier`,
`GithubIdentity`, and `GoogleIdentity` — with sanity checks and Etherscan links (RPC +
deployer key are baked in; the Reclaim verifier address is the Sepolia deployment):

```bash
scripts/deploy.sh                # defaults: MIN_AGE=100 blocks, MIN_BALANCE=0.1 ETH
scripts/deploy.sh 256 1          # MIN_AGE=256, MIN_BALANCE=1 ETH
```

Migrating networks = change `RPC_URL` + `RECLAIM_VERIFIER` at the top of the script.

## 1. Proof of caller's historical balance

Prove on-chain that **the caller** held at least **0.1 ETH** ~100 blocks ago — no
oracle, no trusted party. The EVM can't read historical balances directly, but it can
verify them: the block hash of a past block (via the `BLOCKHASH` opcode for the last
256, or the EIP-2935 history contract for the last 8191) commits to the header →
`stateRoot`, and a Merkle-Patricia proof of `keccak256(msg.sender)` against that root
yields `[nonce, balance, storageRoot, codeHash]`.

- **`HistoricalBalanceVerifier.sol`** — verifies that chain end-to-end (block header
  RLP + MPT account proof). Includes a self-contained RLP reader and MPT inclusion
  verifier. `proveSelfBalance(...)` binds the proof to `msg.sender`, requires the
  balance ≥ `MIN_BALANCE_WEI`, sets `isEligible[msg.sender]`, and emits
  `EligibilityProven` — the tx signature alone authenticates control of the address.
  `verifyBalanceAt(...)` remains a gas-free view returning any address's past balance.
  Constructor: `(minAge, minBalanceWei)` — e.g. `(100, 0.1 ether)`. Block hashes come
  from the `BLOCKHASH` opcode (last 256) with an EIP-2935 fallback (last 8191), so
  `MAX_AGE = 8191`.
- **`balance-proof-service/`** — Node service that calls `eth_getBlockByNumber` +
  `eth_getProof` and rebuilds the fork-exact header RLP. See
  [balance-proof-service/README.md](balance-proof-service/README.md).
- **`frontend/balance.html`** — zero-build UI: connect wallet, generate the proof for
  your own address, then **Verify** (read-only `eth_call`) or **Prove eligibility** (tx).

### Tests

Foundry tests cover `HistoricalBalanceVerifier` against a **real mainnet block +
`eth_getProof`** fixture (`test/fixtures/`, regenerate with `gen_fixture.py`):

```bash
forge test            # 11 passing: RLP/MPT/header decode offline + full fork path
```

The offline tests validate the hand-written RLP reader, MPT verifier, header parser,
and balance decode against real data; the `testFork_*` tests run the full path
(including the on-chain block-hash link) on a forked chain, confirm both block-hash
sources (BLOCKHASH opcode for recent blocks, EIP-2935 for blocks >256 back), and assert
that a tampered header, a below-threshold balance, and a wrong caller (`msg.sender` ≠
proven address) all revert.

> ⚠ The Solidity RLP/MPT code is hand-written. The account-proof path is exercised by
> the tests above, but it has **not had a formal audit** — review before trusting it
> with real value.

## 2. zkTLS identity (Reclaim)

Prove you control an off-chain account (GitHub, Google) via a **Reclaim zkTLS** proof,
verified on-chain and bound to your wallet. The Reclaim verifier is already deployed on
Sepolia (`0xAe94FB09711e1c6B057853a515483792d8e474d0`), so nothing extra to deploy there.

- **`ReclaimIdentity.sol`** — base: minimal Reclaim interface + structs (no SDK import —
  the SDK pins solc 0.8.4), `submitProof` calls the deployed verifier (attestor-signature
  trust anchor), then adds **provider binding** (optional `providerHash`), **user binding**
  (`contextAddress == msg.sender`, stops front-running), and a **sybil nullifier**. Stores
  `isVerified` + the extracted `handleOf`.
- **`GithubIdentity.sol`** / **`GoogleIdentity.sol`** / **`ArxivIdentity.sol`** — thin
  subclasses fixing the extracted field. `ArxivIdentity` additionally proves **≥ 1
  paper**: the provider scrapes your login-gated "articles owned" page and captures a
  paper id (so no proof exists for a 0-paper account), and the contract requires that
  capture to be non-empty (or, with `minPapers > 1`, parses a numeric `paperCount`).
  Deployed on Sepolia:
  - GitHub  `0x842D4e4B5A531cA42eCF601ced9e606405888704`
  - Google  `0x974f84EF3b064c60b4D138043A92685B37BCFD66`
  - arXiv   `0x4352F52ea5cA41768d16aa5aF7b1D5ad3fA53Ef4` (≥ 1 paper; field `first_paper_title`)
- **`frontend/reclaim.html`** — zero-build UI using `@reclaimprotocol/js-sdk` (via CDN):
  connect wallet → pick GitHub/Google → run the Reclaim flow (QR/link) with the wallet set
  as the context address → submit the proof on-chain. Set `APP_SECRET` in the file first
  (client-side, testnet only).

Trust model: Reclaim's witness/attestor network signs the claim; `verifyProof` checks
those signatures (it does **not** verify a zk proof on-chain). You don't run a TEE —
Reclaim operates the attestor infra (proxy-witness by default, TEE-backed available).
