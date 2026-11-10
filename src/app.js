import { createDecartClient, models } from "@decartai/sdk";
import { createFalClient } from "@fal-ai/client";
import { wma } from "@fal-ai/client/realtime";

const $ = (id) => document.getElementById(id);
const ui = {
  gate: $("gate"), pw: $("pw"), pwBtn: $("pwBtn"), pwErr: $("pwErr"),
  engine: $("engine"), fast: $("fast"), fastRow: $("fastRow"), expand: $("expand"),
  file: $("file"), thumb: $("thumb"), clearImg: $("clearImg"), prompt: $("prompt"),
  start: $("start"), stop: $("stop"), apply: $("apply"), mirror: $("mirror"),
  vcamRow: $("vcamRow"), vcam: $("vcam"), vcamHint: $("vcamHint"),
  rot: $("rot"), orient: $("orient"), orientRow: $("orientRow"),
  outView: $("outView"), zoom: $("zoom"), zoomVal: $("zoomVal"), zoomReset: $("zoomReset"),
  inV: $("inV"), outV: $("outV"), status: $("status"), stats: $("stats"), note: $("note"),
};

// fps / size each engine expects from the browser
const ENGINES = {
  lucy:     { label: "Decart Lucy",   kind: "lucy" },
  "eden-5b":  { label: "Eden Live 5B",  kind: "eden", endpoint: "vast/eden-live-5b-video",  w: 1280, h: 704, fps: 24, price: 0.0035 },
  "eden-14b": { label: "Eden Live 14B", kind: "eden", endpoint: "vast/eden-live-14b-video", w: 832,  h: 480, fps: 16, price: 0.01 },
};

const LUCY_SWAP = "Substitute the character in the video with the person in the reference image.";
const EDEN_SWAP = "The character from the reference image, same pose and framing as the camera, natural lighting, detailed, consistent identity.";

let cfg = { maxSessionSeconds: 300, lucyModel: "lucy-latest", engines: {} };
let cam = null;        // raw camera stream
let run = null;        // active session { kind, stop(), apply() }
let refBlob = null;    // character reference (JPEG blob)
let refDirty = false;
let capTimer = null;

const setStatus = (t, cls = "") => { ui.status.textContent = t; ui.status.className = "pill " + cls; };
const setNote = (t = "") => { ui.note.textContent = t; };
const setStats = (o) => { ui.stats.textContent = Object.entries(o).filter(([, v]) => v != null && v !== "").map(([k, v]) => `${k} ${v}`).join("  ·  "); };

