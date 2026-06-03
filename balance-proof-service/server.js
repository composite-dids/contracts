// Historical balance proof service
// ---------------------------------
// Given an address, picks a block ~BLOCKS_AGO behind head and returns everything
// HistoricalBalanceVerifier.verifyBalanceAt() needs:
//
//   targetBlock    -- the block number proven against
//   headerRLP      -- canonical RLP of that block's header (keccak == blockhash)
//   accountProof   -- MPT nodes from eth_getProof, root-first
//
// The header RLP is rebuilt by hand from eth_getBlockByNumber so it is byte-exact
// across forks (London/Shanghai/Cancun/Prague header fields differ). We then assert
// keccak256(headerRLP) == the node's reported block hash before returning -- the same
// check the contract performs on-chain against blockhash().

import express from "express";
import { keccak_256 } from "@noble/hashes/sha3";

const PORT = Number(process.env.PORT || 8081);
const RPC_URL = process.env.RPC_URL || "http://localhost:8545";
const NETWORK = process.env.NETWORK || "sepolia";
const BLOCKS_AGO = Number(process.env.BLOCKS_AGO || 100);

// ---- hex / bytes helpers ----
const hexToBytes = (h) => Uint8Array.from(Buffer.from(String(h).replace(/^0x/, ""), "hex"));
const bytesToHex = (b) => "0x" + Buffer.from(b).toString("hex");
const concat = (arrs) => {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
};

// ---- minimal RLP encoder ----
function encodeLength(len, offset) {
  if (len < 56) return Uint8Array.of(offset + len);
  let n = BigInt(len), tmp = [];
  while (n > 0n) { tmp.unshift(Number(n & 0xffn)); n >>= 8n; }
  return concat([Uint8Array.of(offset + 55 + tmp.length), Uint8Array.from(tmp)]);
}
function rlpEncode(item) {
  if (Array.isArray(item)) {
    const out = concat(item.map(rlpEncode));
    return concat([encodeLength(out.length, 0xc0), out]);
  }
  if (item.length === 1 && item[0] < 0x80) return item;
  return concat([encodeLength(item.length, 0x80), item]);
}

// Field encoders: `data` keeps exact bytes (hashes/addresses/blobs);
// `qty` is a minimal big-endian quantity (0 -> empty string).
const data = (h) => hexToBytes(h);
const qty = (h) => {
  let n = BigInt(h);
  if (n === 0n) return new Uint8Array(0);
  let tmp = [];
  while (n > 0n) { tmp.unshift(Number(n & 0xffn)); n >>= 8n; }
  return Uint8Array.from(tmp);
};

// Canonical header field order. Optional fields are included only if present,
// so the same code serializes Merge/London/Shanghai/Cancun/Prague headers.
const HEADER_SPEC = [
  ["parentHash", data], ["sha3Uncles", data], ["miner", data],
  ["stateRoot", data], ["transactionsRoot", data], ["receiptsRoot", data],
  ["logsBloom", data], ["difficulty", qty], ["number", qty],
  ["gasLimit", qty], ["gasUsed", qty], ["timestamp", qty],
  ["extraData", data], ["mixHash", data], ["nonce", data],
  ["baseFeePerGas", qty], ["withdrawalsRoot", data],
  ["blobGasUsed", qty], ["excessBlobGas", qty],
  ["parentBeaconBlockRoot", data], ["requestsHash", data],
];

function headerRLP(block) {
  const fields = [];
  for (const [key, enc] of HEADER_SPEC) {
    if (block[key] !== undefined && block[key] !== null) fields.push(enc(block[key]));
  }
  return rlpEncode(fields);
}

const toHex = (n) => "0x" + BigInt(n).toString(16);

let rpcId = 0;
async function rpc(method, params) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

async function buildProof(address) {
  const head = parseInt(await rpc("eth_blockNumber", []), 16);
  const targetBlock = head - BLOCKS_AGO;
  if (targetBlock < 0) throw new Error("chain too short");
  const hexBlock = toHex(targetBlock);

  // 1. Block header -> exact RLP, verified against the node's block hash.
  const block = await rpc("eth_getBlockByNumber", [hexBlock, false]);
  const rlp = headerRLP(block);
  const computedHash = bytesToHex(keccak_256(rlp));
  if (computedHash.toLowerCase() !== block.hash.toLowerCase()) {
    throw new Error(`header hash mismatch: rebuilt ${computedHash} vs node ${block.hash}`);
  }

  // 2. Account proof against that block's state root.
  const pf = await rpc("eth_getProof", [address, [], hexBlock]);

  return {
    network: NETWORK,
    address,
    currentBlock: head,
    targetBlock,
    age: BLOCKS_AGO,
    stateRoot: block.stateRoot,
    // ---- contract call args ----
    headerRLP: bytesToHex(rlp),
    accountProof: pf.accountProof,
    // ---- convenience ----
    reportedBalanceWei: BigInt(pf.balance).toString(),
    reportedNonce: parseInt(pf.nonce, 16),
  };
}

const app = express();
app.use((req, res, next) => {
  res.set("access-control-allow-origin", "*");
  res.set("access-control-allow-headers", "*");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/health", (_req, res) => res.json({ ok: true, network: NETWORK, rpc: RPC_URL, blocksAgo: BLOCKS_AGO }));

app.get("/balance-proof/:address", async (req, res) => {
  const address = req.params.address;
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
    return res.status(400).json({ error: "invalid address" });
  }
  try {
    res.json(await buildProof(address));
  } catch (e) {
    console.error(e);
    res.status(502).json({ error: String(e.message || e) });
  }
});

app.listen(PORT, () => {
  console.log(`balance-proof-service on :${PORT}  network=${NETWORK}  rpc=${RPC_URL}  blocksAgo=${BLOCKS_AGO}`);
});
