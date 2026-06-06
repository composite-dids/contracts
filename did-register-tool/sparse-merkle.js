// Sparse Merkle Tree — the off-chain mirror of DIDRegistry's per-signal accumulator.
// -----------------------------------------------------------------------------
// One tree per signal, keyed by the signal's witness (bytes32). The leaf position is
// the low `depth` bits of the key; empty leaves are 0x00..0; internal nodes are
// keccak256(abi.encodePacked(left, right)). The stored leaf value for a key is
// keccak256(abi.encodePacked("DIDRegistry.smt-leaf", key)).
//
// Hashing MUST match DIDRegistry._hashPair / leafHash / _smtInsert exactly. Used to
// produce the (newRoot, siblings) insert proof DIDRegistry.register expects, and to
// rebuild a signal's tree from on-chain SignalInserted events.
import { ethers } from "ethers";

const ZERO = "0x" + "00".repeat(32);
const hashPair = (a, b) => ethers.keccak256(ethers.concat([a, b]));

/** The leaf value a witness key occupies. Domain-tagged (matches contract leafHash). */
export function leafHash(key) {
  return ethers.keccak256(
    ethers.concat([ethers.toUtf8Bytes("DIDRegistry.smt-leaf"), key])
  );
}

export class SparseMerkleTree {
  /** @param {number} depth tree depth (capacity 2**depth leaves). */
  constructor(depth) {
    if (!Number.isInteger(depth) || depth < 1 || depth > 160) {
      throw new Error("depth must be an integer in [1, 160]");
    }
    this.depth = depth;
    // zeros[i] = root of an empty subtree of height i.
    this.zeros = [ZERO];
    for (let i = 0; i < depth; i++) this.zeros.push(hashPair(this.zeros[i], this.zeros[i]));
    // Sparse node store: nodes[level] is a Map<indexString, hash>. Absent => zeros[level].
    this.nodes = Array.from({ length: depth + 1 }, () => new Map());
  }

  /** Leaf index (path) for a key: low `depth` bits of the key, as a BigInt. */
  leafIndex(key) {
    const mask = (1n << BigInt(this.depth)) - 1n;
    return BigInt(key) & mask;
  }

  _node(level, index) {
    const m = this.nodes[level];
    const k = index.toString();
    return m.has(k) ? m.get(k) : this.zeros[level];
  }

  _set(level, index, val) {
    this.nodes[level].set(index.toString(), val);
  }

  get root() {
    return this._node(this.depth, 0n);
  }

  /**
   * Compute (newRoot, siblings) for filling key's leaf WITHOUT mutating the tree.
   * These are exactly the per-signal `Insert` args for DIDRegistry.register.
   * @param {string} key 0x-prefixed bytes32 witness
   * @returns {{ newRoot: string, siblings: string[], leafIndex: string }}
   */
  preview(key) {
    let nodeIndex = this.leafIndex(key);
    let cur = leafHash(key);
    const siblings = [];
    for (let i = 0; i < this.depth; i++) {
      const sib = this._node(i, nodeIndex ^ 1n);
      siblings.push(sib);
      cur = (nodeIndex & 1n) === 0n ? hashPair(cur, sib) : hashPair(sib, cur);
      nodeIndex >>= 1n;
    }
    return { newRoot: cur, siblings, leafIndex: this.leafIndex(key).toString() };
  }

  /** Insert key's leaf, mutating the tree. Returns the new root. */
  insert(key) {
    let nodeIndex = this.leafIndex(key);
    let cur = leafHash(key);
    this._set(0, nodeIndex, cur);
    for (let i = 0; i < this.depth; i++) {
      const sib = this._node(i, nodeIndex ^ 1n);
      cur = (nodeIndex & 1n) === 0n ? hashPair(cur, sib) : hashPair(sib, cur);
      nodeIndex >>= 1n;
      this._set(i + 1, nodeIndex, cur);
    }
    return this.root;
  }

  /** Whether a key's leaf is already filled (i.e. that witness is registered). */
  has(key) {
    return this.nodes[0].has(this.leafIndex(key).toString());
  }
}

export { ZERO, hashPair };
