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
const q = (sql) => db.prepare(sql);
const now = () => Date.now();
const r2 = (n) => Math.round(n * 100) / 100;

// ---------- settings (admin-editable; .env is only a fallback for the keys) ----------
const DEFAULTS = {
  fal_key: "", decart_key: "",
  rate_lucy: "1", rate_eden_5b: "1", rate_eden_14b: "1", lucy_fast: "1",
  first_frame_fee: "0", max_session_seconds: "300", signup_bonus: "0", allow_signup: "1",
  lucy_model: "lucy-latest", first_frame_model: "fal-ai/flux-2/klein/9b/edit",
};
const realKey = (v) => (v && !/^YOUR_/i.test(v) ? v : "");
function setting(key) {
  const row = q("SELECT value FROM settings WHERE key = ?").get(key);
  if (row && row.value !== "") return row.value;
  if (key === "fal_key") return realKey(process.env.FAL_KEY);
  if (key === "decart_key") return realKey(process.env.DECART_API_KEY);
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
const pub = (u) => ({ id: u.id, username: u.username, isAdmin: !!u.is_admin, balance: r2(u.balance) });

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

  const bonus = first ? 0 : Math.max(0, num("signup_bonus"));
  const info = q("INSERT INTO users (username, pass, is_admin, balance, created_at) VALUES (?, ?, ?, ?, ?)")
    .run(username, hashPw(password), first ? 1 : 0, bonus, now());   // first account = admin
  const id = Number(info.lastInsertRowid);
  if (bonus > 0) q("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").run(id, bonus, "Signup bonus", now());
  const user = q("SELECT * FROM users WHERE id = ?").get(id);
  startAuth(req, res, user);
  res.json({ user: pub(user) });
});

app.post("/api/login", (req, res) => {
  if (limited(req, "login", 15, 600000)) return res.status(429).json({ error: "Too many attempts, try later" });
  const user = q("SELECT * FROM users WHERE username = ?").get(String(req.body?.username || "").trim());
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
    engines: { lucy: !!setting("decart_key"), eden: !!setting("fal_key") },
    rates: { lucy: num("rate_lucy"), "eden-5b": num("rate_eden_5b"), "eden-14b": num("rate_eden_14b"), firstFrame: num("first_frame_fee") },
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

// ---------- admin ----------
const NUMERIC = ["rate_lucy", "rate_eden_5b", "rate_eden_14b", "first_frame_fee", "max_session_seconds", "signup_bonus"];
const mask = (v) => (v ? `••••${v.slice(-4)}` : "");

app.get("/api/admin/settings", requireAdmin, (_req, res) => {
  const out = { fal_key_hint: mask(setting("fal_key")), decart_key_hint: mask(setting("decart_key")), allow_signup: setting("allow_signup") === "1", lucy_fast: setting("lucy_fast") === "1", lucy_model: setting("lucy_model") };
  for (const k of NUMERIC) out[k] = num(k);
  res.json(out);
});
app.post("/api/admin/settings", requireAdmin, (req, res) => {
  const b = req.body || {};
  for (const k of NUMERIC) if (b[k] !== undefined && b[k] !== "") {
    const n = Number(b[k]);
    if (!Number.isFinite(n) || n < 0) return res.status(400).json({ error: `Invalid value for ${k}` });
    setSetting(k, k === "max_session_seconds" ? Math.max(10, Math.floor(n)) : n);
  }
  for (const k of ["fal_key", "decart_key"]) if (typeof b[k] === "string" && b[k].trim()) setSetting(k, b[k].trim());   // blank = keep current
  if (b.allow_signup !== undefined) setSetting("allow_signup", b.allow_signup ? "1" : "0");
  if (b.lucy_fast !== undefined) setSetting("lucy_fast", b.lucy_fast ? "1" : "0");
  if (typeof b.lucy_model === "string" && /^lucy[\w.-]{0,30}$/.test(b.lucy_model.trim())) setSetting("lucy_model", b.lucy_model.trim());
  res.json({ ok: true });
});

app.get("/api/admin/users", requireAdmin, (req, res) => {
  const s = `%${String(req.query.q || "").replace(/[%_]/g, "")}%`;
  res.json({
    users: q(`SELECT u.id, u.username, u.balance, u.is_admin, u.disabled, u.created_at,
                     (SELECT COALESCE(SUM(charged), 0) FROM sessions WHERE user_id = u.id) AS used
              FROM users u WHERE u.username LIKE ? ORDER BY u.id DESC LIMIT 200`).all(s),
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

// ---------- static ----------
// no-cache = always revalidate (ETag), so UI updates show up immediately
app.use(express.static(path.join(__dirname, "public"), { extensions: ["html"], setHeaders: (res) => res.setHeader("Cache-Control", "no-cache") }));

app.listen(PORT, () => {
  const n = q("SELECT COUNT(*) AS n FROM users").get().n;
  console.log(`LiveChar on :${PORT}  users=${n}${n ? "" : "  (first account to register becomes admin)"}`);
});
