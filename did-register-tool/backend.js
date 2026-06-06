#!/usr/bin/env node
// DIDRegistry backend (prove-only) HTTP service
// ---------------------------------------------------------------------------
// Backs the register frontend. It holds the WHOLE per-signal Sparse Merkle Tree and
// generates the insert proofs a user needs to register; the register contract verifies
// them and only stores the roots. It also serves the address -> issued-signals
// hashtable (the credential ledger) for downstream uses such as online voting.
//
// Endpoints (all JSON, CORS-open for the static frontend):
//   GET /health
//   GET /mechanism                       -> signals, DNF terms, formula, depth
//   GET /account/:addr                   -> held signals, eligible terms, registered?
//   GET /prove?account=0x..&term=0       -> { termIndex, inserts:[{newRoot,siblings}], callArgs }
//   GET /registry                        -> [{ address, signals, termMask, tokenId }, ...]
//   GET /recent?n=10                     -> the most recently registered N (newest first)
//   GET /registry/:addr                  -> one ledger entry (or null)
//   GET /roots                           -> in-memory vs on-chain root check
//
// Run:
//   RPC_URL=http://127.0.0.1:8545 REGISTRY=0x... node backend.js   # PORT defaults to 8090
import http from "node:http";
import { RegistryStore } from "./backend-store.js";

const PORT = Number(process.env.PORT || 8090);
const RPC_URL = process.env.RPC_URL || process.env.DID_RPC || "http://127.0.0.1:8545";
const REGISTRY = process.env.REGISTRY || process.env.DID_REGISTRY;
const SYNC_MS = Number(process.env.SYNC_MS || 4000);

if (!REGISTRY) {
  console.error("Set REGISTRY=0x... (the DIDRegistry address). Optional: RPC_URL, PORT, SYNC_MS.");
  process.exit(1);
}

function send(res, code, body) {
  const json = JSON.stringify(body, null, 2);
  res.writeHead(code, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-headers": "content-type",
  });
  res.end(json);
}

async function main() {
  console.error(`Connecting to ${RPC_URL}, registry ${REGISTRY} …`);
  const store = await new RegistryStore(RPC_URL, REGISTRY).init();
  console.error(`Loaded mechanism: ${store.mechanism().formula}`);
  console.error(`Synced ${store.registryTable().length} registration(s).`);

  // Background sync so the in-memory trees + ledger track the chain.
  const timer = setInterval(() => store.sync().catch((e) => console.error("sync error:", e.message)), SYNC_MS);
  timer.unref?.();

  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === "OPTIONS") return send(res, 204, {});
      const url = new URL(req.url, `http://localhost:${PORT}`);
      const path = url.pathname.replace(/\/+$/, "") || "/";

      if (path === "/health") return send(res, 200, { ok: true, registry: REGISTRY, rpc: RPC_URL });
      if (path === "/mechanism") return send(res, 200, store.mechanism());
      if (path === "/roots") return send(res, 200, await store.checkRoots());
      if (path === "/registry") return send(res, 200, { count: store.registryTable().length, entries: store.registryTable() });
      if (path === "/recent") {
        const n = Number(url.searchParams.get("n") || 10);
        const entries = store.recent(n);
        return send(res, 200, { count: entries.length, entries });
      }

      let m;
      if ((m = path.match(/^\/account\/(0x[0-9a-fA-F]{40})$/))) {
        return send(res, 200, await store.accountInfo(m[1]));
      }
      if ((m = path.match(/^\/registry\/(0x[0-9a-fA-F]{40})$/))) {
        const entry = store.registryTable().find((e) => e.address.toLowerCase() === m[1].toLowerCase());
        return send(res, 200, entry ?? null);
      }
      if (path === "/prove") {
        const account = url.searchParams.get("account");
        if (!account) return send(res, 400, { error: "missing ?account=0x.." });
        const term = url.searchParams.has("term") ? Number(url.searchParams.get("term")) : undefined;
        try {
          return send(res, 200, await store.prove(account, term));
        } catch (e) {
          return send(res, 409, { error: e.message, code: e.code ?? "PROVE_FAILED" });
        }
      }

      return send(res, 404, { error: "not found", path });
    } catch (e) {
      return send(res, 500, { error: e.shortMessage || e.message || String(e) });
    }
  });

  server.listen(PORT, () => {
    console.error(`DIDRegistry backend listening on http://127.0.0.1:${PORT}`);
    console.error(`  GET /mechanism  /account/:addr  /prove?account=&term=  /registry`);
  });
}

main().catch((e) => { console.error("fatal:", e.shortMessage || e.message || e); process.exit(1); });
