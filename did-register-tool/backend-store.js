// DIDRegistry backend store
// ---------------------------------------------------------------------------
// Holds the WHOLE per-signal Sparse Merkle Tree (one per signal) in memory, kept in
// sync with the chain by replaying `SignalInserted` events. The backend's job is to
// PROVE: given an account and a chosen term it returns the per-signal (newRoot, siblings)
// insert proofs the register contract expects. The backend does NOT verify — the
// register contract verifies and only stores the roots, never the whole tree.
//
// It also maintains a hashtable `address -> issued signals` (built from `Registered`
// events) — the credential ledger, usable later for e.g. online voting.
import { ethers } from "ethers";
import { SparseMerkleTree } from "./sparse-merkle.js";
import { REGISTRY_ABI, SIGNAL_LABELS, termSignals, describeMechanism } from "./did-registry.js";

export class RegistryStore {
  constructor(rpcUrl, registryAddr, { labels = SIGNAL_LABELS, fromBlock = 0 } = {}) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.registry = new ethers.Contract(registryAddr, REGISTRY_ABI, this.provider);
    this.address = registryAddr;
    this.labels = labels;
    this.fromBlock = fromBlock;

    this.n = 0;
    this.depth = 0;
    this.terms = [];
    this.signals = [];          // [{slot,label,verifier}]
    this.trees = [];            // SparseMerkleTree per signal
    this.issued = new Map();    // address(lowercase) -> {address, signals, termIndex, termMask, tokenId, block}
    this._lastBlock = fromBlock - 1;
    this._syncing = null;
  }

  /** Read the static config (signals, depth, mechanism) and do a first full sync. */
  async init() {
    this.n = Number(await this.registry.numSignals());
    this.depth = Number(await this.registry.TREE_DEPTH());
    const tc = Number(await this.registry.termCount());
    this.terms = [];
    for (let i = 0; i < tc; i++) this.terms.push(Number(await this.registry.terms(i)));

    this.signals = [];
    this.trees = [];
    for (let s = 0; s < this.n; s++) {
      const [verifier] = await this.registry.signals(s);
      this.signals.push({ slot: s, label: this.labels[s] ?? `Signal #${s + 1}`, verifier });
      this.trees.push(new SparseMerkleTree(this.depth));
    }
    await this.sync();
    return this;
  }

  /** Replay any new SignalInserted / Registered events into the in-memory state. */
  async sync() {
    // Coalesce concurrent syncs.
    if (this._syncing) return this._syncing;
    this._syncing = (async () => {
      const head = await this.provider.getBlockNumber();
      const from = this._lastBlock + 1;
      if (from > head) return;

      const inserts = await this.registry.queryFilter(
        this.registry.filters.SignalInserted(), from, head
      );
      inserts.sort((a, b) => (a.blockNumber - b.blockNumber) || (a.index - b.index));
      for (const ev of inserts) {
        const signal = Number(ev.args.signal);
        this.trees[signal].insert(ev.args.key);
      }

      const regs = await this.registry.queryFilter(
        this.registry.filters.Registered(), from, head
      );
      regs.sort((a, b) => (a.blockNumber - b.blockNumber) || (a.index - b.index));
      for (const ev of regs) {
        const mask = Number(ev.args.termMask);
        const addr = ev.args.account;
        this.issued.set(addr.toLowerCase(), {
          address: addr,
          termIndex: Number(ev.args.termIndex),
          termMask: mask,
          signals: termSignals(mask, this.n),
          signalLabels: termSignals(mask, this.n).map((s) => this.signals[s]?.label),
          tokenId: ev.args.tokenId.toString(),
          block: ev.blockNumber,
        });
      }

      this._lastBlock = head;
    })();
    try { await this._syncing; } finally { this._syncing = null; }
  }

  /** Sanity: each in-memory tree root must equal the on-chain signalRoot(s). */
  async checkRoots() {
    const out = [];
    for (let s = 0; s < this.n; s++) {
      const onchain = await this.registry.signalRoot(s);
      const local = this.trees[s].root;
      out.push({ signal: s, ok: onchain.toLowerCase() === local.toLowerCase(), onchain, local });
    }
    return out;
  }

  mechanism() {
    return {
      registry: this.address,
      numSignals: this.n,
      treeDepth: this.depth,
      terms: this.terms,
      formula: describeMechanism(this.terms, this.labels, this.n),
      termDetail: this.terms.map((m, i) => ({ index: i, mask: m, signals: termSignals(m, this.n) })),
      signals: this.signals,
    };
  }

  /** Live held-signals + eligibility for an account (reads witnesses on-chain). */
  async accountInfo(account) {
    const held = Number(await this.registry.signalBitmapOf(account));
    const eligBitmap = Number(await this.registry.eligibleTerms(account));
    const eligibleTerms = [];
    for (let i = 0; i < this.terms.length; i++) if ((eligBitmap & (1 << i)) !== 0) eligibleTerms.push(i);
    return {
      account,
      heldBitmap: held,
      heldSignals: termSignals(held, this.n),
      eligibleTerms,
      registered: await this.registry.isRegistered(account),
      issued: this.issued.get(account.toLowerCase()) ?? null,
    };
  }

  /**
   * Generate the per-signal insert proofs for `account` to satisfy `termIndex`
   * (defaults to the first eligible term). The backend PROVES here; the register
   * contract will verify. Returns { termIndex, signals, inserts, keys, callArgs }.
   */
  async prove(account, termIndex) {
    await this.sync(); // make sure the trees reflect the latest on-chain state

    const eligBitmap = Number(await this.registry.eligibleTerms(account));
    const eligible = [];
    for (let i = 0; i < this.terms.length; i++) if ((eligBitmap & (1 << i)) !== 0) eligible.push(i);
    if (eligible.length === 0) {
      const err = new Error("account satisfies no term of the mechanism");
      err.code = "NO_ELIGIBLE_TERM";
      throw err;
    }
    const ti = termIndex === undefined || termIndex === null ? eligible[0] : Number(termIndex);
    if (!eligible.includes(ti)) {
      const err = new Error(`term ${ti} is not satisfied (eligible: ${eligible.join(",")})`);
      err.code = "TERM_NOT_ELIGIBLE";
      throw err;
    }

    const mask = this.terms[ti];
    const sigs = termSignals(mask, this.n);
    const inserts = [];
    const keys = [];
    for (const s of sigs) {
      const key = await this.registry.witnessOf(s, account);
      if (key === ethers.ZeroHash) {
        const err = new Error(`signal ${s} (${this.signals[s].label}) not held`);
        err.code = "SIGNAL_NOT_HELD";
        throw err;
      }
      if (this.trees[s].has(key)) {
        const err = new Error(`signal ${s} (${this.signals[s].label}): witness already registered (duplicate)`);
        err.code = "DUPLICATE";
        throw err;
      }
      const { newRoot, siblings } = this.trees[s].preview(key);
      inserts.push({ newRoot, siblings });
      keys.push(key);
    }

    return {
      account, termIndex: ti, mask, signals: sigs,
      signalLabels: sigs.map((s) => this.signals[s].label),
      keys, inserts,
      callArgs: [ti, inserts.map((x) => [x.newRoot, x.siblings])],
    };
  }

  /** The address -> issued-signals hashtable (credential ledger; e.g. for voting). */
  registryTable() {
    return Array.from(this.issued.values());
  }

  /** The most recently registered N identities (newest first). */
  recent(n = 10) {
    return Array.from(this.issued.values())
      .sort((a, b) => (b.block - a.block) || (b.tokenId.localeCompare?.(a.tokenId) ?? 0))
      .slice(0, Math.max(0, n));
  }
}
