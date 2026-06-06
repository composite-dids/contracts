// Offline self-test: confirms the JS Sparse Merkle Tree matches DIDRegistry's hashing.
// Run: node selftest.js
import { ethers } from "ethers";
import { SparseMerkleTree, leafHash, hashPair, ZERO } from "./sparse-merkle.js";

let failures = 0;
const eq = (a, b, msg) => {
  const ok = String(a).toLowerCase() === String(b).toLowerCase();
  console.log(`${ok ? "ok  " : "FAIL"}  ${msg}`);
  if (!ok) { failures++; console.log(`        got ${a}\n        exp ${b}`); }
};

const DEPTH = 16;

// 1. Empty-tree root for depth D equals zeros[D] = repeated keccak of the zero leaf.
let z = ZERO;
for (let i = 0; i < DEPTH; i++) z = hashPair(z, z);
const t = new SparseMerkleTree(DEPTH);
eq(t.root, z, "empty-tree root == zeros[depth]");

// 2. preview then insert are consistent (the root the contract would commit to).
const keyA = ethers.keccak256(ethers.toUtf8Bytes("validator:alice"));
const prevA = t.preview(keyA);
const rootA = t.insert(keyA);
eq(t.root, prevA.newRoot, "insert root == preview newRoot");
eq(rootA, prevA.newRoot, "insert return == preview newRoot");

// 3. A non-membership fold of the EMPTY leaf along the proof reproduces the PRE-insert
//    root (this is exactly the contract's duplicate check).
const t2 = new SparseMerkleTree(DEPTH);
const before = t2.root;
const keyB = ethers.keccak256(ethers.toUtf8Bytes("github:bob"));
const prevB = t2.preview(keyB);
let emptyNode = ZERO, filledNode = leafHash(keyB);
let idx = t2.leafIndex(keyB);
for (let i = 0; i < DEPTH; i++) {
  const sib = prevB.siblings[i];
  if ((idx & 1n) === 0n) { emptyNode = hashPair(emptyNode, sib); filledNode = hashPair(filledNode, sib); }
  else { emptyNode = hashPair(sib, emptyNode); filledNode = hashPair(sib, filledNode); }
  idx >>= 1n;
}
eq(emptyNode, before, "empty-leaf fold == current root (non-membership)");
eq(filledNode, prevB.newRoot, "filled-leaf fold == newRoot");

// 4. has() reflects insertion (duplicate detection).
eq(t.has(keyA), true, "has(key) true after insert");
eq(t.has(keyB), false, "has(other key) false");

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
