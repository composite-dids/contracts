// DIDRegistry client helpers
// ---------------------------------------------------------------------------
// Reconstructs the registry's per-signal Sparse Merkle Trees from on-chain
// `SignalInserted` events and prepares the per-signal (newRoot, siblings) insert
// proofs that DIDRegistry.register(termIndex, inserts) expects.
//
// Eligibility is a negation-free DNF: a disjunction (OR) of conjunctive `terms`, each
// term a bitmap of signals that must ALL hold. To register you pick ONE term you
// satisfy and submit an insert proof for each signal in it. Each signal's tree rejects
// a witness that is already registered (per-signal de-duplication).
import { ethers } from "ethers";
import { SparseMerkleTree } from "./sparse-merkle.js";

export const REGISTRY_ABI = [
  "function TREE_DEPTH() view returns (uint256)",
  "function MAX_SIGNALS() view returns (uint8)",
  "function numSignals() view returns (uint256)",
  "function termCount() view returns (uint256)",
  "function terms(uint256) view returns (uint8)",
  "function signals(uint256) view returns (address verifier, bytes4 witnessSelector)",
  "function signalRoot(uint256) view returns (bytes32)",
  "function witnessOf(uint8 slot, address account) view returns (bytes32)",
  "function hasSignal(uint8 slot, address account) view returns (bool)",
  "function signalBitmapOf(address account) view returns (uint8)",
  "function satisfiesTerm(address account, uint256 termIndex) view returns (bool)",
  "function eligibleTerms(address account) view returns (uint256)",
  "function leafHash(bytes32 key) pure returns (bytes32)",
  "function zeros(uint256 height) view returns (bytes32)",
  "function isRegistered(address account) view returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function register(uint8 termIndex, (bytes32 newRoot, bytes32[] siblings)[] inserts) returns (uint256 tokenId)",
  "event Registered(address indexed account, uint8 indexed termIndex, uint8 termMask, uint256 tokenId)",
  "event SignalInserted(uint8 indexed signal, bytes32 indexed key, bytes32 newRoot)",
];

/** Default human labels for the integrated signal slots (override per deployment). */
export const SIGNAL_LABELS = [
  "Validator identity",
  "GitHub account",
  "Google account",
  "arXiv account",
];

/** Where a user goes to prove each signal (relative to the frontend dir). */
export const SIGNAL_PROVE_URLS = [
  "index.html",   // validator
  "reclaim.html", // GitHub (Reclaim zkTLS)
  "reclaim.html", // Google (Reclaim zkTLS)
  "reclaim.html", // arXiv  (Reclaim zkTLS)
];

/** Decompose a term bitmap into the list of signal indices it requires. */
export function termSignals(mask, n) {
  const out = [];
  for (let s = 0; s < n; s++) if ((Number(mask) & (1 << s)) !== 0) out.push(s);
  return out;
}

/** Render a DNF mechanism as a human string, e.g. "(validator AND github) OR (gmail AND arxiv)". */
export function describeMechanism(terms, labels, n) {
  return terms
    .map((mask) => termSignals(mask, n).map((s) => labels[s] ?? `signal#${s}`).join(" AND "))
    .map((t) => (terms.length > 1 ? `(${t})` : t))
    .join(" OR ");
}

/**
 * Rebuild a single signal's Sparse Merkle Tree by replaying its `SignalInserted` events.
 * Returns a populated SparseMerkleTree whose root should equal signalRoot(signal).
 */
export async function rebuildSignalTree(registry, signal, depth, { fromBlock = 0 } = {}) {
  const tree = new SparseMerkleTree(depth);
  const events = await registry.queryFilter(
    registry.filters.SignalInserted(signal),
    fromBlock,
    "latest"
  );
  for (const ev of events) tree.insert(ev.args.key);
  return tree;
}

/**
 * Inspect an account against the mechanism.
 * @returns {{
 *   n: number, depth: number, terms: number[],
 *   signals: {slot:number,label:string,verifier:string,held:boolean}[],
 *   heldBitmap: number, eligibleTerms: number[], alreadyRegistered: boolean
 * }}
 */
export async function inspect(registry, account, { labels = SIGNAL_LABELS } = {}) {
  const n = Number(await registry.numSignals());
  const depth = Number(await registry.TREE_DEPTH());
  const tc = Number(await registry.termCount());
  const terms = [];
  for (let i = 0; i < tc; i++) terms.push(Number(await registry.terms(i)));

  const heldBitmap = Number(await registry.signalBitmapOf(account));
  const signals = [];
  for (let s = 0; s < n; s++) {
    const [verifier] = await registry.signals(s);
    signals.push({
      slot: s,
      label: labels[s] ?? `Signal #${s + 1}`,
      verifier,
      held: (heldBitmap & (1 << s)) !== 0,
    });
  }

  const eligBitmap = Number(await registry.eligibleTerms(account));
  const eligibleTerms = [];
  for (let i = 0; i < tc; i++) if ((eligBitmap & (1 << i)) !== 0) eligibleTerms.push(i);

  return {
    n, depth, terms, signals, heldBitmap, eligibleTerms,
    alreadyRegistered: await registry.isRegistered(account),
  };
}

/**
 * Prepare a registration for `account` satisfying `termIndex` (defaults to the first
 * eligible term). Builds the per-signal insert proofs by rebuilding each involved
 * signal's tree from chain.
 *
 * @returns {{
 *   termIndex: number|null, mask: number, signals: number[],
 *   inserts: {newRoot:string,siblings:string[]}[], keys: string[],
 *   callArgs: [number, {newRoot:string,siblings:string[]}[]]|null,
 *   canRegister: boolean, reason: string|null
 * }}
 */
export async function prepareRegistration(registry, account, opts = {}) {
  const info = await inspect(registry, account, opts);

  if (info.eligibleTerms.length === 0) {
    return {
      termIndex: null, mask: 0, signals: [], inserts: [], keys: [],
      callArgs: null, canRegister: false,
      reason: "account satisfies no term of the mechanism (prove the missing signals)",
      info,
    };
  }

  const termIndex = opts.termIndex !== undefined ? Number(opts.termIndex) : info.eligibleTerms[0];
  if (!info.eligibleTerms.includes(termIndex)) {
    throw new Error(`term ${termIndex} is not satisfied by ${account}; eligible: ${info.eligibleTerms}`);
  }

  const mask = info.terms[termIndex];
  const sigs = termSignals(mask, info.n);

  const inserts = [];
  const keys = [];
  for (const s of sigs) {
    const key = await registry.witnessOf(s, account);
    if (key === ethers.ZeroHash) throw new Error(`signal ${s} not held by ${account}`);

    const tree = await rebuildSignalTree(registry, s, info.depth, opts);
    const onchainRoot = await registry.signalRoot(s);
    if (tree.root.toLowerCase() !== onchainRoot.toLowerCase()) {
      throw new Error(`signal ${s}: local root ${tree.root} != on-chain ${onchainRoot} (rebuild stale)`);
    }
    if (tree.has(key)) throw new Error(`signal ${s}: witness already registered (duplicate)`);

    const { newRoot, siblings } = tree.preview(key);
    inserts.push({ newRoot, siblings });
    keys.push(key);
  }

  return {
    termIndex, mask, signals: sigs, inserts, keys,
    callArgs: [termIndex, inserts], canRegister: true, reason: null, info,
  };
}

/** Convenience: build the registry contract instance. */
export function getRegistry(addressOrName, signerOrProvider) {
  return new ethers.Contract(addressOrName, REGISTRY_ABI, signerOrProvider);
}
