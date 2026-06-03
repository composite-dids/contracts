// Beacon identity proof service
// ------------------------------
// Given a validator index, fetches a recent BeaconState from a beacon node and
// builds the exact SSZ branches BeaconIdentityVerifier.proveValidator() expects:
//
//   beaconTimestamp   -- EL timestamp whose EIP-4788 parent root anchors the proof
//   validatorFields   -- the 8 leaves of the Validator container
//   validatorProof    -- branch: validatorRoot   -> beaconStateRoot   (len 40+1+depth)
//   beaconStateRoot   -- claimed state root (verified by the branch below it)
//   stateRootProof    -- branch: beaconStateRoot  -> beaconBlockRoot   (len 3)
//
// Proof anchoring (EIP-4788):
//   We prove the validator against a target beacon block TB (root R, slot S).
//   EIP-4788's beacon-roots contract is keyed by an *execution* block timestamp and
//   returns that EL block's parent_beacon_block_root. So we find the next beacon
//   block CB after TB; CB's execution payload has parent_beacon_block_root == R and a
//   timestamp t. That t is `beaconTimestamp`, and on-chain beacon_roots(t) == R.
//
// Only a beacon node is required (no execution node) -- the EL timestamp comes from
// CB's execution payload.

import express from "express";
import { Tree } from "@chainsafe/persistent-merkle-tree";
import { createChainForkConfig } from "@lodestar/config";
import { networksChainConfig } from "@lodestar/config/networks";
import { ssz } from "@lodestar/types";

const PORT = Number(process.env.PORT || 8080);
const BEACON_URL = (process.env.BEACON_URL || "http://localhost:5052").replace(/\/$/, "");
const NETWORK = process.env.NETWORK || "sepolia";
// How many slots behind head to anchor, to stay clear of reorgs.
const SLOT_LAG = Number(process.env.SLOT_LAG || 4);

const chainConfig = networksChainConfig[NETWORK];
if (!chainConfig) {
  throw new Error(`Unknown NETWORK '${NETWORK}'. Known: ${Object.keys(networksChainConfig).join(", ")}`);
}
const config = createChainForkConfig(chainConfig);

const FAR_FUTURE_PREFIX = "0xffffffffffffffff"; // uint64 max, little-endian, first 8 bytes

// ---- small helpers ----
const toHex = (u8) => "0x" + Buffer.from(u8).toString("hex");
const fromHex = (h) => Uint8Array.from(Buffer.from(String(h).replace(/^0x/, ""), "hex"));