async function api(path, body) {
  const r = await fetch(path, { method: body ? "POST" : "GET", headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
  return j;
}

// ---------- images ----------
function loadImage(src) {
  return new Promise((ok, bad) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => bad(new Error("Could not read image")); i.src = src; });
}
async function fileToJpeg(file, maxSide = 1024) {
  const url = URL.createObjectURL(file);
  try {
    const img = await loadImage(url);
    const s = Math.min(1, maxSide / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.round(img.width * s); c.height = Math.round(img.height * s);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    if (Math.min(c.width, c.height) < 512) setNote("Reference is small — 512px+ on the short side works best.");
    return await new Promise((ok) => c.toBlob(ok, "image/jpeg", 0.9));
  } finally { URL.revokeObjectURL(url); }
}
const blobToDataUrl = (b) => new Promise((ok) => { const r = new FileReader(); r.onload = () => ok(r.result); r.readAsDataURL(b); });

// Draw the camera rotated by `rot` degrees, filling w x h (cover crop).
function drawCover(ctx, video, w, h, rot = 0) {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return;
  const side = rot % 180 !== 0;
  const s = Math.max(w / (side ? vh : vw), h / (side ? vw : vh));
  ctx.save();
  ctx.translate(w / 2, h / 2);
  ctx.rotate((rot * Math.PI) / 180);
  ctx.drawImage(video, (-vw * s) / 2, (-vh * s) / 2, vw * s, vh * s);
  ctx.restore();
}
const camRot = () => +ui.rot.value || 0;
const isPortrait = () => ui.orient.value === "portrait" && !ui.orient.disabled;

// raw camera lives in a hidden <video>; the CAMERA pane shows what the model receives
const rawV = document.createElement("video");
rawV.muted = true; rawV.playsInline = true;
rawV.style.cssText = "position:fixed;width:1px;height:1px;opacity:0;pointer-events:none";
document.body.appendChild(rawV);

// ---------- camera ----------
async function openCamera(w, h, fps) {
  cam = await navigator.mediaDevices.getUserMedia({
    video: { width: { ideal: w }, height: { ideal: h }, frameRate: { ideal: fps }, facingMode: "user" },
    audio: false,
  });
  rawV.srcObject = cam;
  await rawV.play().catch(() => {});
  await new Promise((ok) => (rawV.videoWidth ? ok() : rawV.addEventListener("loadedmetadata", ok, { once: true })));
  return cam;
}
function closeCamera() {
  clearInterval(capTimer); capTimer = null;
  cam?.getTracks().forEach((t) => t.stop());
  cam = null; rawV.srcObject = null; ui.inV.srcObject = null;
}
// The model gets a canvas, not the raw camera: exact size + fps, with camera rotation applied.
function exactStream(w, h, fps) {
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  const ctx = c.getContext("2d");
  const tick = () => drawCover(ctx, rawV, w, h, camRot());
  tick(); capTimer = setInterval(tick, 1000 / fps);
  const stream = c.captureStream(fps);
  ui.inV.srcObject = stream; ui.inV.play().catch(() => {});
  return { stream, canvas: c };
}
function showOutput(stream) {
  ui.outV.srcObject = stream;
  const tryPlay = (n = 0) => ui.outV.play().catch(() => n < 10 && setTimeout(() => tryPlay(n + 1), 300));
  tryPlay();
}

// ---------- Lucy (Decart direct) ----------
async function startLucy() {
  const model = models.realtime(cfg.lucyModel);
  const fps = typeof model.fps === "number" ? model.fps : (model.fps.ideal || model.fps.max || 30);
  await openCamera(model.width, model.height, fps);
  const [w, h] = isPortrait() ? [model.height, model.width] : [model.width, model.height];
  const { stream } = exactStream(w, h, fps);
  const client = createDecartClient({
    apiKeyProvider: async () => (await api("/api/decart-token", {})).apiKey,
  });

  const text = ui.prompt.value.trim() || (refBlob ? LUCY_SWAP : "");
  const initialState = {};
  if (text) initialState.prompt = { text, enhance: ui.expand.checked };
  if (refBlob) initialState.image = refBlob;

  const wantFast = ui.fast.checked && model.supportedSpeeds?.includes("fast");
  const t0 = performance.now();
  const rt = await client.realtime.connect(stream, {
    model,
    onRemoteStream: showOutput,
    ...(Object.keys(initialState).length ? { initialState } : {}),
    ...(wantFast ? { speed: "fast" } : {}),
  });

  let secs = 0, fpsNow = null;
  const paint = () => setStats({ fps: fpsNow, billed: secs ? secs + "s" : null, mode: wantFast ? "fast" : "standard" });
  rt.on("connectionChange", (s) => setStatus(s, s === "connected" || s === "generating" ? "ok" : ""));
  rt.on("generationTick", ({ seconds }) => { secs = seconds; paint(); });
  rt.on("stats", (s) => { fpsNow = s?.video?.framesPerSecond ? Math.round(s.video.framesPerSecond) : fpsNow; paint(); });
  rt.on("error", (e) => setNote(`Lucy: ${e.code || ""} ${e.message || e}`));
  rt.on("sessionEnded", () => stopAll("Session ended"));
  setStatus("connected", "ok");
  setNote(`Connected in ${((performance.now() - t0) / 1000).toFixed(1)}s`);

  return {
    kind: "lucy",
    stop: () => rt.disconnect(),
    apply: async () => {
      const p = ui.prompt.value.trim() || (refBlob ? LUCY_SWAP : "");
      // set() replaces the whole state, so always send prompt + image together
      await rt.set({ ...(p ? { prompt: p } : {}), image: refBlob || null, enhance: ui.expand.checked });
    },
  };
}

// ---------- Eden Live (fal, WebRTC) ----------
async function edenFirstFrame(eng, canvas) {
  if (!refBlob) return null; // Eden makes its own reference from frame + prompt
  setStatus("building look…");
  const frame = canvas.toDataURL("image/jpeg", 0.85);
  const character = await blobToDataUrl(refBlob);
  const { url } = await api("/api/first-frame", { frame, character, prompt: ui.prompt.value.trim(), width: eng.w, height: eng.h });
  return url;
}

async function startEden(eng) {
  await openCamera(eng.w, eng.h, eng.fps);
  const { stream, canvas } = exactStream(eng.w, eng.h, eng.fps);
  const fal = createFalClient({ proxyUrl: "/api/fal/proxy" });

  setNote(refBlob ? "Hold still for a second…" : "");
  const imageUrl = await edenFirstFrame(eng, canvas);
  const promptText = () => ui.prompt.value.trim() || (refBlob ? EDEN_SWAP : "");

  setStatus("connecting…");
  let pingTimer = null, rtt = null, lastErr = "";
  const session = fal.realtime.open(wma(eng.endpoint), {
    receive: ["video"],
    localStream: stream,
    negotiationTimeoutMs: 60000,
    onMedia: showOutput,
    onState: (s) => {
      if (s === "failed") setTimeout(() => run?.kind === "eden" && stopAll(lastErr || "Connection failed"), 150);
      else if (s !== "live") setStatus(s);
    },
    onError: (e) => { lastErr = `Eden: ${e?.message || e}`; setNote(lastErr); },
    onData: (raw) => {
      let m; try { m = JSON.parse(raw); } catch { return; }
      if (m.type === "configured" || m.type === "reset_applied") { setStatus("live", "ok"); setNote(""); }
      else if (m.type === "prompt_applied") setNote("Prompt applied");
      else if (m.type === "pong") { const ts = m.client_ts ?? m.ts; if (ts) rtt = Math.round(Date.now() - ts); }
      else if (m.type === "stats") setStats({
        fps: m.generation_fps != null ? (+m.generation_fps).toFixed(1) : null,
        latency: m.latency_ms != null ? Math.round(m.latency_ms) + "ms" : null,
        rtt: rtt != null ? rtt + "ms" : null,
        cost: m.billable_units != null ? "$" + (m.billable_units * eng.price).toFixed(3) : null,
      });
      else if (m.type === "error") { setNote(`Eden: ${m.error}`); if (!m.retryable) stopAll("Error"); }
      else if (m.type === "stream_exhausted") stopAll("Stream ended — press Start again");
    },
  });

  const cfgMsg = { type: "configure", enable_prompt_expansion: ui.expand.checked };
  if (promptText()) cfgMsg.prompt = promptText();
  if (imageUrl) cfgMsg.image_url = imageUrl;
  session.send(cfgMsg);
  pingTimer = setInterval(() => session.send({ type: "ping", ts: Date.now() }), 3000);
  session.ready.catch((e) => { if (run?.kind === "eden") stopAll(`Eden: ${e?.message || lastErr || "could not connect"}`); });

  return {
    kind: "eden",
    stop: async () => {
      clearInterval(pingTimer);
      try { session.send({ type: "stop" }); } catch {}
      await session.close();
    },
    apply: async () => {
      if (refDirty) {
        // new character → new anchor frame
        const url = await edenFirstFrame(eng, canvas);
        session.send({ type: "reset", image_url: url, ...(promptText() ? { prompt: promptText() } : {}) });
      } else if (promptText()) {
        session.send({ type: "prompt", prompt: promptText() });
      }
    },
  };
}

// ---------- control ----------
let capTimeout = null;
async function startAll() {
  if (run) return;
  const eng = ENGINES[ui.engine.value];
  ui.start.disabled = true; setNote(""); setStats({}); setStatus("starting…");
  try {
    run = eng.kind === "lucy" ? await startLucy() : await startEden(eng);
    refDirty = false;
    ui.stop.disabled = false; ui.apply.disabled = false; ui.engine.disabled = true; ui.fast.disabled = true; ui.orient.disabled = true;
    capTimeout = setTimeout(() => stopAll("Session time limit reached"), cfg.maxSessionSeconds * 1000);
  } catch (e) {
    console.error(e);
    await stopAll(e?.name === "NotAllowedError" ? "Camera permission denied" : (e?.message || "Could not start"));
  }
}
async function stopAll(reason = "") {
  clearTimeout(capTimeout);
  const r = run; run = null;
  try { await r?.stop(); } catch {}
  closeCamera();
  ui.outV.srcObject = null;
  ui.start.disabled = false; ui.stop.disabled = true; ui.apply.disabled = true; ui.engine.disabled = false; ui.fast.disabled = false;
  ui.orient.disabled = ENGINES[ui.engine.value].kind !== "lucy";
  setStatus("idle"); if (reason) setNote(reason);
}
async function applyAll() {
  if (!run) return;
  ui.apply.disabled = true;
  try { await run.apply(); refDirty = false; if (run?.kind === "lucy") setNote("Applied"); }
  catch (e) { setNote(e?.message || "Apply failed"); }
  finally { if (run) ui.apply.disabled = false; }
}

// ---------- wiring ----------
ui.file.addEventListener("change", async () => {
  const f = ui.file.files[0]; if (!f) return;
  setNote("");
  try {
    refBlob = await fileToJpeg(f); refDirty = true;
    ui.thumb.src = URL.createObjectURL(refBlob); ui.thumb.hidden = false; ui.clearImg.hidden = false;
  } catch (e) { setNote(e.message); }
});
ui.clearImg.addEventListener("click", () => {
  refBlob = null; refDirty = true; ui.file.value = ""; ui.thumb.hidden = true; ui.clearImg.hidden = true;
});
function syncEngine() {
  const lucy = ENGINES[ui.engine.value].kind === "lucy";
  ui.fastRow.hidden = !lucy;
  ui.orient.disabled = !lucy || !!run;          // Eden Live is landscape only
  document.body.classList.toggle("portrait", isPortrait());
  if (window.livecharDesktop?.vcam?.active()) restartVcam();
}
ui.engine.addEventListener("change", syncEngine);
ui.orient.addEventListener("change", syncEngine);
ui.mirror.addEventListener("change", () => document.body.classList.toggle("mirror", ui.mirror.checked));
ui.start.addEventListener("click", startAll);
ui.stop.addEventListener("click", () => stopAll());
ui.apply.addEventListener("click", applyAll);
ui.prompt.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) applyAll(); });
window.addEventListener("pagehide", () => { run?.stop(); closeCamera(); });

