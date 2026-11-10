// USDT payment verification over public endpoints (no API keys).
// BSC (BEP-20, 18 decimals) via JSON-RPC, Tron (TRC-20, 6 decimals) via TronGrid.
import crypto from "node:crypto";

export const NETWORKS = {
  bsc:  { label: "BSC (BEP-20)",  decimals: 18, contract: "0x55d398326f99059ff775485246999027b3197955", minConf: 3 },
  tron: { label: "Tron (TRC-20)", decimals: 6,  contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" },
};
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

// ---- addresses ----
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function b58decode(s) {
  let n = 0n;
  for (const c of s) { const i = B58.indexOf(c); if (i < 0) return null; n = n * 58n + BigInt(i); }
  let hex = n.toString(16); if (hex.length % 2) hex = "0" + hex;
  const lead = s.match(/^1*/)[0].length;
  return Buffer.concat([Buffer.alloc(lead), Buffer.from(hex, "hex")]);
}
const sha256 = (b) => crypto.createHash("sha256").update(b).digest();
/** Tron base58 address -> 20-byte hex (no prefix), or null if invalid. */
export function tronToHex(addr) {
  const raw = typeof addr === "string" && /^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(addr) ? b58decode(addr) : null;
  if (!raw || raw.length !== 25 || raw[0] !== 0x41) return null;
  if (!sha256(sha256(raw.subarray(0, 21))).subarray(0, 4).equals(raw.subarray(21))) return null;
  return raw.subarray(1, 21).toString("hex");
}
export const isBscAddress = (a) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);
export const isTronAddress = (a) => !!tronToHex(a);
export const isTxid = (network, t) => typeof t === "string" && (network === "bsc" ? /^0x[0-9a-fA-F]{64}$/ : /^[0-9a-fA-F]{64}$/).test(t);

/** "10.0042" -> integer base units for the network (BigInt). */
export function toUnits(amount, network) {
  const [i, f = ""] = String(amount).split(".");
  const d = NETWORKS[network].decimals;
  return BigInt(i + f.padEnd(d, "0").slice(0, d));
}

async function getJson(url, init, ms = 12000) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(url, { ...init, signal: AbortSignal.timeout(ms) });
    if (r.status === 429 && attempt < 3) { await new Promise((ok) => setTimeout(ok, 1200 * (attempt + 1))); continue; }   // public rate limit
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }
}
async function rpc(urls, method, params) {
  let last;
  for (const url of urls) {
    try {
      const j = await getJson(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
      if (j.error) throw new Error(j.error.message || "RPC error");
      return j.result;
    } catch (e) { last = e; }
  }
  throw last || new Error("RPC unavailable");
}

/**
 * Look up a USDT transfer.
 * Returns { status: "ok", units, timeMs } | { status: "pending" } | { status: "invalid", reason }
 * "ok" means: confirmed, successful, USDT, paid to `address`. Amount/time are for the caller to judge.
 */
export async function findTransfer(network, txid, address, opts = {}) {
  if (network === "bsc") {
    const urls = opts.bscRpc?.length ? opts.bscRpc : ["https://bsc-dataseed.binance.org", "https://bsc-dataseed1.defibit.io", "https://bsc-rpc.publicnode.com"];
    const rc = await rpc(urls, "eth_getTransactionReceipt", [txid]);
    if (!rc) return { status: "pending" };
    if (rc.status !== "0x1") return { status: "invalid", reason: "Transaction failed on-chain" };
    const want = "0x" + address.toLowerCase().slice(2).padStart(64, "0");
    let units = 0n;
    for (const log of rc.logs || []) {
      if (log.address?.toLowerCase() !== NETWORKS.bsc.contract) continue;
      if (log.topics?.[0] !== TRANSFER_TOPIC || log.topics[2]?.toLowerCase() !== want) continue;
      units += BigInt(log.data);
    }
    if (units === 0n) return { status: "invalid", reason: "No USDT sent to our address in this transaction" };
    const head = BigInt(await rpc(urls, "eth_blockNumber", []));
    if (head - BigInt(rc.blockNumber) < BigInt(NETWORKS.bsc.minConf)) return { status: "pending" };
    const block = await rpc(urls, "eth_getBlockByNumber", [rc.blockNumber, false]);
    return { status: "ok", units, timeMs: Number(BigInt(block.timestamp)) * 1000 };
  }

  if (network === "tron") {
    const want = tronToHex(address);
    const base = opts.tronApi || "https://api.trongrid.io";
    const key = opts.tronKey ? { "TRON-PRO-API-KEY": opts.tronKey } : {};
    const j = await getJson(`${base}/v1/transactions/${txid}/events?only_confirmed=true`, { headers: key });
    const events = Array.isArray(j.data) ? j.data : [];
    if (!events.length) {
      // not confirmed yet, unknown, or a failed tx (failed txs emit no events)
      const info = await getJson(`${base}/wallet/gettransactioninfobyid`, { method: "POST", headers: { "Content-Type": "application/json", ...key }, body: JSON.stringify({ value: txid }) }).catch(() => ({}));
      if (info?.receipt?.result && info.receipt.result !== "SUCCESS") return { status: "invalid", reason: "Transaction failed on-chain" };
      return { status: "pending" };
    }
    let units = 0n, timeMs = 0;
    for (const ev of events) {
      if (ev.contract_address !== NETWORKS.tron.contract || ev.event_name !== "Transfer") continue;
      const to = String(ev.result?.to || "").toLowerCase().replace(/^0x/, "").replace(/^41(?=[0-9a-f]{40}$)/, "");
      if (to !== want) continue;
      units += BigInt(ev.result.value); timeMs = ev.block_timestamp;
    }
    if (units === 0n) return { status: "invalid", reason: "No USDT sent to our address in this transaction" };
    return { status: "ok", units, timeMs };
  }
  throw new Error("Unknown network");
}
