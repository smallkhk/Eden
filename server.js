// LiveChar — live AI character changer
// Engines: Decart Lucy (direct) + VAST Eden Live 14B / 5B (fal.ai)
import express from "express";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createDecartClient } from "@decartai/sdk";
import falProxy from "@fal-ai/server-proxy";

try { process.loadEnvFile(); } catch { /* no .env file — use real env */ }

const {
  PORT = 3000,
  FAL_KEY = "",
  DECART_API_KEY = "",
  APP_PASSWORD = "",
  MAX_SESSION_SECONDS = "300",
  LUCY_MODEL = "lucy-latest",
  FIRST_FRAME_MODEL = "fal-ai/flux-2/klein/9b/edit",
} = process.env;

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.set("trust proxy", 1);
app.use(express.json({ limit: "12mb" }));

// ---------- access gate (single shared password) ----------
const COOKIE = "lc_auth";
const sign = (v) => crypto.createHmac("sha256", APP_PASSWORD || "open").update(v).digest("hex");
const GOOD = sign("livechar-session");

function cookieOf(req, name) {
  const m = (req.headers.cookie || "").match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? m[1] : "";
}
function isAuthed(req) {
  if (!APP_PASSWORD) return true;
  const c = cookieOf(req, COOKIE);
  return c.length === GOOD.length && crypto.timingSafeEqual(Buffer.from(c), Buffer.from(GOOD));
}
const requireAuth = (req, res, next) =>
  isAuthed(req) ? next() : res.status(401).json({ error: "Unauthorized" });

app.post("/api/login", (req, res) => {
  const pw = String(req.body?.password || "");
  const a = Buffer.from(sign(pw)), b = Buffer.from(sign(APP_PASSWORD));
  if (!APP_PASSWORD || crypto.timingSafeEqual(a, b)) {
    res.setHeader("Set-Cookie",
      `${COOKIE}=${GOOD}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000${req.secure ? "; Secure" : ""}`);
    return res.json({ ok: true });
  }
  res.status(401).json({ error: "Wrong password" });
});

// ---------- config for the frontend ----------
app.get("/api/config", (req, res) => {
  res.json({
    authed: isAuthed(req),
    maxSessionSeconds: Number(MAX_SESSION_SECONDS),
    lucyModel: LUCY_MODEL,
    engines: { lucy: !!DECART_API_KEY, eden: !!FAL_KEY },
  });
});

// ---------- Decart: short-lived client token ----------
const decart = DECART_API_KEY ? createDecartClient({ apiKey: DECART_API_KEY }) : null;

app.post("/api/decart-token", requireAuth, async (req, res) => {
  if (!decart) return res.status(503).json({ error: "DECART_API_KEY not set" });
  try {
    const origin = req.headers.origin;
    const token = await decart.tokens.create({
      expiresIn: 60,
      ...(origin ? { allowedOrigins: [origin] } : {}),
      constraints: { realtime: { maxSessionDuration: Number(MAX_SESSION_SECONDS) } },
    });
    res.json({ apiKey: token.apiKey, expiresAt: token.expiresAt });
  } catch (e) {
    console.error("decart token:", e?.message || e);
    res.status(502).json({ error: "Could not mint Decart token" });
  }
});

// ---------- fal: proxy for realtime (Eden Live) ----------
const falConfig = falProxy.resolveProxyConfig({
  allowedEndpoints: [
    "vast/eden-live-14b-video", "vast/eden-live-14b-video/**",
    "vast/eden-live-5b-video", "vast/eden-live-5b-video/**",
  ],
  allowUnauthorizedRequests: false,
  isAuthenticated: async (b) => {
    if (!APP_PASSWORD) return true;
    const raw = [].concat(b.getHeader("cookie") || "").join("; ");
    return isAuthed({ headers: { cookie: raw } });
  },
  resolveFalAuth: async () => (FAL_KEY ? `Key ${FAL_KEY}` : undefined),
});

// Own adapter (not the bundled Express one) so fal's HTTP status codes reach the browser.
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
      sendResponse: async (upstream) => {
        res.status(upstream.status);
        res.end(Buffer.from(await upstream.arrayBuffer()));
      },
    }, falConfig);
  } catch (e) {
    console.error("fal proxy:", e?.message || e);
    if (!res.headersSent) res.status(502).json({ error: "fal proxy error" });
  }
});

// ---------- fal: build the Eden "target look" first frame ----------
// Eden Live renders from a first frame that shows the target look in the
// camera's pose. We make that frame from (camera frame + character image).
const isImg = (s) => typeof s === "string" && /^data:image\/(jpeg|png|webp);base64,/.test(s);

app.post("/api/first-frame", requireAuth, async (req, res) => {
  if (!FAL_KEY) return res.status(503).json({ error: "FAL_KEY not set" });
  const { frame, character, prompt = "", width = 832, height = 480 } = req.body || {};
  if (!isImg(frame) || !isImg(character)) return res.status(400).json({ error: "frame and character must be image data URIs" });

  const w = Math.min(1280, Math.max(256, Number(width) | 0));
  const h = Math.min(1280, Math.max(256, Number(height) | 0));
  const instruction =
    "Replace the person in the first image with the character from the second image. " +
    "Keep the first image's exact pose, head position, framing, camera angle and background. " +
    String(prompt).slice(0, 600);

  try {
    const r = await fetch(`https://fal.run/${FIRST_FRAME_MODEL}`, {
      method: "POST",
      headers: { Authorization: `Key ${FAL_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        prompt: instruction,
        image_urls: [frame, character],
        image_size: { width: w, height: h },
        num_images: 1,
        output_format: "jpeg",
      }),
    });
    const data = await r.json().catch(() => ({}));
    const url = data?.images?.[0]?.url;
    if (!r.ok || !url) {
      console.error("first-frame:", r.status, JSON.stringify(data).slice(0, 400));
      return res.status(502).json({ error: data?.detail?.[0]?.msg || data?.detail || "First-frame generation failed" });
    }
    res.json({ url });
  } catch (e) {
    console.error("first-frame:", e?.message || e);
    res.status(502).json({ error: "First-frame generation failed" });
  }
});

// ---------- static ----------
// no-cache = always revalidate (ETag), so UI updates show up immediately
app.use(express.static(path.join(__dirname, "public"), { setHeaders: (res) => res.setHeader("Cache-Control", "no-cache") }));

app.listen(PORT, () => {
  console.log(`LiveChar on :${PORT}  lucy=${!!DECART_API_KEY} eden=${!!FAL_KEY} gate=${APP_PASSWORD ? "on" : "OFF (set APP_PASSWORD)"}`);
});