// ---------- output zoom (scroll over the output; drag to move) ----------
const desk = window.livecharDesktop?.vcam;
const ZMIN = 1, ZMAX = 4;
const view = { z: 1, ox: 0, oy: 0 };   // ox/oy: pan as a fraction of the frame
function setView(z = view.z, ox = view.ox, oy = view.oy) {
  view.z = Math.min(ZMAX, Math.max(ZMIN, z));
  const lim = (view.z - 1) / (2 * view.z);              // keep the frame edges out of view
  view.ox = Math.min(lim, Math.max(-lim, ox));
  view.oy = Math.min(lim, Math.max(-lim, oy));
  const flip = ui.mirror.checked ? "scaleX(-1) " : "";
  ui.outV.style.transform = `${flip}scale(${view.z}) translate(${view.ox * 100}%, ${view.oy * 100}%)`;
  ui.zoom.value = view.z; ui.zoomVal.textContent = view.z.toFixed(2) + "×";
  ui.outView.style.cursor = view.z > 1 ? "grab" : "";
  desk?.setView?.(view.z, view.ox, view.oy);            // same framing on the virtual camera
}
ui.outView.addEventListener("wheel", (e) => { e.preventDefault(); setView(view.z * Math.exp(-e.deltaY * 0.0015)); }, { passive: false });
ui.zoom.addEventListener("input", () => setView(+ui.zoom.value));
ui.zoomReset.addEventListener("click", () => setView(1, 0, 0));
ui.outView.addEventListener("dblclick", () => setView(1, 0, 0));
let drag = null;
ui.outView.addEventListener("pointerdown", (e) => { if (view.z > 1) { drag = { x: e.clientX, y: e.clientY }; ui.outView.setPointerCapture(e.pointerId); } });
ui.outView.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const r = ui.outView.getBoundingClientRect(), dir = ui.mirror.checked ? -1 : 1;
  setView(view.z, view.ox + dir * (e.clientX - drag.x) / (r.width * view.z), view.oy + (e.clientY - drag.y) / (r.height * view.z));
  drag = { x: e.clientX, y: e.clientY };
});
const endDrag = () => { drag = null; };
ui.outView.addEventListener("pointerup", endDrag); ui.outView.addEventListener("pointercancel", endDrag);
ui.mirror.addEventListener("change", () => setView());

