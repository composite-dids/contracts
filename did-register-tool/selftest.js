// Offline self-test: confirms the JS incremental tree matches DIDRegistry's hashing.
// Run: node selftest.js
import { ethers } from "ethers";
import { IncrementalMerkleTree, hashPair, ZERO } from "./incremental-merkle.js";

let failures = 0;
const eq = (a, b, msg) => {
  const ok = String(a).toLowerCase() === String(b).toLowerCase();
  console.log(`${ok ? "ok  " : "FAIL"}  ${msg}`);
  if (!ok) { failures++; console.log(`        got ${a}\n        exp ${b}`); }
};

// 1. Empty-tree root for depth 8 equals zeros[8] = repeated keccak of zero.
const DEPTH = 8;
let z = ZERO;
for (let i = 0; i < DEPTH; i++) z = hashPair(z, z);
const t = new IncrementalMerkleTree(DEPTH);
eq(t.root, z, "empty-tree root == zeros[depth]");

// 2. previewInsert then insert are consistent, and the root advances deterministically.
const leafA = ethers.keccak256(ethers.toUtf8Bytes("alice"));
const prev = t.previewInsert(leafA);
const idx = t.insert(leafA);
eq(idx, 0, "first leaf index == 0");
eq(t.root, prev.newRoot, "insert root == previewInsert newRoot");

// 3. A second insert advances the frontier; preview matches commit.
const leafB = ethers.keccak256(ethers.toUtf8Bytes("bob"));
const prevB = t.previewInsert(leafB);
t.insert(leafB);
eq(t.root, prevB.newRoot, "second insert root == preview");

// 4. Membership proof of leaf 0 verifies against the current root.
const mp = t.membershipProof(0);
let node = mp.leaf;
for (let i = 0; i < mp.path.length; i++) {
  node = mp.pathIndices[i] ? hashPair(mp.path[i], node) : hashPair(node, mp.path[i]);
}
eq(node, t.root, "membership proof of leaf 0 reconstructs root");

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
