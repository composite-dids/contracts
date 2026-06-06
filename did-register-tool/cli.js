#!/usr/bin/env node
// DIDRegistry CLI
// ---------------------------------------------------------------------------
// Inspect the mechanism + an account's signals, build the per-signal insert proofs,
// or submit a registration.
//
//   node cli.js mechanism --rpc <url> --registry <addr>
//   node cli.js signals   --rpc <url> --registry <addr> --account <addr>
//   node cli.js prepare   --rpc <url> --registry <addr> --account <addr> [--term <i>]
//   node cli.js register  --rpc <url> --registry <addr> --pk <0x privkey> [--term <i>]
//
// Eligibility is a negation-free DNF (OR of AND-terms). `prepare`/`register` default to
// the first term the account satisfies; pass --term to choose another.
import { ethers } from "ethers";
import {
  getRegistry, prepareRegistration, inspect, describeMechanism, termSignals, SIGNAL_LABELS,
} from "./did-registry.js";

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) out[a.slice(2)] = argv[++i];
    else out._.push(a);
  }
  return out;
}

function need(args, key) {
  const v = args[key] ?? process.env[`DID_${key.toUpperCase()}`];
  if (!v) {
    console.error(`Missing --${key} (or DID_${key.toUpperCase()} env var).`);
    process.exit(1);
  }
  return v;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];
  if (!cmd) {
    console.error("Usage: node cli.js <mechanism|signals|prepare|register> --rpc <url> --registry <addr> [...]");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(need(args, "rpc"));
  const registryAddr = need(args, "registry");

  if (cmd === "mechanism") {
    const reg = getRegistry(registryAddr, provider);
    const n = Number(await reg.numSignals());
    const tc = Number(await reg.termCount());
    const terms = [];
    for (let i = 0; i < tc; i++) terms.push(Number(await reg.terms(i)));
    console.log(JSON.stringify({
      numSignals: n,
      treeDepth: Number(await reg.TREE_DEPTH()),
      terms,
      formula: describeMechanism(terms, SIGNAL_LABELS, n),
      termDetail: terms.map((m, i) => ({ index: i, mask: m, signals: termSignals(m, n) })),
    }, null, 2));
    return;
  }

  if (cmd === "signals") {
    const reg = getRegistry(registryAddr, provider);
    const account = need(args, "account");
    const info = await inspect(reg, account);
    console.log(JSON.stringify({
      account,
      heldBitmap: info.heldBitmap,
      formula: describeMechanism(info.terms, SIGNAL_LABELS, info.n),
      eligibleTerms: info.eligibleTerms,
      alreadyRegistered: info.alreadyRegistered,
      signals: info.signals,
    }, null, 2));
    return;
  }

  if (cmd === "prepare" || cmd === "register") {
    let signer = null;
    let account = args.account;
    if (cmd === "register") {
      signer = new ethers.Wallet(need(args, "pk"), provider);
      account = await signer.getAddress();
    }
    if (!account) need(args, "account");

    const reg = getRegistry(registryAddr, signer ?? provider);
    const opts = args.term !== undefined ? { termIndex: Number(args.term) } : {};
    const plan = await prepareRegistration(reg, account, opts);

    if (!plan.canRegister) {
      console.error(`Cannot register ${account}: ${plan.reason}`);
      console.log(JSON.stringify({
        account,
        formula: describeMechanism(plan.info.terms, SIGNAL_LABELS, plan.info.n),
        eligibleTerms: plan.info.eligibleTerms,
        signals: plan.info.signals,
      }, null, 2));
      process.exit(2);
    }

    console.log(JSON.stringify({
      account,
      termIndex: plan.termIndex,
      termSignals: plan.signals,
      keys: plan.keys,
      inserts: plan.inserts,
    }, null, 2));

    if (cmd === "register") {
      console.error(`Submitting register(term ${plan.termIndex}) …`);
      const tx = await reg.register(...plan.callArgs);
      console.error("tx:", tx.hash);
      const rcpt = await tx.wait();
      console.error("✓ mined in block", rcpt.blockNumber);
    }
    return;
  }

  console.error(`Unknown command '${cmd}'.`);
  process.exit(1);
}

main().catch((e) => {
  console.error("Error:", e.shortMessage || e.message || e);
  process.exit(1);
});