// ---------- virtual camera (desktop app only) ----------
function startVcam() {
  const r = isPortrait() ? desk.start("outV", 720, 1280) : desk.start("outV", 1280, 720);
  if (r.ok) desk.setView?.(view.z, view.ox, view.oy);
  return r;
}
function restartVcam() { desk.stop(); const r = startVcam(); if (!r.ok) { ui.vcam.checked = false; ui.vcamHint.hidden = true; setNote(r.error); } }
let vcamPoll = null;
if (desk) {
  ui.vcamRow.hidden = false;
  ui.vcam.addEventListener("change", () => {
    clearInterval(vcamPoll);
    if (ui.vcam.checked) {
      const r = startVcam();
      if (!r.ok) { ui.vcam.checked = false; ui.vcamHint.hidden = true; setNote(r.error); return; }
      ui.vcamHint.hidden = false;
      const show = () => { ui.vcamHint.textContent = desk.connected() ? `In use by another app as “${desk.name}”.` : `Select “${desk.name}” as the camera in your other app.`; };
      show(); vcamPoll = setInterval(show, 2000);
    } else { desk.stop(); ui.vcamHint.hidden = true; }
  });
}

async function login() {
  ui.pwErr.textContent = "";
  try { await api("/api/login", { password: ui.pw.value }); ui.gate.hidden = true; await boot(); }
  catch (e) { ui.pwErr.textContent = e.message; }
}
ui.pwBtn.addEventListener("click", login);
ui.pw.addEventListener("keydown", (e) => e.key === "Enter" && login());

async function boot() {
  cfg = await api("/api/config");
  if (!cfg.authed) { ui.gate.hidden = false; return; }
  for (const o of ui.engine.options) {
    const on = ENGINES[o.value].kind === "lucy" ? cfg.engines.lucy : cfg.engines.eden;
    o.disabled = !on; if (!on) o.textContent += " (no key)";
  }
  const first = [...ui.engine.options].find((o) => !o.disabled);
  if (first) ui.engine.value = first.value; else setNote("No API keys set on the server.");
  syncEngine();
  document.body.classList.toggle("mirror", ui.mirror.checked);
  setView();
  setStatus("idle");
}
boot().catch((e) => setNote(e.message));
