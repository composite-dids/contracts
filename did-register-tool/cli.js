#!/usr/bin/env node
// DIDRegistry CLI
// ---------------------------------------------------------------------------
// Generate the registration tuple, inspect signal status, or submit a registration.
//
//   node cli.js prepare  --rpc <url> --registry <addr> --account <addr>
//   node cli.js signals  --rpc <url> --registry <addr> --account <addr>
//   node cli.js register --rpc <url> --registry <addr> --pk <0x privkey>
//   node cli.js root     --rpc <url> --registry <addr>
//
// `prepare` prints the exact (signalBitmap, newRoot, insertionPath) you'd pass to
// register(...) — handy for relayers, scripts, or the frontend.
import { ethers } from "ethers";
import { getRegistry, prepareRegistration, SIGNAL_LABELS } from "./did-registry.js";

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
    console.error("Usage: node cli.js <prepare|signals|register|root> --rpc <url> --registry <addr> [...]");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(need(args, "rpc"));
  const registryAddr = need(args, "registry");

  if (cmd === "root") {
    const reg = getRegistry(registryAddr, provider);
    console.log(JSON.stringify({
      root: await reg.root(),
      nextIndex: Number(await reg.nextIndex()),
      treeDepth: Number(await reg.TREE_DEPTH()),
    }, null, 2));
    return;
  }

  if (cmd === "signals") {
    const reg = getRegistry(registryAddr, provider);
    const account = need(args, "account");
    const bitmap = Number(await reg.signalBitmapOf(account));
    const max = Number(await reg.MAX_SIGNALS());
    const rows = [];
    for (let s = 0; s < max; s++) {
      const [verifier] = await reg.signals(s);
      rows.push({
        slot: s,
        label: SIGNAL_LABELS[s] ?? `Signal #${s + 1}`,
        verifier,
        configured: verifier !== ethers.ZeroAddress,
        active: (bitmap & (1 << s)) !== 0,
      });
    }
    console.log(JSON.stringify({ account, bitmap, signals: rows }, null, 2));
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
    const plan = await prepareRegistration(reg, account);

    if (plan.bitmap === 0) {
      console.error(`Account ${account} holds no signals — verify on a signal contract first.`);
      process.exit(2);
    }
    if (plan.alreadyRegistered) {
      const held = Number(await reg.balanceOf(account));
      console.error(`Account ${account} already holds ${held} credential(s). Registering a NEW proof mints another; an exact replay is rejected on-chain.`);
    }

    console.log(JSON.stringify({
      account,
      bitmap: plan.bitmap,
      signals: plan.signals,
      commitment: plan.commitment,
      leafIndex: plan.leafIndex,
      newRoot: plan.newRoot,
      insertionPath: plan.insertionPath,
    }, null, 2));

    if (cmd === "register") {
      console.error("Submitting register() …");
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
