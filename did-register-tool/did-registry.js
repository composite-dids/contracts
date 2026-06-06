// DIDRegistry client helpers
// ---------------------------------------------------------------------------
// Reconstructs the registry's incremental Merkle tree from on-chain `Registered`
// events and prepares the (signalBitmap, newRoot r', insertionPath π) tuple that
// DIDRegistry.register(...) expects.
//
// Signal slots: 0 = beacon validator identity, 1 = historical balance,
// 2 & 3 = reserved for the 3rd / 4th proofs (default 0x0000 placeholder).
import { ethers } from "ethers";
import { IncrementalMerkleTree } from "./incremental-merkle.js";

export const REGISTRY_ABI = [
  "function TREE_DEPTH() view returns (uint256)",
  "function root() view returns (bytes32)",
  "function nextIndex() view returns (uint256)",
  "function MAX_SIGNALS() view returns (uint8)",
  "function signals(uint256) view returns (address verifier, bytes4 selector)",
  "function hasSignal(uint8 slot, address account) view returns (bool)",
  "function signalBitmapOf(address account) view returns (uint8)",
  "function previewCommitment(address account, uint8 bitmap) view returns (bytes32)",
  "function isRegistered(address account) view returns (bool)",
  "function usedCommitment(bytes32) view returns (bool)",
  "function isKnownRoot(bytes32) view returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function tokenOfCommitment(bytes32) view returns (uint256)",
  "function register(uint8 signalBitmap, bytes32 newRoot, bytes32[] insertionPath) returns (uint256 tokenId, uint256 leafIndex)",
  "event Registered(address indexed account, bytes32 indexed commitment, uint256 leafIndex, uint8 signalBitmap, bytes32 newRoot, uint256 tokenId)",
];

/** Human labels for the four integrated signal slots. */
export const SIGNAL_LABELS = [
  "Beacon validator identity",
  "Historical balance",
  "GitHub account",
  "Google account",
];

/** Where a user goes to prove each signal (relative to the frontend dir). */
export const SIGNAL_PROVE_URLS = [
  "index.html",   // beacon validator
  "balance.html", // historical balance
  "reclaim.html", // GitHub (Reclaim zkTLS)
  "reclaim.html", // Google (Reclaim zkTLS)
];

/**
 * Rebuild the registry's Merkle tree locally by replaying `Registered` events in
 * leaf order. Returns a populated IncrementalMerkleTree whose root should equal the
 * on-chain root.
 */
export async function rebuildTree(registry, { fromBlock = 0 } = {}) {
  const depth = Number(await registry.TREE_DEPTH());
  const tree = new IncrementalMerkleTree(depth);

  const events = await registry.queryFilter(registry.filters.Registered(), fromBlock, "latest");
  // Order strictly by the on-chain leaf index (block/log order should already match,
  // but sort defensively).
  events.sort((a, b) => Number(a.args.leafIndex) - Number(b.args.leafIndex));
  for (const ev of events) {
    const idx = Number(ev.args.leafIndex);
    if (idx !== tree.count) {
      throw new Error(`leaf gap: expected index ${tree.count}, event says ${idx}`);
    }
    tree.insert(ev.args.commitment);
  }
  return tree;
}

/**
 * Prepare everything needed to register `account`.
 * @returns {{
 *   bitmap: number, signals: {slot:number,label:string,active:boolean}[],
 *   commitment: string, newRoot: string, insertionPath: string[], leafIndex: number,
 *   alreadyRegistered: boolean, callArgs: [number, string, string[]]
 * }}
 */
export async function prepareRegistration(registry, account, opts = {}) {
  const bitmap = Number(await registry.signalBitmapOf(account));
  const maxSignals = Number(await registry.MAX_SIGNALS());
  const signals = [];
  for (let s = 0; s < maxSignals; s++) {
    signals.push({
      slot: s,
      label: SIGNAL_LABELS[s] ?? `Signal #${s + 1}`,
      active: (bitmap & (1 << s)) !== 0,
    });
  }

  const alreadyRegistered = await registry.isRegistered(account);
  if (bitmap === 0) {
    return { bitmap, signals, alreadyRegistered, commitment: null, newRoot: null, insertionPath: [], leafIndex: -1, callArgs: null };
  }

  // The leaf x is computed on-chain to avoid any abi-encoding drift.
  const commitment = await registry.previewCommitment(account, bitmap);
  const tree = await rebuildTree(registry, opts);

  // Sanity: our reconstructed root must match the chain's current root r.
  const onchainRoot = await registry.root();
  if (tree.root.toLowerCase() !== onchainRoot.toLowerCase()) {
    throw new Error(`local root ${tree.root} != on-chain root ${onchainRoot}; rebuild may be stale`);
  }

  const { newRoot, path, leafIndex } = tree.previewInsert(commitment);
  return {
    bitmap,
    signals,
    alreadyRegistered,
    commitment,
    newRoot,
    insertionPath: path,
    leafIndex,
    callArgs: [bitmap, newRoot, path],
  };
}

/** Convenience: build the registry contract instance. */
export function getRegistry(addressOrName, signerOrProvider) {
  return new ethers.Contract(addressOrName, REGISTRY_ABI, signerOrProvider);
}
