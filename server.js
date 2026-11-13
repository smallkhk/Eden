// LiveChar — live AI character changer
// Accounts + per-second balance + admin panel.
// Engines: Decart Lucy (direct) + VAST Eden Live 14B / 5B (fal.ai)
import express from "express";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { createDecartClient } from "@decartai/sdk";
import falProxy from "@fal-ai/server-proxy";
import QRCode from "qrcode";
import nodemailer from "nodemailer";
import { NETWORKS, findTransfer, toUnits, isBscAddress, isTronAddress, isTxid } from "./lib/chain.js";

try { process.loadEnvFile(); } catch { /* no .env file */ }

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, "data");
fs.mkdirSync(DATA_DIR, { recursive: true });

// ---------- database ----------
const db = new DatabaseSync(path.join(DATA_DIR, "livechar.db"));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE COLLATE NOCASE, pass TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0,
    balance REAL NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS auth (token TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires_at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS ledger (
    id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, delta REAL NOT NULL, reason TEXT NOT NULL, created_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, engine TEXT NOT NULL, rate REAL NOT NULL,
    cap_seconds INTEGER NOT NULL, started_at INTEGER NOT NULL, last_beat INTEGER NOT NULL,
    ended_at INTEGER, charged REAL NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS sessions_open ON sessions (ended_at, user_id);
`);
db.exec(`
  CREATE TABLE IF NOT EXISTS packages (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, seconds INTEGER NOT NULL, price REAL NOT NULL,
    active INTEGER NOT NULL DEFAULT 1, sort INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, package_name TEXT NOT NULL, seconds INTEGER NOT NULL,
    network TEXT NOT NULL, amount TEXT NOT NULL, address TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
    txid TEXT, note TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, paid_at INTEGER
  );
  CREATE UNIQUE INDEX IF NOT EXISTS orders_txid ON orders (network, txid) WHERE txid IS NOT NULL;
  CREATE TABLE IF NOT EXISTS vouchers (
    code TEXT PRIMARY KEY, seconds INTEGER NOT NULL, max_uses INTEGER NOT NULL DEFAULT 1, uses INTEGER NOT NULL DEFAULT 0,
    note TEXT, created_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS redemptions (code TEXT NOT NULL, user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (code, user_id));
  CREATE TABLE IF NOT EXISTS characters (
    id INTEGER PRIMARY KEY, user_id INTEGER, name TEXT NOT NULL, prompt TEXT NOT NULL DEFAULT '', mime TEXT NOT NULL, created_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS resets (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires_at INTEGER NOT NULL);
`);
if (!db.prepare("PRAGMA table_info(users)").all().some((c) => c.name === "email")) db.exec("ALTER TABLE users ADD COLUMN email TEXT");
const CHAR_DIR = path.join(DATA_DIR, "chars");
fs.mkdirSync(CHAR_DIR, { recursive: true });
const q = (sql) => db.prepare(sql);
const now = () => Date.now();
const r2 = (n) => Math.round(n * 100) / 100;

// ---------- settings (admin-editable; .env is only a fallback for the keys) ----------
const DEFAULTS = {
  fal_key: "", decart_key: "", elevenlabs_key: "", rate_voice: "1",
  rate_lucy: "1", rate_eden_5b: "1", rate_eden_14b: "1", lucy_fast: "1",
  first_frame_fee: "0", max_session_seconds: "300", signup_bonus: "0", allow_signup: "1",
  lucy_model: "lucy-latest", first_frame_model: "fal-ai/flux-2/klein/9b/edit",
  usdt_bsc_address: "", usdt_tron_address: "", tron_api_key: "",
  smtp_host: "", smtp_port: "587", smtp_user: "", smtp_pass: "", smtp_from: "", site_url: "",
};
const realKey = (v) => (v && !/^YOUR_/i.test(v) ? v : "");
function setting(key) {
  const row = q("SELECT value FROM settings WHERE key = ?").get(key);
  if (row && row.value !== "") return row.value;
  if (key === "fal_key") return realKey(process.env.FAL_KEY);
  if (key === "decart_key") return realKey(process.env.DECART_API_KEY);
  if (key === "elevenlabs_key") return realKey(process.env.ELEVENLABS_API_KEY);
  return DEFAULTS[key] ?? "";
}
const num = (key) => { const n = Number(setting(key)); return Number.isFinite(n) ? n : Number(DEFAULTS[key]); };
const setSetting = (key, value) =>
  q("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, String(value));

const ENGINES = {
  lucy:       { rate: () => num("rate_lucy"), provider: "decart" },
  "eden-5b":  { rate: () => num("rate_eden_5b"),  provider: "fal", endpoint: "vast/eden-live-5b-video" },
  "eden-14b": { rate: () => num("rate_eden_14b"), provider: "fal", endpoint: "vast/eden-live-14b-video" },
};

// ---------- auth ----------
const COOKIE = "lc_sid";
const hashPw = (pw, salt = crypto.randomBytes(16).toString("hex")) =>
  `${salt}:${crypto.scryptSync(pw, salt, 64).toString("hex")}`;
function checkPw(pw, stored) {
  const [salt, hash] = String(stored).split(":");
  if (!salt || !hash) return false;
  const a = Buffer.from(hash, "hex"), b = crypto.scryptSync(pw, salt, 64);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
const cookieOf = (header, name) => {
  const m = String(header || "").match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? m[1] : "";
};
function userFromCookie(cookieHeader) {
  const token = cookieOf(cookieHeader, COOKIE);
  if (!/^[a-f0-9]{64}$/.test(token)) return null;
  const u = q(`SELECT u.* FROM auth a JOIN users u ON u.id = a.user_id WHERE a.token = ? AND a.expires_at > ?`).get(token, now());
  return u && !u.disabled ? u : null;
}
const pub = (u) => ({ id: u.id, username: u.username, email: u.email || "", isAdmin: !!u.is_admin, balance: r2(u.balance) });
const cleanEmail = (v) => { const e = String(v || "").trim().toLowerCase(); return /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/.test(e) ? e : ""; };

const app = express();
app.set("trust proxy", 1);
// sendBeacon posts text/plain
app.use("/api/session/stop", express.text({ type: "text/plain", limit: "2kb" }));
app.use(express.json({ limit: "12mb" }));

const requireUser = (req, res, next) => {
  req.user = userFromCookie(req.headers.cookie);
  return req.user ? next() : res.status(401).json({ error: "Please log in" });
};
const requireAdmin = (req, res, next) =>
  requireUser(req, res, () => (req.user.is_admin ? next() : res.status(403).json({ error: "Admin only" })));

// small in-memory limiter for login / register
const hits = new Map();
function limited(req, bucket, max, windowMs) {
  const key = `${bucket}:${req.ip}`, t = now();
  const list = (hits.get(key) || []).filter((x) => t - x < windowMs);
  list.push(t); hits.set(key, list);
  return list.length > max;
}
setInterval(() => { const t = now(); for (const [k, v] of hits) if (!v.some((x) => t - x < 3600000)) hits.delete(k); }, 300000).unref();

function startAuth(req, res, user) {
  const token = crypto.randomBytes(32).toString("hex");
  q("INSERT INTO auth (token, user_id, expires_at) VALUES (?, ?, ?)").run(token, user.id, now() + 30 * 864e5);
  res.setHeader("Set-Cookie", `${COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000${req.secure ? "; Secure" : ""}`);
}

app.post("/api/register", (req, res) => {
  if (limited(req, "reg", 10, 3600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const username = String(req.body?.username || "").trim();
  const password = String(req.body?.password || "");
  const first = q("SELECT COUNT(*) AS n FROM users").get().n === 0;
  if (!first && setting("allow_signup") !== "1") return res.status(403).json({ error: "Sign-ups are closed" });
  if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) return res.status(400).json({ error: "Username: 3-32 letters, numbers, _ . -" });
  if (password.length < 6 || password.length > 200) return res.status(400).json({ error: "Password must be at least 6 characters" });
  if (q("SELECT 1 FROM users WHERE username = ?").get(username)) return res.status(409).json({ error: "Username already taken" });
  const rawEmail = String(req.body?.email || "").trim(), email = cleanEmail(rawEmail);
  if (rawEmail && !email) return res.status(400).json({ error: "That email address doesn't look right" });
  if (email && q("SELECT 1 FROM users WHERE email = ?").get(email)) return res.status(409).json({ error: "Email already in use" });

  const bonus = first ? 0 : Math.max(0, num("signup_bonus"));
  const info = q("INSERT INTO users (username, pass, is_admin, balance, created_at, email) VALUES (?, ?, ?, ?, ?, ?)")
    .run(username, hashPw(password), first ? 1 : 0, bonus, now(), email || null);   // first account = admin
  const id = Number(info.lastInsertRowid);
  if (bonus > 0) q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").run(id, bonus, "Signup bonus", now());
  const user = q("SELECT * FROM users WHERE id = ?").get(id);
  startAuth(req, res, user);
  res.json({ user: pub(user) });
});

app.post("/api/login", (req, res) => {
  if (limited(req, "login", 15, 600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const login = String(req.body?.username || "").trim();
  const user = q("SELECT * FROM users WHERE username = ?").get(login) || (cleanEmail(login) && q("SELECT * FROM users WHERE email = ?").get(cleanEmail(login)));
  if (!user || !checkPw(String(req.body?.password || ""), user.pass)) return res.status(401).json({ error: "Wrong username or password" });
  if (user.disabled) return res.status(403).json({ error: "Account disabled" });
  startAuth(req, res, user);
  res.json({ user: pub(user) });
});

app.post("/api/logout", (req, res) => {
  const token = cookieOf(req.headers.cookie, COOKIE);
  if (token) q("DELETE FROM auth WHERE token = ?").run(token);
  res.setHeader("Set-Cookie", `${COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`);
  res.json({ ok: true });
});

app.get("/api/config", (req, res) => {
  const user = userFromCookie(req.headers.cookie);
  res.json({
    user: user ? pub(user) : null,
    hasUsers: q("SELECT COUNT(*) AS n FROM users").get().n > 0,
    allowSignup: setting("allow_signup") === "1",
    maxSessionSeconds: num("max_session_seconds"),
    lucyModel: setting("lucy_model"), lucyFast: setting("lucy_fast") === "1",
    engines: { lucy: !!setting("decart_key"), eden: !!setting("fal_key"), voice: !!setting("elevenlabs_key") },
    canReset: !!setting("smtp_host"),
    rates: { lucy: num("rate_lucy"), "eden-5b": num("rate_eden_5b"), "eden-14b": num("rate_eden_14b"), firstFrame: num("first_frame_fee"), voice: num("rate_voice") },
  });
});

// ---------- billing ----------
const FREE_CONNECT_MS = 20000;
const GRACE_MS = 45000;   // a session with no heartbeat for this long is closed

function debit(userId, amount, reason) {
  const u = q("SELECT balance FROM users WHERE id = ?").get(userId);
  const take = r2(Math.min(Math.max(0, amount), Math.max(0, u.balance)));
  if (take > 0) {
    q("UPDATE users SET balance = ROUND(balance - ?, 2) WHERE id = ?").run(take, userId);
    if (reason) q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").run(userId, -take, reason, now());
  }
  return { took: take, balance: q("SELECT balance FROM users WHERE id = ?").get(userId).balance };
}

// Charge a session up to `until` (server clock) and optionally close it.
function settle(s, until, close) {
  const capEnd = s.started_at + s.cap_seconds * 1000;
  // never marked live: the first 20s (connecting) are free, so a failed connection costs nothing
  const neverLive = s.charged === 0 && s.last_beat === s.started_at;
  const from = neverLive ? Math.min(until, s.started_at + FREE_CONNECT_MS) : s.last_beat;
  const end = Math.max(from, Math.min(until, capEnd));
  const { took, balance } = debit(s.user_id, ((end - from) / 1000) * s.rate, null);
  const finished = close || balance <= 0 || end >= capEnd;
  q("UPDATE sessions SET last_beat = ?, charged = ROUND(charged + ?, 2), ended_at = ? WHERE id = ?").run(end, took, finished ? end : null, s.id);
  if (finished) {
    const total = q("SELECT charged FROM sessions WHERE id = ?").get(s.id).charged;
    if (total > 0) q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)")
      .run(s.user_id, -total, `Session ${s.engine} (${Math.round((end - s.started_at) / 1000)}s)`, now());
  }
  return { balance: r2(balance), ended: finished };
}
const balanceOf = (userId) => r2(q("SELECT balance FROM users WHERE id = ?").get(userId).balance);
const openSession = (userId) => q("SELECT * FROM sessions WHERE user_id = ? AND ended_at IS NULL").get(userId);
const sessionFor = (userId, id) => q("SELECT * FROM sessions WHERE id = ? AND user_id = ? AND ended_at IS NULL").get(String(id || ""), userId);

setInterval(() => {
  const t = now();
  for (const s of q("SELECT * FROM sessions WHERE ended_at IS NULL AND last_beat < ?").all(t - GRACE_MS)) settle(s, s.last_beat + GRACE_MS, true);
  q("DELETE FROM auth WHERE expires_at < ?").run(t);
}, 15000).unref();

async function mintDecartToken(req, seconds) {
  const client = createDecartClient({ apiKey: setting("decart_key") });
  const origin = req.headers.origin;
  const token = await client.tokens.create({
    expiresIn: 60,
    ...(origin ? { allowedOrigins: [origin] } : {}),
    constraints: { realtime: { maxSessionDuration: Math.max(1, Math.floor(seconds)) } },
  });
  return token.apiKey;
}

app.post("/api/session/start", requireUser, (req, res) => {
  const engine = String(req.body?.engine || "");
  const def = ENGINES[engine];
  if (!def) return res.status(400).json({ error: "Unknown engine" });
  if (!setting(def.provider === "fal" ? "fal_key" : "decart_key")) return res.status(503).json({ error: "This engine is not set up yet" });

  const old = openSession(req.user.id);
  if (old) settle(old, now(), true);

  const rate = Math.max(0, def.rate());
  const balance = balanceOf(req.user.id);
  const max = Math.max(10, Math.floor(num("max_session_seconds")));
  const cap = rate > 0 ? Math.min(max, Math.floor(balance / rate)) : max;
  if (cap < 5) return res.status(402).json({ error: "Not enough balance" });

  const id = crypto.randomBytes(16).toString("hex"), t = now();
  q("INSERT INTO sessions (id, user_id, engine, rate, cap_seconds, started_at, last_beat) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .run(id, req.user.id, engine, rate, cap, t, t);
  res.json({ id, rate, maxSeconds: cap, balance });
});

// Billing starts when the video is actually live (at most 20s after start), not while connecting.
app.post("/api/session/live", requireUser, (req, res) => {
  const s = sessionFor(req.user.id, req.body?.id);
  if (s && s.charged === 0 && s.last_beat === s.started_at)
    q("UPDATE sessions SET last_beat = ? WHERE id = ?").run(Math.min(now(), s.started_at + FREE_CONNECT_MS) + 1, s.id);
  res.json({ ok: !!s });
});

app.post("/api/session/beat", requireUser, (req, res) => {
  const s = sessionFor(req.user.id, req.body?.id);
  res.json(s ? settle(s, now(), false) : { ended: true, balance: balanceOf(req.user.id) });
});

app.post("/api/session/stop", requireUser, (req, res) => {
  let id = req.body?.id;
  if (typeof req.body === "string") { try { id = JSON.parse(req.body).id; } catch { id = ""; } }
  const s = sessionFor(req.user.id, id);
  res.json(s ? settle(s, now(), true) : { ended: true, balance: balanceOf(req.user.id) });
});

// Decart: short-lived client token, capped to what is left of the paid session
app.post("/api/decart-token", requireUser, async (req, res) => {
  const s = sessionFor(req.user.id, req.body?.id);
  if (!s || s.engine !== "lucy") return res.status(403).json({ error: "No active Lucy session" });
  const left = s.cap_seconds - (now() - s.started_at) / 1000;
  if (left < 1) return res.status(402).json({ error: "Session time used up" });
  try { res.json({ apiKey: await mintDecartToken(req, left) }); }
  catch (e) { console.error("decart token:", e?.message || e); res.status(502).json({ error: "Could not get a Lucy token — check the Decart key in Admin" }); }
});

// ---------- fal: proxy for realtime (Eden Live) — only with an active paid Eden session ----------
const falConfig = falProxy.resolveProxyConfig({
  allowedEndpoints: [
    "vast/eden-live-14b-video", "vast/eden-live-14b-video/**",
    "vast/eden-live-5b-video", "vast/eden-live-5b-video/**",
  ],
  allowUnauthorizedRequests: false,
  isAuthenticated: async (b) => {
    const user = userFromCookie([].concat(b.getHeader("cookie") || "").join("; "));
    const s = user && openSession(user.id);
    return !!s && ENGINES[s.engine]?.provider === "fal";
  },
  resolveFalAuth: async () => (setting("fal_key") ? `Key ${setting("fal_key")}` : undefined),
});
app.all(["/api/fal/proxy", "/api/fal/proxy/*"], async (req, res) => {
  try {
    await falProxy.handleRequest({
      id: "express",
      method: req.method,
      getRequestBody: async () => JSON.stringify(req.body ?? {}),
      getHeaders: () => req.headers,
      getHeader: (name) => req.headers[name],
      sendHeader: (name, value) => res.setHeader(name, value),
      respondWith: (status, data) => res.status(status).json(data),
      sendResponse: async (upstream) => { res.status(upstream.status); res.end(Buffer.from(await upstream.arrayBuffer())); },
    }, falConfig);
  } catch (e) {
    console.error("fal proxy:", e?.message || e);
    if (!res.headersSent) res.status(502).json({ error: "fal proxy error" });
  }
});

// ---------- fal: Eden "target look" first frame (flat fee) ----------
const isImg = (s) => typeof s === "string" && /^data:image\/(jpeg|png|webp);base64,/.test(s);
app.post("/api/first-frame", requireUser, async (req, res) => {
  const s = openSession(req.user.id);
  if (!s || ENGINES[s.engine]?.provider !== "fal") return res.status(403).json({ error: "No active Eden session" });
  const { frame, character, prompt = "", width = 832, height = 480 } = req.body || {};
  if (!isImg(frame) || !isImg(character)) return res.status(400).json({ error: "frame and character must be image data URIs" });
  const fee = Math.max(0, num("first_frame_fee"));
  if (balanceOf(req.user.id) < fee) return res.status(402).json({ error: "Not enough balance" });

  const w = Math.min(1280, Math.max(256, Number(width) | 0)), h = Math.min(1280, Math.max(256, Number(height) | 0));
  const instruction =
    "Replace the person in the first image with the character from the second image. " +
    "Keep the first image's exact pose, head position, framing, camera angle and background. " + String(prompt).slice(0, 600);
  try {
    const r = await fetch(`https://fal.run/${setting("first_frame_model")}`, {
      method: "POST",
      headers: { Authorization: `Key ${setting("fal_key")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: instruction, image_urls: [frame, character], image_size: { width: w, height: h }, num_images: 1, output_format: "jpeg" }),
    });
    const data = await r.json().catch(() => ({}));
    const url = data?.images?.[0]?.url;
    if (!r.ok || !url) {
      console.error("first-frame:", r.status, JSON.stringify(data).slice(0, 400));
      return res.status(502).json({ error: "Could not build the character frame — check the fal key in Admin" });
    }
    const { balance } = debit(req.user.id, fee, fee > 0 ? "Character frame" : null);
    res.json({ url, balance: r2(balance) });
  } catch (e) {
    console.error("first-frame:", e?.message || e);
    res.status(502).json({ error: "Could not build the character frame" });
  }
});

// ---------- email ----------
async function sendMail(to, subject, text) {
  if (!setting("smtp_host")) throw new Error("Email is not set up");
  const port = Number(setting("smtp_port")) || 587;
  const transport = nodemailer.createTransport({
    host: setting("smtp_host"), port, secure: port === 465,
    ...(setting("smtp_user") ? { auth: { user: setting("smtp_user"), pass: setting("smtp_pass") } } : {}),
    connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 15000,
  });
  await transport.sendMail({ from: setting("smtp_from") || setting("smtp_user"), to, subject, text });
}
const siteUrl = (req) => setting("site_url") || `${req.protocol}://${req.get("host")}`;
const sha = (v) => crypto.createHash("sha256").update(v).digest("hex");

app.post("/api/password/forgot", async (req, res) => {
  if (limited(req, "forgot", 5, 3600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  if (!setting("smtp_host")) return res.status(503).json({ error: "Password reset by email is not available. Ask the admin to reset it." });
  const login = String(req.body?.login || "").trim();
  const user = q("SELECT * FROM users WHERE username = ?").get(login) || (cleanEmail(login) && q("SELECT * FROM users WHERE email = ?").get(cleanEmail(login)));
  if (user?.email && !user.disabled) {
    const token = crypto.randomBytes(32).toString("hex");
    q("DELETE FROM resets WHERE user_id = ?").run(user.id);
    q("INSERT INTO resets (token_hash, user_id, expires_at) VALUES (?, ?, ?)").run(sha(token), user.id, now() + 3600000);
    sendMail(user.email, "Reset your LiveChar password",
      `Hi ${user.username},\n\nUse this link to set a new password (valid for 1 hour):\n${siteUrl(req)}/reset?token=${token}\n\nIf you didn't ask for this, ignore this email.`)
      .catch((e) => console.error("reset email:", e?.message || e));
  }
  res.json({ ok: true });   // same answer whether or not the account exists
});
app.post("/api/password/reset", (req, res) => {
  if (limited(req, "reset", 10, 3600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const password = String(req.body?.password || "");
  if (password.length < 6 || password.length > 200) return res.status(400).json({ error: "Password must be at least 6 characters" });
  const row = q("SELECT * FROM resets WHERE token_hash = ? AND expires_at > ?").get(sha(String(req.body?.token || "")), now());
  if (!row) return res.status(400).json({ error: "This reset link is invalid or has expired" });
  q("UPDATE users SET pass = ? WHERE id = ?").run(hashPw(password), row.user_id);
  q("DELETE FROM resets WHERE user_id = ?").run(row.user_id);
  q("DELETE FROM auth WHERE user_id = ?").run(row.user_id);
  res.json({ ok: true });
});

// ---------- account ----------
app.get("/api/account", requireUser, (req, res) => {
  res.json({
    user: pub(req.user),
    sessions: q("SELECT engine, started_at, ended_at, last_beat, charged FROM sessions WHERE user_id = ? ORDER BY started_at DESC LIMIT 30").all(req.user.id),
    ledger: q("SELECT delta, reason, created_at FROM ledger WHERE user_id = ? ORDER BY id DESC LIMIT 50").all(req.user.id),
    orders: q("SELECT id, package_name, seconds, network, amount, status, txid, created_at FROM orders WHERE user_id = ? AND status != 'cancelled' ORDER BY created_at DESC LIMIT 20").all(req.user.id),
  });
});
app.post("/api/account/password", requireUser, (req, res) => {
  const next = String(req.body?.next || "");
  if (!checkPw(String(req.body?.current || ""), req.user.pass)) return res.status(400).json({ error: "Current password is wrong" });
  if (next.length < 6 || next.length > 200) return res.status(400).json({ error: "New password must be at least 6 characters" });
  q("UPDATE users SET pass = ? WHERE id = ?").run(hashPw(next), req.user.id);
  q("DELETE FROM auth WHERE user_id = ? AND token != ?").run(req.user.id, cookieOf(req.headers.cookie, COOKIE));   // log out other devices
  res.json({ ok: true });
});
app.post("/api/account/email", requireUser, (req, res) => {
  const raw = String(req.body?.email || "").trim(), email = cleanEmail(raw);
  if (raw && !email) return res.status(400).json({ error: "That email address doesn't look right" });
  if (email && q("SELECT 1 FROM users WHERE email = ? AND id != ?").get(email, req.user.id)) return res.status(409).json({ error: "Email already in use" });
  q("UPDATE users SET email = ? WHERE id = ?").run(email || null, req.user.id);
  res.json({ ok: true, email });
});

function credit(userId, seconds, reason) {
  q("UPDATE users SET balance = ROUND(balance + ?, 2) WHERE id = ?").run(seconds, userId);
  q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").run(userId, seconds, reason, now());
  return balanceOf(userId);
}

// ---------- vouchers ----------
const CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const newCode = () => Array.from({ length: 3 }, () => Array.from(crypto.randomBytes(4), (b) => CODE_CHARS[b % CODE_CHARS.length]).join("")).join("-");

app.post("/api/vouchers/redeem", requireUser, (req, res) => {
  if (limited(req, "redeem", 10, 600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const code = String(req.body?.code || "").trim().toUpperCase();
  const v = q("SELECT * FROM vouchers WHERE code = ?").get(code);
  if (!v) return res.status(404).json({ error: "That code is not valid" });
  if (v.uses >= v.max_uses) return res.status(410).json({ error: "That code has already been used" });
  if (q("SELECT 1 FROM redemptions WHERE code = ? AND user_id = ?").get(code, req.user.id)) return res.status(409).json({ error: "You have already used this code" });
  q("INSERT INTO redemptions (code, user_id, created_at) VALUES (?, ?, ?)").run(code, req.user.id, now());
  q("UPDATE vouchers SET uses = uses + 1 WHERE code = ?").run(code);
  res.json({ seconds: v.seconds, balance: credit(req.user.id, v.seconds, `Voucher ${code}`) });
});

// ---------- packages + USDT orders ----------
const ORDER_TTL = 2 * 3600000;
const payAddress = (network) => setting(network === "bsc" ? "usdt_bsc_address" : "usdt_tron_address");
const chainOpts = () => ({ tronKey: setting("tron_api_key") });

app.get("/api/packages", requireUser, (_req, res) => {
  res.json({
    packages: q("SELECT id, name, seconds, price FROM packages WHERE active = 1 ORDER BY sort, price").all(),
    networks: Object.keys(NETWORKS).filter(payAddress).map((id) => ({ id, label: NETWORKS[id].label })),
  });
});

async function orderView(o) {
  return {
    id: o.id, package: o.package_name, seconds: o.seconds, network: o.network, networkLabel: NETWORKS[o.network].label,
    amount: o.amount, address: o.address, status: o.status, txid: o.txid || "", note: o.note || "", expiresAt: o.expires_at,
    qr: o.status === "pending" ? await QRCode.toDataURL(o.address, { margin: 1, width: 220 }) : "",
  };
}
app.get("/api/orders/current", requireUser, async (req, res) => {
  const o = q("SELECT * FROM orders WHERE user_id = ? AND status = 'pending' AND expires_at > ? ORDER BY created_at DESC").get(req.user.id, now());
  res.json({ order: o ? await orderView(o) : null });
});
app.post("/api/orders", requireUser, async (req, res) => {
  const pkg = q("SELECT * FROM packages WHERE id = ? AND active = 1").get(Number(req.body?.packageId));
  const network = String(req.body?.network || "");
  if (!pkg) return res.status(404).json({ error: "Package not found" });
  if (!NETWORKS[network] || !payAddress(network)) return res.status(400).json({ error: "That network is not available" });
  if (q("SELECT 1 FROM orders WHERE user_id = ? AND status = 'pending' AND txid IS NOT NULL").get(req.user.id))
    return res.status(409).json({ error: "You have a payment being checked. Wait for it to finish first." });
  q("UPDATE orders SET status = 'cancelled' WHERE user_id = ? AND status = 'pending'").run(req.user.id);

  // A unique amount per open order ties an on-chain payment to exactly one buyer.
  let amount = "";
  for (let i = 0; i < 200 && !amount; i++) {
    const a = (pkg.price + crypto.randomInt(1, 100) / 10000).toFixed(4);
    if (!q("SELECT 1 FROM orders WHERE network = ? AND amount = ? AND status = 'pending' AND expires_at > ?").get(network, a, now())) amount = a;
  }
  if (!amount) return res.status(503).json({ error: "Too many open orders right now, try again in a minute" });
  const id = crypto.randomBytes(12).toString("hex"), t = now();
  q("INSERT INTO orders (id, user_id, package_name, seconds, network, amount, address, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    .run(id, req.user.id, pkg.name, pkg.seconds, network, amount, payAddress(network), t, t + ORDER_TTL);
  res.json({ order: await orderView(q("SELECT * FROM orders WHERE id = ?").get(id)) });
});
app.post("/api/orders/:id/cancel", requireUser, (req, res) => {
  const r = q("UPDATE orders SET status = 'cancelled' WHERE id = ? AND user_id = ? AND status = 'pending' AND txid IS NULL").run(req.params.id, req.user.id);
  res.json({ ok: r.changes > 0 });
});

// Check an order's txid on-chain; credit once if it is the exact payment.
async function checkOrder(o) {
  const r = await findTransfer(o.network, o.txid, o.address, chainOpts());
  if (r.status === "pending") return { status: "pending" };
  const fail = (note) => { q("UPDATE orders SET txid = NULL, note = ? WHERE id = ? AND status = 'pending'").run(note, o.id); return { status: "invalid", error: note }; };
  if (r.status === "invalid") return fail(r.reason);
  if (r.units !== toUnits(o.amount, o.network)) return fail(`Amount does not match. This order needs exactly ${o.amount} USDT. Contact support with your transaction ID.`);
  if (r.timeMs < o.created_at - 600000) return fail("That transaction is older than this order");
  const done = q("UPDATE orders SET status = 'paid', paid_at = ?, note = NULL WHERE id = ? AND status = 'pending'").run(now(), o.id);
  if (done.changes) credit(o.user_id, o.seconds, `USDT top-up: ${o.package_name} (${o.amount} USDT, ${NETWORKS[o.network].label})`);
  return { status: "paid", balance: balanceOf(o.user_id) };
}
app.post("/api/orders/:id/confirm", requireUser, async (req, res) => {
  if (limited(req, "confirm", 30, 600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const o = q("SELECT * FROM orders WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!o) return res.status(404).json({ error: "Order not found" });
  if (o.status === "paid") return res.json({ status: "paid", balance: balanceOf(req.user.id) });
  if (o.status !== "pending") return res.status(410).json({ error: "This order was cancelled. Start a new one." });
  let txid = String(req.body?.txid || o.txid || "").trim();
  if (o.network === "tron") txid = txid.replace(/^0x/i, "");
  if (!isTxid(o.network, txid)) return res.status(400).json({ error: "That doesn't look like a transaction ID (hash)" });
  txid = txid.toLowerCase();
  if (q("SELECT 1 FROM orders WHERE network = ? AND txid = ? AND id != ?").get(o.network, txid, o.id)) return res.status(409).json({ error: "That transaction has already been used" });
  q("UPDATE orders SET txid = ?, note = NULL WHERE id = ?").run(txid, o.id);
  try { res.json(await checkOrder({ ...o, txid })); }
  catch (e) { console.error("order check:", e?.message || e); res.json({ status: "pending" }); }   // network hiccup: the background check retries
});
// Keep checking submitted payments in the background, so users don't have to stay on the page.
let checking = false;
setInterval(async () => {
  if (checking) return; checking = true;
  try {
    q("UPDATE orders SET status = 'expired' WHERE status = 'pending' AND txid IS NULL AND expires_at < ?").run(now());
    for (const o of q("SELECT * FROM orders WHERE status = 'pending' AND txid IS NOT NULL ORDER BY created_at LIMIT 5").all()) {
      try {
        const r = await checkOrder(o);
        if (r.status === "pending" && now() - o.created_at > 24 * 3600000) q("UPDATE orders SET status = 'expired', note = 'Not confirmed after 24h' WHERE id = ?").run(o.id);
      } catch (e) { console.error("order sweep:", e?.message || e); }
    }
  } finally { checking = false; }
}, 30000).unref();

// ---------- characters (per-user gallery + admin presets) ----------
const IMG_RE = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/;
function saveCharacter(userId, body) {
  const name = String(body?.name || "").trim().slice(0, 40) || "Character";
  const m = IMG_RE.exec(String(body?.image || ""));
  if (!m) return { error: "Add an image for the character" };
  const buf = Buffer.from(m[2], "base64");
  if (buf.length > 900000) return { error: "Image is too large" };
  const info = q("INSERT INTO characters (user_id, name, prompt, mime, created_at) VALUES (?, ?, ?, ?, ?)").run(userId, name, String(body?.prompt || "").slice(0, 2000), m[1], now());
  const id = Number(info.lastInsertRowid);
  fs.writeFileSync(path.join(CHAR_DIR, String(id)), buf);
  return { id };
}
app.get("/api/characters", requireUser, (req, res) => {
  res.json({ characters: q("SELECT id, name, prompt, user_id IS NULL AS preset FROM characters WHERE user_id = ? OR user_id IS NULL ORDER BY user_id IS NULL DESC, id DESC").all(req.user.id) });
});
app.post("/api/characters", requireUser, (req, res) => {
  if (q("SELECT COUNT(*) AS n FROM characters WHERE user_id = ?").get(req.user.id).n >= 30) return res.status(400).json({ error: "You can save up to 30 characters. Delete one first." });
  const r = saveCharacter(req.user.id, req.body);
  res.status(r.error ? 400 : 200).json(r);
});
app.get("/api/characters/:id/image", requireUser, (req, res) => {
  const c = q("SELECT * FROM characters WHERE id = ? AND (user_id = ? OR user_id IS NULL)").get(Number(req.params.id), req.user.id);
  const file = c && path.join(CHAR_DIR, String(c.id));
  if (!c || !fs.existsSync(file)) return res.status(404).end();
  res.setHeader("Content-Type", c.mime); res.setHeader("Cache-Control", "private, max-age=86400");
  fs.createReadStream(file).pipe(res);
});
app.delete("/api/characters/:id", requireUser, (req, res) => {
  const c = q("SELECT * FROM characters WHERE id = ?").get(Number(req.params.id));
  if (!c || !(c.user_id === req.user.id || (c.user_id === null && req.user.is_admin))) return res.status(404).json({ error: "Character not found" });
  q("DELETE FROM characters WHERE id = ?").run(c.id);
  fs.rmSync(path.join(CHAR_DIR, String(c.id)), { force: true });
  res.json({ ok: true });
});

// ---------- admin ----------
const NUMERIC = ["rate_voice", "rate_lucy", "rate_eden_5b", "rate_eden_14b", "first_frame_fee", "max_session_seconds", "signup_bonus"];
const mask = (v) => (v ? `••••${v.slice(-4)}` : "");
const TEXT_KEYS = ["usdt_bsc_address", "usdt_tron_address", "smtp_host", "smtp_port", "smtp_user", "smtp_from", "site_url"];
const SECRET_KEYS = ["fal_key", "decart_key", "elevenlabs_key", "tron_api_key", "smtp_pass"];

app.get("/api/admin/settings", requireAdmin, (_req, res) => {
  const out = { fal_key_hint: mask(setting("fal_key")), decart_key_hint: mask(setting("decart_key")), elevenlabs_key_hint: mask(setting("elevenlabs_key")), allow_signup: setting("allow_signup") === "1", lucy_fast: setting("lucy_fast") === "1", lucy_model: setting("lucy_model") };
  for (const k of NUMERIC) out[k] = num(k);
  for (const k of TEXT_KEYS) out[k] = setting(k);
  out.tron_api_key_hint = mask(setting("tron_api_key")); out.smtp_pass_hint = mask(setting("smtp_pass"));
  res.json(out);
});
app.post("/api/admin/settings", requireAdmin, (req, res) => {
  const b = req.body || {};
  for (const k of NUMERIC) if (b[k] !== undefined && b[k] !== "") {
    const n = Number(b[k]);
    if (!Number.isFinite(n) || n < 0) return res.status(400).json({ error: `Invalid value for ${k}` });
    setSetting(k, k === "max_session_seconds" ? Math.max(10, Math.floor(n)) : n);
  }
  if (b.usdt_bsc_address && !isBscAddress(String(b.usdt_bsc_address).trim())) return res.status(400).json({ error: "BSC address must be 0x followed by 40 hex characters" });
  if (b.usdt_tron_address && !isTronAddress(String(b.usdt_tron_address).trim())) return res.status(400).json({ error: "Tron address is not valid (check for a typo)" });
  if (b.site_url && !/^https?:\/\/[^\s/]+$/.test(String(b.site_url).trim().replace(/\/+$/, ""))) return res.status(400).json({ error: "Site URL should look like https://your-site.com" });
  for (const k of TEXT_KEYS) if (typeof b[k] === "string") {
    const v = b[k].trim().replace(k === "site_url" ? /\/+$/ : /$^/, "");
    q("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(k, v.slice(0, 300));   // may be cleared
  }
  for (const k of SECRET_KEYS) if (typeof b[k] === "string" && b[k].trim()) setSetting(k, b[k].trim());   // blank = keep current
  if (b.allow_signup !== undefined) setSetting("allow_signup", b.allow_signup ? "1" : "0");
  if (b.lucy_fast !== undefined) setSetting("lucy_fast", b.lucy_fast ? "1" : "0");
  if (typeof b.lucy_model === "string" && /^lucy[\w.-]{0,30}$/.test(b.lucy_model.trim())) setSetting("lucy_model", b.lucy_model.trim());
  res.json({ ok: true });
});

app.get("/api/admin/users", requireAdmin, (req, res) => {
  const s = `%${String(req.query.q || "").replace(/[%_]/g, "")}%`;
  res.json({
    users: q(`SELECT u.id, u.username, u.email, u.balance, u.is_admin, u.disabled, u.created_at,
                     (SELECT COALESCE(SUM(charged), 0) FROM sessions WHERE user_id = u.id) AS used
              FROM users u WHERE u.username LIKE ? OR u.email LIKE ? ORDER BY u.id DESC LIMIT 200`).all(s, s),
  });
});
app.post("/api/admin/users/:id/balance", requireAdmin, (req, res) => {
  const user = q("SELECT * FROM users WHERE id = ?").get(Number(req.params.id));
  const delta = r2(Number(req.body?.delta));
  if (!user) return res.status(404).json({ error: "User not found" });
  if (!Number.isFinite(delta) || delta === 0 || Math.abs(delta) > 1e8) return res.status(400).json({ error: "Enter a number of seconds" });
  const next = r2(Math.max(0, user.balance + delta));
  q("UPDATE users SET balance = ? WHERE id = ?").run(next, user.id);
  q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)")
    .run(user.id, r2(next - user.balance), `Admin (${req.user.username}): ${String(req.body?.note || "").slice(0, 120) || "adjustment"}`, now());
  res.json({ balance: next });
});
app.post("/api/admin/users/:id", requireAdmin, (req, res) => {
  const user = q("SELECT * FROM users WHERE id = ?").get(Number(req.params.id));
  if (!user) return res.status(404).json({ error: "User not found" });
  const b = req.body || {}, self = user.id === req.user.id;
  if (self && (b.disabled || b.is_admin === false)) return res.status(400).json({ error: "You can't disable or demote your own account" });
  if (typeof b.password === "string" && b.password && b.password.length < 6) return res.status(400).json({ error: "Password must be at least 6 characters" });
  if (b.disabled !== undefined) {
    q("UPDATE users SET disabled = ? WHERE id = ?").run(b.disabled ? 1 : 0, user.id);
    if (b.disabled) q("DELETE FROM auth WHERE user_id = ?").run(user.id);
  }
  if (b.is_admin !== undefined) q("UPDATE users SET is_admin = ? WHERE id = ?").run(b.is_admin ? 1 : 0, user.id);
  if (typeof b.password === "string" && b.password) {
    q("UPDATE users SET pass = ? WHERE id = ?").run(hashPw(b.password), user.id);
    if (!self) q("DELETE FROM auth WHERE user_id = ?").run(user.id);
  }
  res.json({ ok: true });
});
app.post("/api/admin/presets", requireAdmin, (req, res) => {
  const r = saveCharacter(null, req.body);
  res.status(r.error ? 400 : 200).json(r);
});
app.get("/api/admin/packages", requireAdmin, (_req, res) => res.json({ packages: q("SELECT * FROM packages ORDER BY sort, price").all() }));
app.post("/api/admin/packages", requireAdmin, (req, res) => {
  const b = req.body || {}, name = String(b.name || "").trim().slice(0, 40);
  const seconds = Math.floor(Number(b.seconds)), price = Math.round(Number(b.price) * 100) / 100;
  if (!name) return res.status(400).json({ error: "Give the package a name" });
  if (!(seconds > 0) || seconds > 1e8) return res.status(400).json({ error: "Seconds must be more than 0" });
  if (!(price > 0) || price > 1e6) return res.status(400).json({ error: "Price must be more than 0" });
  if (b.id) q("UPDATE packages SET name = ?, seconds = ?, price = ?, active = ? WHERE id = ?").run(name, seconds, price, b.active === false ? 0 : 1, Number(b.id));
  else q("INSERT INTO packages (name, seconds, price) VALUES (?, ?, ?)").run(name, seconds, price);
  res.json({ ok: true });
});
app.delete("/api/admin/packages/:id", requireAdmin, (req, res) => { q("DELETE FROM packages WHERE id = ?").run(Number(req.params.id)); res.json({ ok: true }); });

app.get("/api/admin/vouchers", requireAdmin, (_req, res) => res.json({ vouchers: q("SELECT * FROM vouchers ORDER BY created_at DESC, code LIMIT 300").all() }));
app.post("/api/admin/vouchers", requireAdmin, (req, res) => {
  const b = req.body || {};
  const seconds = Math.floor(Number(b.seconds)), count = Math.floor(Number(b.count) || 1), maxUses = Math.floor(Number(b.maxUses) || 1);
  if (!(seconds > 0) || seconds > 1e8) return res.status(400).json({ error: "Seconds must be more than 0" });
  if (!(count >= 1 && count <= 200)) return res.status(400).json({ error: "Make between 1 and 200 codes at a time" });
  if (!(maxUses >= 1 && maxUses <= 100000)) return res.status(400).json({ error: "Uses per code must be at least 1" });
  const codes = [];
  while (codes.length < count) {
    const code = newCode();
    if (q("SELECT 1 FROM vouchers WHERE code = ?").get(code)) continue;
    q("INSERT INTO vouchers (code, seconds, max_uses, note, created_at) VALUES (?, ?, ?, ?, ?)").run(code, seconds, maxUses, String(b.note || "").slice(0, 80), now());
    codes.push(code);
  }
  res.json({ codes });
});
app.delete("/api/admin/vouchers/:code", requireAdmin, (req, res) => { q("DELETE FROM vouchers WHERE code = ?").run(String(req.params.code).toUpperCase()); res.json({ ok: true }); });

app.get("/api/admin/orders", requireAdmin, (_req, res) => {
  res.json({ orders: q(`SELECT o.id, o.package_name, o.seconds, o.network, o.amount, o.status, o.txid, o.note, o.created_at, u.username
                        FROM orders o JOIN users u ON u.id = o.user_id WHERE o.status != 'cancelled' ORDER BY o.created_at DESC LIMIT 60`).all() });
});
// Manual approval, e.g. the buyer sent the wrong amount and you have checked your wallet yourself.
app.post("/api/admin/orders/:id/approve", requireAdmin, (req, res) => {
  const o = q("SELECT * FROM orders WHERE id = ?").get(req.params.id);
  if (!o) return res.status(404).json({ error: "Order not found" });
  const done = q("UPDATE orders SET status = 'paid', paid_at = ?, note = ? WHERE id = ? AND status != 'paid'").run(now(), `Approved by ${req.user.username}`, o.id);
  if (!done.changes) return res.status(409).json({ error: "Order is already paid" });
  credit(o.user_id, o.seconds, `USDT top-up: ${o.package_name} (approved by ${req.user.username})`);
  res.json({ ok: true });
});
app.post("/api/admin/test-email", requireAdmin, async (req, res) => {
  const to = cleanEmail(req.body?.to) || req.user.email;
  if (!to) return res.status(400).json({ error: "Enter an address to send the test to" });
  try { await sendMail(to, "LiveChar test email", "Your LiveChar email settings work."); res.json({ ok: true, to }); }
  catch (e) { res.status(502).json({ error: `Email failed: ${e?.message || e}` }); }
});

app.get("/api/admin/activity", requireAdmin, (_req, res) => {
  res.json({
    sessions: q(`SELECT s.engine, s.rate, s.started_at, s.ended_at, s.last_beat, s.charged, u.username
                 FROM sessions s JOIN users u ON u.id = s.user_id ORDER BY s.started_at DESC LIMIT 50`).all(),
    ledger: q(`SELECT l.delta, l.reason, l.created_at, u.username
               FROM ledger l JOIN users u ON u.id = l.user_id ORDER BY l.id DESC LIMIT 50`).all(),
    totals: q(`SELECT (SELECT COUNT(*) FROM users) AS users, (SELECT COALESCE(SUM(balance), 0) FROM users) AS balance,
                      (SELECT COALESCE(SUM(charged), 0) FROM sessions) AS used,
                      (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL) AS live`).get(),
  });
});

// ---------- voice: ElevenLabs voice changer (natural, speech-to-speech) ----------
// The app splits the mic at short pauses and posts each phrase (16 kHz 16-bit mono PCM, up to 8 s).
// The server converts it with the user's chosen voice and streams the new voice back (same format).
// Billed per second of speech at rate_voice, gathered into one history line per burst of talking.
const XI = "https://api.elevenlabs.io/v1";
let voiceCache = { at: 0, list: [] };
const voiceUse = new Map();   // userId -> { secs, last }
app.get("/api/voices", requireUser, async (_req, res) => {
  const key = setting("elevenlabs_key");
  if (!key) return res.status(503).json({ error: "Voice is not set up yet" });
  if (Date.now() - voiceCache.at > 10 * 60 * 1000 || !voiceCache.list.length) {
    try {
      const r = await fetch(`${XI}/voices`, { headers: { "xi-api-key": key } });
      const j = await r.json();
      if (!r.ok) return res.status(502).json({ error: `ElevenLabs: ${j?.detail?.message || j?.detail || r.status}` });
      voiceCache = { at: Date.now(), list: (j.voices || []).map((v) => ({
        id: v.voice_id, name: v.name, category: v.category || "",
        gender: v.labels?.gender || "", accent: v.labels?.accent || "", age: v.labels?.age || "",
        description: v.labels?.description || v.labels?.descriptive || v.description || "", preview: v.preview_url || "",
      })) };
    } catch (e) { return res.status(502).json({ error: "Can't reach ElevenLabs" }); }
  }
  res.json({ voices: voiceCache.list });
});
app.post("/api/voice/convert", requireUser, express.raw({ type: "application/octet-stream", limit: "400kb" }), async (req, res) => {
  const key = setting("elevenlabs_key");
  if (!key) return res.status(503).json({ error: "Voice is not set up yet" });
  const voice = String(req.query.voice || "");
  if (!/^[A-Za-z0-9]{8,40}$/.test(voice)) return res.status(400).json({ error: "Pick a voice" });
  const pcm = req.body;
  if (!Buffer.isBuffer(pcm) || pcm.length < 3200 || pcm.length > 16000 * 2 * 8 || pcm.length % 2) {
    return res.status(400).json({ error: "A phrase must be 0.1–8 seconds of 16 kHz audio" });
  }
  const secs = pcm.length / 2 / 16000, cost = secs * num("rate_voice");
  if (balanceOf(req.user.id) < Math.min(cost, 1)) return res.status(402).json({ error: "Balance finished — top up to continue" });
  const form = new FormData();
  form.set("model_id", "eleven_multilingual_sts_v2");
  form.set("file_format", "pcm_s16le_16");
  form.set("remove_background_noise", "false");
  form.append("audio", new Blob([pcm], { type: "application/octet-stream" }), "phrase.pcm");
  let r;
  try {
    // ElevenLabs serves the same voice changer under both names; try the documented one first
    for (const path of ["speech-to-speech", "voice-changer"]) {
      r = await fetch(`${XI}/${path}/${voice}/stream?output_format=pcm_16000&optimize_streaming_latency=3`, {
        method: "POST", headers: { "xi-api-key": key }, body: form,
      });
      if (r.status !== 404) break;
    }
  } catch { return res.status(502).json({ error: "Can't reach ElevenLabs" }); }
  if (!r.ok || !r.body) {
    const t = await r.text().catch(() => "");
    let msg = t.slice(0, 200);
    try { const j = JSON.parse(t); msg = j?.detail?.message || j?.detail || msg; } catch {}
    return res.status(r.status === 401 ? 503 : 502).json({ error: `ElevenLabs: ${msg}` });
  }
  debit(req.user.id, cost, null);
  const u = voiceUse.get(req.user.id) || { secs: 0, last: 0 };
  u.secs += cost; u.last = now(); voiceUse.set(req.user.id, u);
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Accel-Buffering", "no");
  res.setHeader("X-Balance", String(balanceOf(req.user.id)));
  const reader = r.body.getReader();
  try {
    for (;;) { const { value, done } = await reader.read(); if (done) break; res.write(Buffer.from(value)); }
  } catch {}
  res.end();
});
setInterval(() => {   // one history line per burst of talking
  for (const [id, u] of voiceUse) if (now() - u.last > 30000) {
    if (u.secs > 0) q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").run(id, -r2(u.secs), "Voice changer", now());
    voiceUse.delete(id);
  }
}, 10000).unref();

// ---------- share live: the iOS app streams its output to a watch link ----------
// Each user has one fixed link (/watch/<id>). The app POSTs H.264 packets; viewers (watch page, Chrome
// extension) keep one streaming GET open and get them as they arrive. Plain HTTP both ways, so it works
// behind any Nginx without extra config (responses carry X-Accel-Buffering: no).
// Packet: [u32 length][u8 flags][u64 timestamp µs][data]. flags 1 = keyframe, 2 = stream ended,
// 4 = audio (16 kHz s16le mono PCM of the new voice, same clock as the video); otherwise data is H.264 Annex B.
// A zero-length packet is a keep-alive.
db.exec("CREATE TABLE IF NOT EXISTS shares (user_id INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE)");
const SHARE_IDLE_MS = 20000, VIEWER_MAX_BACKLOG = 8 << 20, GOP_MAX_BYTES = 6 << 20;
const live = new Map();   // share id -> { viewers:Set<res>, gop:Buffer[], gopBytes, live, last, userId }
const shareIdOf = (userId) => {
  let row = q("SELECT id FROM shares WHERE user_id = ?").get(userId);
  if (!row) { row = { id: crypto.randomBytes(9).toString("base64url") }; q("INSERT INTO shares (user_id, id) VALUES (?, ?)").run(userId, row.id); }
  return row.id;
};
const channel = (id) => { let c = live.get(id); if (!c) { c = { viewers: new Set(), gop: [], gopBytes: 0, live: false, last: 0 }; live.set(id, c); } return c; };
const frameOf = (payload) => { const h = Buffer.alloc(4); h.writeUInt32BE(payload.length); return [h, payload]; };
function sendTo(res, bufs) {
  if (res.writableLength > VIEWER_MAX_BACKLOG) { res.destroy(); return; }   // viewer too slow: drop it, it reconnects
  for (const b of bufs) res.write(b);
}
function endedPacket() { const p = Buffer.alloc(9); p[0] = 2; return p; }
function stopChannel(c) {
  if (!c.live) return;
  c.live = false; c.gop = []; c.gopBytes = 0;
  const pkt = frameOf(endedPacket());
  for (const v of c.viewers) sendTo(v, pkt);
}
const shareUrl = (req, id) => `${(setting("site_url") || `${req.protocol}://${req.get("host")}`).replace(/\/+$/, "")}/watch/${id}`;
const shareCors = (res) => { res.setHeader("Access-Control-Allow-Origin", "*"); res.setHeader("Cache-Control", "no-store"); };

app.get("/api/share", requireUser, (req, res) => {
  const id = shareIdOf(req.user.id), c = live.get(id);
  res.json({ id, url: shareUrl(req, id), live: !!c?.live, viewers: c?.viewers.size || 0 });
});
app.post("/api/share/reset", requireUser, (req, res) => {
  const old = q("SELECT id FROM shares WHERE user_id = ?").get(req.user.id);
  if (old) { const c = live.get(old.id); if (c) { stopChannel(c); for (const v of c.viewers) v.end(); live.delete(old.id); } }
  q("DELETE FROM shares WHERE user_id = ?").run(req.user.id);
  const id = shareIdOf(req.user.id);
  res.json({ id, url: shareUrl(req, id) });
});
app.post("/api/share/frames", requireUser, express.raw({ type: "application/octet-stream", limit: "8mb" }), (req, res) => {
  const id = shareIdOf(req.user.id), c = channel(id), body = req.body;
  if (!Buffer.isBuffer(body)) return res.status(400).json({ error: "Send application/octet-stream" });
  c.live = true; c.last = now(); c.userId = req.user.id;
  const out = [];
  for (let o = 0; o + 4 <= body.length;) {
    const len = body.readUInt32BE(o); o += 4;
    if (len < 9 || o + len > body.length) break;
    const payload = body.subarray(o, o + len); o += len;
    if (payload[0] & 2) { stopChannel(c); continue; }
    // keep everything since the last keyframe, so a viewer who joins now starts with a clean picture
    const copy = Buffer.from(payload);
    if (!(copy[0] & 4)) {   // video: keep since the last keyframe (audio, flag 4, is only passed on live)
      if (copy[0] & 1) { c.gop = []; c.gopBytes = 0; }
      if (c.gopBytes + copy.length <= GOP_MAX_BYTES) { c.gop.push(copy); c.gopBytes += copy.length; }
    }
    out.push(...frameOf(copy));
  }
  if (out.length) for (const v of c.viewers) sendTo(v, out);
  res.json({ viewers: c.viewers.size });
});
app.post("/api/share/stop", requireUser, (req, res) => {
  const c = live.get(shareIdOf(req.user.id));
  if (c) stopChannel(c);
  res.json({ ok: true });
});
app.options("/api/share/:id/stream", (_req, res) => { shareCors(res); res.setHeader("Access-Control-Allow-Methods", "GET"); res.end(); });
app.get("/api/share/:id/info", (req, res) => {
  shareCors(res);
  const ok = q("SELECT 1 FROM shares WHERE id = ?").get(String(req.params.id));
  if (!ok) return res.status(404).json({ error: "Unknown link" });
  const c = live.get(String(req.params.id));
  res.json({ live: !!c?.live, viewers: c?.viewers.size || 0 });
});
app.get("/api/share/:id/stream", (req, res) => {
  shareCors(res);
  const id = String(req.params.id);
  if (!q("SELECT 1 FROM shares WHERE id = ?").get(id)) return res.status(404).json({ error: "Unknown link" });
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();
  req.socket.setNoDelay(true);
  const c = channel(id);
  if (c.live && c.gop.length) sendTo(res, c.gop.flatMap(frameOf));
  c.viewers.add(res);
  const keep = setInterval(() => res.write(Buffer.alloc(4)), 10000);
  res.on("close", () => { clearInterval(keep); c.viewers.delete(res); });
});
app.get("/watch/:id", (_req, res) => { res.setHeader("Cache-Control", "no-cache"); res.sendFile(path.join(__dirname, "public", "watch.html")); });
setInterval(() => {
  const t = now();
  for (const [id, c] of live) {
    if (c.live && t - c.last > SHARE_IDLE_MS) stopChannel(c);
    if (!c.live && !c.viewers.size) live.delete(id);
  }
}, 5000).unref();

// ---------- static ----------
// no-cache = always revalidate (ETag), so UI updates show up immediately
app.use(express.static(path.join(__dirname, "public"), { extensions: ["html"], setHeaders: (res) => res.setHeader("Cache-Control", "no-cache") }));

app.listen(PORT, () => {
  const n = q("SELECT COUNT(*) AS n FROM users").get().n;
  console.log(`LiveChar on :${PORT}  users=${n}${n ? "" : "  (first account to register becomes admin)"}`);
});
