// Incremental Merkle tree — the off-chain mirror of DIDRegistry's accumulator.
// -----------------------------------------------------------------------------
// Append-only tree over keccak256(abi.encodePacked(left, right)), empty leaf = 0x00..0.
// Used to produce the (newRoot r', insertionPath π) that DIDRegistry.register expects,
// and to generate membership proofs for already-registered leaves.
//
// Hashing MUST match DIDRegistry._hashPair / zeros exactly.
import { ethers } from "ethers";

const ZERO = "0x" + "00".repeat(32);

const hashPair = (a, b) => ethers.keccak256(ethers.concat([a, b]));

export class IncrementalMerkleTree {
  /** @param {number} depth tree depth (capacity 2**depth). */
  constructor(depth) {
    if (!Number.isInteger(depth) || depth < 1 || depth > 32) {
      throw new Error("depth must be an integer in [1, 32]");
    }
    this.depth = depth;
    this.count = 0;

    // zeros[i] = root of an empty subtree of height i.
    this.zeros = [ZERO];
    for (let i = 0; i < depth; i++) this.zeros.push(hashPair(this.zeros[i], this.zeros[i]));

    // filledSubtrees[i] = the left-sibling cached at level i along the frontier.
    this.filled = this.zeros.slice(0, depth);
    this.leaves = [];
    this.root = this.zeros[depth];
  }

  /**
   * Compute (newRoot, path) for appending `leaf` at the current frontier WITHOUT
   * mutating the tree. These are exactly the `(newRoot, insertionPath)` args for
   * DIDRegistry.register.
   * @param {string} leaf 0x-prefixed bytes32
   * @returns {{ newRoot: string, path: string[], leafIndex: number }}
   */
  previewInsert(leaf) {
    let idx = this.count;
    let cur = leaf;
    const path = [];
    for (let i = 0; i < this.depth; i++) {
      if ((idx & 1) === 0) {
        path.push(this.zeros[i]);
        cur = hashPair(cur, this.zeros[i]);
      } else {
        path.push(this.filled[i]);
        cur = hashPair(this.filled[i], cur);
      }
      idx >>= 1;
    }
    return { newRoot: cur, path, leafIndex: this.count };
  }

  /** Append `leaf`, mutating the frontier and root. */
  insert(leaf) {
    let idx = this.count;
    let cur = leaf;
    for (let i = 0; i < this.depth; i++) {
      if ((idx & 1) === 0) {
        this.filled[i] = cur;
        cur = hashPair(cur, this.zeros[i]);
      } else {
        cur = hashPair(this.filled[i], cur);
      }
      idx >>= 1;
    }
    this.leaves.push(leaf);
    this.root = cur;
    this.count += 1;
    return this.count - 1;
  }

  /**
   * Membership proof for the leaf at `index` against the *current* root. Useful for
   * later "I am a registered DID" proofs against a known historical root.
   * @returns {{ leaf: string, path: string[], pathIndices: number[], root: string }}
   */
  membershipProof(index) {
    if (index < 0 || index >= this.count) throw new Error("index out of range");
    const path = [];
    const pathIndices = [];
    const layer = this.leaves.slice();
    let idx = index;
    let nodes = layer;
    for (let i = 0; i < this.depth; i++) {
      const isRight = idx & 1;
      const sibIdx = isRight ? idx - 1 : idx + 1;
      const sib = sibIdx < nodes.length ? nodes[sibIdx] : this.zeros[i];
      path.push(sib);
      pathIndices.push(isRight);
      // build next layer
      const next = [];
      for (let j = 0; j < nodes.length; j += 2) {
        const l = nodes[j];
        const r = j + 1 < nodes.length ? nodes[j + 1] : this.zeros[i];
        next.push(hashPair(l, r));
      }
      nodes = next;
      idx >>= 1;
    }
    return { leaf: this.leaves[index], path, pathIndices, root: this.root };
  }
}

export { ZERO, hashPair };