async function beaconGet(path, { ssz: wantSsz = false } = {}) {
  const res = await fetch(`${BEACON_URL}${path}`, {
    headers: { accept: wantSsz ? "application/octet-stream" : "application/json" },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    const err = new Error(`beacon ${path} -> ${res.status} ${body.slice(0, 200)}`);
    err.status = res.status;
    throw err;
  }
  return wantSsz ? new Uint8Array(await res.arrayBuffer()) : res.json();
}

// Find the most recent beacon block at or before `slot` (skips empty slots).
async function findBlockHeaderAtOrBefore(slot) {
  for (let s = slot; s > slot - 32 && s >= 0; s--) {
    try {
      const h = await beaconGet(`/eth/v1/beacon/headers/${s}`);
      return h.data; // { root, header: { message: {...} } }
    } catch (e) {
      if (e.status === 404) continue;
      throw e;
    }
  }
  throw new Error(`no block found near slot ${slot}`);
}

async function buildProof(validatorIndex) {
  // 1. Pick a child block CB a few slots behind head (anchors EIP-4788).
  const head = (await beaconGet(`/eth/v1/beacon/headers/head`)).data;
  const headSlot = Number(head.header.message.slot);
  const cbHeader = await findBlockHeaderAtOrBefore(headSlot - SLOT_LAG);
  const cbRoot = cbHeader.root;

  // 2. Full CB block -> EL timestamp + the parent beacon root R (== target block TB).
  const cbBlock = (await beaconGet(`/eth/v2/beacon/blocks/${cbRoot}`)).data;
  const R = cbBlock.message.parent_root;
  const beaconTimestamp = Number(cbBlock.message.body.execution_payload.timestamp);

  // 3. Target block header (gives us the 5 header fields and confirms root == R).
  const tbHeaderResp = (await beaconGet(`/eth/v1/beacon/headers/${R}`)).data;
  const tbMsg = tbHeaderResp.header.message;
  const tbSlot = Number(tbMsg.slot);
  const tbStateRoot = tbMsg.state_root;

  // 4. Download the target BeaconState (SSZ) and deserialize as the right fork type.
  const BeaconState = config.getForkTypes(tbSlot).BeaconState;
  const stateBytes = await beaconGet(`/eth/v2/debug/beacon/states/${tbStateRoot}`, { ssz: true });
  const state = BeaconState.deserializeToViewDU(stateBytes);

  if (validatorIndex >= state.validators.length) {
    const e = new Error(`validator index ${validatorIndex} out of range (have ${state.validators.length})`);
    e.status = 400;
    throw e;
  }

  const beaconStateRoot = toHex(state.hashTreeRoot());
  if (beaconStateRoot.toLowerCase() !== tbStateRoot.toLowerCase()) {
    throw new Error(`state root mismatch: computed ${beaconStateRoot} vs header ${tbStateRoot}`);
  }

  // 5. Validator fields (the 8 container leaves) and validatorRoot.
  const validator = state.validators.get(validatorIndex).toValue();
  const VF = ssz.phase0.Validator.fields;
  const fieldOrder = [
    "pubkey",
    "withdrawalCredentials",
    "effectiveBalance",
    "slashed",
    "activationEligibilityEpoch",
    "activationEpoch",
    "exitEpoch",
    "withdrawableEpoch",
  ];
  const validatorFields = fieldOrder.map((name) => toHex(VF[name].hashTreeRoot(validator[name])));

  // 6. Branch: validatorRoot -> beaconStateRoot.
  const stateTree = new Tree(state.node);
  const valGindex = BeaconState.getPathInfo(["validators", validatorIndex]).gindex;
  const validatorProof = stateTree.getSingleProof(valGindex).map(toHex);
  // len = VALIDATOR_LIST_DEPTH(40) + 1 (length mixin) + BEACON_STATE_TREE_DEPTH
  const beaconStateTreeDepth = validatorProof.length - 41;

  // 7. Branch: beaconStateRoot -> beaconBlockRoot, from the target block header.
  const header = {
    slot: tbSlot,
    proposerIndex: Number(tbMsg.proposer_index),
    parentRoot: fromHex(tbMsg.parent_root),
    stateRoot: fromHex(tbMsg.state_root),
    bodyRoot: fromHex(tbMsg.body_root),
  };
  const headerTree = new Tree(ssz.phase0.BeaconBlockHeader.toView(header).node);
  const srGindex = ssz.phase0.BeaconBlockHeader.getPathInfo(["stateRoot"]).gindex;
  const stateRootProof = headerTree.getSingleProof(srGindex).map(toHex);
  const computedBlockRoot = toHex(ssz.phase0.BeaconBlockHeader.hashTreeRoot(header));
  if (computedBlockRoot.toLowerCase() !== R.toLowerCase()) {
    throw new Error(`block root mismatch: computed ${computedBlockRoot} vs R ${R}`);
  }

  // 8. Decode the convenience fields the frontend uses to gate the UX.
  const credsHex = validatorFields[1];
  const credsType = parseInt(credsHex.slice(2, 4), 16);
  const withdrawalAddress = "0x" + credsHex.slice(-40);
  const exited = !validatorFields[6].toLowerCase().startsWith(FAR_FUTURE_PREFIX);

  return {
    network: NETWORK,
    validatorIndex,
    targetSlot: tbSlot,
    beaconBlockRoot: R,
    beaconTimestamp,
    beaconStateTreeDepth, // deploy the contract with this value
    // ---- contract call args ----
    beaconStateRoot,
    validatorFields,
    validatorProof,
    stateRootProof,
    // ---- convenience / UX gating ----
    withdrawalAddress,
    credsType,
    effectiveBalanceGwei: Number(validator.effectiveBalance),
    exited,
  };
}

const app = express();
app.use((req, res, next) => {
  res.set("access-control-allow-origin", "*");
  res.set("access-control-allow-headers", "*");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/health", (_req, res) => res.json({ ok: true, network: NETWORK, beacon: BEACON_URL }));

app.get("/proof/:validatorIndex", async (req, res) => {
  const idx = Number(req.params.validatorIndex);
  if (!Number.isInteger(idx) || idx < 0) {
    return res.status(400).json({ error: "validatorIndex must be a non-negative integer" });
  }
  try {
    const out = await buildProof(idx);
    res.json(out);
  } catch (e) {
    console.error(e);
    res.status(e.status || 502).json({ error: String(e.message || e) });
  }
});

app.listen(PORT, () => {
  console.log(`proof-service on :${PORT}  network=${NETWORK}  beacon=${BEACON_URL}`);
});
