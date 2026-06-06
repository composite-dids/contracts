# contracts

On-chain verification of various types of identity.

## Registration (local only for now!)
Just run 
```
scripts/demo-local.sh
```
Follow the instruction locally, can use any signals provided in the following.

## Deploying (Sepolia)

`scripts/deploy.sh` deploys the whole suite in one run — `HistoricalBalanceVerifier`,
`GithubIdentity`, and `GoogleIdentity` — with sanity checks and Etherscan links (RPC +
deployer key are baked in; the Reclaim verifier address is the Sepolia deployment):

```bash
scripts/deploy.sh                # defaults: MIN_AGE=100 blocks, MIN_BALANCE=0.1 ETH
scripts/deploy.sh 256 1          # MIN_AGE=256, MIN_BALANCE=1 ETH
```

Migrating networks = change `RPC_URL` + `RECLAIM_VERIFIER` at the top of the script.

## 1. Proof of validator identity

Prove that you control an Ethereum validator's **withdrawal address**, verified
on-chain against the beacon-chain validator set via EIP-4788.

- **`beaconverify.sol`** — `BeaconStakeVerifier`: low-level SSZ proof that a
  validator exists in a recent beacon state and recovers its withdrawal address +
  effective balance. Fork depth is a constructor parameter (Deneb = 5, Electra = 6).
- **`BeaconIdentityVerifier.sol`** — binds that proof to a caller-controlled address
  so it actually proves *identity*, two ways:
  - `verifyAndBind(…)` — requires `msg.sender == withdrawalAddr` (simplest).
  - `verifyWithSignature(…, nonce, sig)` — the withdrawal address signs a
    domain-separated message; anyone (e.g. a relayer) may submit it.

  It stores only a boolean signal (`isVerified`) plus the effective balance, and
  enforces one-validator-one-identity (`boundIdentityOf`).
- **`proof-service/`** — Node service that builds the SSZ proofs from a beacon node.
  See [proof-service/README.md](proof-service/README.md).
- **`frontend/index.html`** — zero-build UI (ethers via CDN): connect wallet, enter
  a validator index, fetch a proof, and submit either path. Just open the file (or
  serve it) — set the proof-service URL and the deployed contract address.

### End-to-end (Sepolia by default)

1. Deploy `BeaconIdentityVerifier` **on Sepolia** with the state-tree depth for the
   live fork (**6** for Electra — Sepolia and mainnet are both on Electra). The
   proof service reports the right value.
2. Run the proof service against your **Sepolia** beacon node (`NETWORK=sepolia`,
   the default).
3. Open the frontend, connect the wallet that owns the validator's withdrawal
   address (it will prompt to switch to Sepolia), enter the validator index,
   generate the proof, and verify.

**Migrating networks** is deliberately a one-line change in each piece:
- proof service: `NETWORK=mainnet` (+ a mainnet `BEACON_URL`).
- frontend: change `ACTIVE` in `index.html` (or load `index.html?net=mainnet`).
- contract: redeploy on the target chain. The EIP-4788 beacon-roots address is
  identical on every chain, and the state-tree depth (6) is the same on Sepolia and
  mainnet today, so no Solidity changes are needed.

### Why the binding matters

`proveValidator` alone proves "validator N exists and its withdrawal address is X" —
anyone can submit anyone's proof. Binding to `msg.sender`/signature proves the
submitter *controls* X, turning a public fact into an identity claim.

## 2. Proof of caller's historical balance

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

## 3. zkTLS identity (Reclaim)

Prove you control an off-chain account (GitHub, Google) via a **Reclaim zkTLS** proof,
verified on-chain and bound to your wallet. The Reclaim verifier is already deployed on
Sepolia (`0xAe94FB09711e1c6B057853a515483792d8e474d0`), so nothing extra to deploy there.

- **`ReclaimIdentity.sol`** — base: minimal Reclaim interface + structs (no SDK import —
  the SDK pins solc 0.8.4), `submitProof` calls the deployed verifier (attestor-signature
  trust anchor), then adds **provider binding** (optional `providerHash`), **user binding**
  (`contextAddress == msg.sender`, stops front-running), and a **sybil nullifier**. Stores
  `isVerified` + the extracted `handleOf`.
- **`GithubIdentity.sol`** / **`GoogleIdentity.sol`** — thin subclasses fixing the
  extracted field (`username` / `email`). Deployed on Sepolia:
  - GitHub  `0x842D4e4B5A531cA42eCF601ced9e606405888704`
  - Google  `0x974f84EF3b064c60b4D138043A92685B37BCFD66`
- **`frontend/reclaim.html`** — zero-build UI using `@reclaimprotocol/js-sdk` (via CDN):
  connect wallet → pick GitHub/Google → run the Reclaim flow (QR/link) with the wallet set
  as the context address → submit the proof on-chain. Set `APP_SECRET` in the file first
  (client-side, testnet only).

Trust model: Reclaim's witness/attestor network signs the claim; `verifyProof` checks
those signatures (it does **not** verify a zk proof on-chain). You don't run a TEE —
Reclaim operates the attestor infra (proxy-witness by default, TEE-backed available).
