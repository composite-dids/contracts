# contracts

On-chain verification of various types of identity.

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

## 2. zkTLS identity

`reclaimprotocolverifier.sol` — Reclaim Protocol zkTLS proof. (To be wired up next.)
