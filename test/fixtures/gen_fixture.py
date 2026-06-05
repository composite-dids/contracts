#!/usr/bin/env python3
"""Generate a real (header + eth_getProof) fixture for HistoricalBalanceVerifier tests.

Reconstructs the canonical block-header RLP from eth_getBlockByNumber (Prague field
order) so keccak256(headerRLP) == block hash, and pulls an MPT account proof from
eth_getProof. Writes JSON the Forge test consumes. Verify with `cast keccak`.
"""
import json, sys, urllib.request

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://ethereum-rpc.publicnode.com"
ADDR = sys.argv[2] if len(sys.argv) > 2 else "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
AGE = int(sys.argv[3]) if len(sys.argv) > 3 else 100

def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json", "user-agent": "curl/8.9.1"},
    )
    r = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]

def enc_len(l, off):
    if l < 56:
        return bytes([off + l])
    lb = l.to_bytes((l.bit_length() + 7) // 8, "big")
    return bytes([off + 55 + len(lb)]) + lb

def rlp(item):
    if isinstance(item, list):
        out = b"".join(rlp(x) for x in item)
        return enc_len(len(out), 0xC0) + out
    if len(item) == 1 and item[0] < 0x80:
        return item
    return enc_len(len(item), 0x80) + item

def data(h):      # exact bytes, keep leading zeros (hashes/addresses/blobs)
    return bytes.fromhex(h[2:])

def qty(h):       # quantity: minimal big-endian, 0 -> empty
    n = int(h, 16)
    return b"" if n == 0 else n.to_bytes((n.bit_length() + 7) // 8, "big")

# Canonical header field order. (key, encoder, required)
SPEC = [
    ("parentHash", data, True), ("sha3Uncles", data, True), ("miner", data, True),
    ("stateRoot", data, True), ("transactionsRoot", data, True), ("receiptsRoot", data, True),
    ("logsBloom", data, True), ("difficulty", qty, True), ("number", qty, True),
    ("gasLimit", qty, True), ("gasUsed", qty, True), ("timestamp", qty, True),
    ("extraData", data, True), ("mixHash", data, True), ("nonce", data, True),
    ("baseFeePerGas", qty, False), ("withdrawalsRoot", data, False),
    ("blobGasUsed", qty, False), ("excessBlobGas", qty, False),
    ("parentBeaconBlockRoot", data, False), ("requestsHash", data, False),
]

def header_rlp(blk):
    fields = []
    for key, enc, _ in SPEC:
        if key in blk and blk[key] is not None:
            fields.append(enc(blk[key]))
    return rlp(fields)

head = int(rpc("eth_blockNumber", []), 16)
fork_block = head - 1                # forge forks here; blockhash(target) is then in range
target = fork_block - AGE            # age == AGE
hexb = hex(target)

blk = rpc("eth_getBlockByNumber", [hexb, False])
hdr = header_rlp(blk)
pf = rpc("eth_getProof", [ADDR, [], hexb])

# A block >256 behind the fork block, to exercise the EIP-2935 (Pectra) path on-chain.
deep_block = fork_block - 300
deep = rpc("eth_getBlockByNumber", [hex(deep_block), False])

fixture = {
    "rpc": RPC,
    "address": ADDR,
    "targetBlock": target,
    "forkBlock": fork_block,
    "age": AGE,
    "blockHash": blk["hash"],
    "stateRoot": blk["stateRoot"],
    "headerRLP": "0x" + hdr.hex(),
    "accountProof": pf["accountProof"],
    "balanceWei": str(int(pf["balance"], 16)),
    "nonce": int(pf["nonce"], 16),
    "deepBlock": deep_block,
    "deepBlockHash": deep["hash"],
}

out = sys.argv[4] if len(sys.argv) > 4 else "test/fixtures/balance_mainnet.json"
with open(out, "w") as f:
    json.dump(fixture, f, indent=2)

print(f"wrote {out}")
print(f"  target block : {target}  (fork at {fork_block}, age {AGE})")
print(f"  block hash   : {blk['hash']}")
print(f"  proof nodes  : {len(pf['accountProof'])}")
print(f"  balance      : {fixture['balanceWei']} wei")
print(f"  headerRLP len: {len(hdr)} bytes")
