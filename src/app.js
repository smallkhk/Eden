import { createDecartClient, models } from "@decartai/sdk";
import { createFalClient } from "@fal-ai/client";
import { wma } from "@fal-ai/client/realtime";

const $ = (id) => document.getElementById(id);
const ui = {
  gate: $("gate"), authTitle: $("authTitle"), au: $("au"), pw: $("pw"), pwBtn: $("pwBtn"), pwErr: $("pwErr"), authSwap: $("authSwap"),
  em: $("em"), emRow: $("emRow"), auLabel: $("auLabel"), forgot: $("forgot"),
  chars: $("chars"), charName: $("charName"), saveChar: $("saveChar"), charPreset: $("charPreset"), presetRow: $("presetRow"), saveRow: $("saveRow"),
  snap: $("snap"), rec: $("rec"), tools: $("tools"),
  who: $("who"), bal: $("bal"), adminLink: $("adminLink"), logout: $("logout"), userBox: $("userBox"),
  engine: $("engine"), expand: $("expand"),
  file: $("file"), thumb: $("thumb"), clearImg: $("clearImg"), prompt: $("prompt"),
  start: $("start"), stop: $("stop"), apply: $("apply"), mirror: $("mirror"),
  vcamRow: $("vcamRow"), vcam: $("vcam"), vcamHint: $("vcamHint"),
  camSel: $("camSel"), rot: $("rot"), orient: $("orient"), orientRow: $("orientRow"),
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

let cfg = { maxSessionSeconds: 300, lucyModel: "lucy-latest", lucyFast: true, engines: {}, rates: {} };
let bill = null;       // paid session { id, timer }
const fmtBal = (s) => { s = Math.max(0, Math.floor(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60); return (h ? h + "h " : "") + (h || m ? m + "m " : "") + (s % 60) + "s"; };
const setBalance = (b) => { if (b != null) ui.bal.textContent = fmtBal(b); };
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
  if (r.status === 401 && path !== "/api/login" && path !== "/api/register") showAuth();
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
// ---------- which camera to use ----------
// Never use our own virtual cameras as the input: that would feed the output back into itself.
const OWN_CAMERA = /livechar camera|softcam/i;
const CAM_KEY = "livechar.camera";
const savedCamera = () => { try { return localStorage.getItem(CAM_KEY) || ""; } catch { return ""; } };
const saveCamera = (id) => { try { id ? localStorage.setItem(CAM_KEY, id) : localStorage.removeItem(CAM_KEY); } catch {} };
let camWant = { w: 1280, h: 720, fps: 30 };

async function realCameras() {
  const all = await navigator.mediaDevices.enumerateDevices();
  return all.filter((d) => d.kind === "videoinput" && !OWN_CAMERA.test(d.label));
}
// Fill the dropdown. Names are only known after the browser has been given camera permission.
async function listCameras(currentId = "") {
  const cams = await realCameras().catch(() => []);
  const named = cams.filter((d) => d.label);
  const keep = currentId || ui.camSel.value || savedCamera();
  ui.camSel.replaceChildren(...(named.length ? named : [{ deviceId: "", label: "Default camera" }]).map((d) => {
    const o = document.createElement("option"); o.value = d.deviceId; o.textContent = d.label; return o;
  }));
  if ([...ui.camSel.options].some((o) => o.value === keep)) ui.camSel.value = keep;
  return cams;
}
const getCam = (deviceId) => navigator.mediaDevices.getUserMedia({
  video: { width: { ideal: camWant.w }, height: { ideal: camWant.h }, frameRate: { ideal: camWant.fps }, ...(deviceId ? { deviceId: { exact: deviceId } } : { facingMode: "user" }) },
  audio: false,
});

async function openCamera(w, h, fps) {
  camWant = { w, h, fps };
  const wanted = ui.camSel.value || savedCamera();
  let stream;
  try { stream = await getCam(wanted); }
  catch (e) { if (!wanted || e?.name === "NotAllowedError") throw e; stream = await getCam(""); }   // saved camera unplugged
  // The default the system picked may be one of our own virtual cameras: switch to a real one.
  let track = stream.getVideoTracks()[0];
  const cams = await realCameras().catch(() => []);
  if (OWN_CAMERA.test(track.label)) {
    stream.getTracks().forEach((t) => t.stop());
    if (!cams.length) throw new Error("No real camera found. Plug in a webcam: LiveChar's own virtual camera can't be the input.");
    stream = await getCam(cams[0].deviceId);
    track = stream.getVideoTracks()[0];
  }
  cam = stream;
  await listCameras(track.getSettings().deviceId || "");
  rawV.srcObject = cam;
  await rawV.play().catch(() => {});
  await new Promise((ok) => (rawV.videoWidth ? ok() : rawV.addEventListener("loadedmetadata", ok, { once: true })));
  return cam;
}
// Changing the camera works while live: the AI reads the canvas, so only the source behind it is swapped.
async function switchCamera() {
  saveCamera(ui.camSel.value);
  if (!cam) return;
  try {
    const next = await getCam(ui.camSel.value);
    cam.getTracks().forEach((t) => t.stop());
    cam = next; rawV.srcObject = cam;
    await rawV.play().catch(() => {});
    setNote("Camera changed");
  } catch (e) { setNote(`Could not open that camera (${e?.message || e?.name || e})`); }
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
  goLive();
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
    apiKeyProvider: async () => (await api("/api/decart-token", { id: bill?.id })).apiKey,
  });

  const text = ui.prompt.value.trim() || (refBlob ? LUCY_SWAP : "");
  const initialState = {};
  if (text) initialState.prompt = { text, enhance: ui.expand.checked };
  if (refBlob) initialState.image = refBlob;

  const wantFast = cfg.lucyFast && model.supportedSpeeds?.includes("fast");
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
  const { url, balance } = await api("/api/first-frame", { frame, character, prompt: ui.prompt.value.trim(), width: eng.w, height: eng.h });
  setBalance(balance);
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
      else if (m.type === "stream_exhausted") stopAll("The stream ended. Press Go live to start again.");
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
// Billing starts when the first output frame arrives (or 20s after start, whichever is first).
function goLive() {
  const b = bill;
  if (!b || b.live) return;
  b.live = true; clearTimeout(b.fallback);
  api("/api/session/live", { id: b.id }).catch(() => {});
  b.timer = setInterval(async () => {
    try {
      const r = await api("/api/session/beat", { id: b.id });
      setBalance(r.balance);
      if (r.ended && bill === b) stopAll(r.balance <= 0 ? "Balance finished — top up to continue" : "Session time limit reached");
    } catch {}
  }, 5000);
}
async function startAll() {
  if (run) return;
  const eng = ENGINES[ui.engine.value];
  ui.start.disabled = true; setNote(""); setStats({}); setStatus("starting…");
  try {
    // open the paid session first: the server sets how long it may run
    const s = await api("/api/session/start", { engine: ui.engine.value });
    bill = { id: s.id, timer: null, live: false, fallback: setTimeout(goLive, 20000) }; setBalance(s.balance);
    run = eng.kind === "lucy" ? await startLucy() : await startEden(eng);
    refDirty = false;
    ui.stop.disabled = false; ui.apply.disabled = false; ui.engine.disabled = true; ui.orient.disabled = true;
    capTimeout = setTimeout(() => stopAll("Session time limit reached"), s.maxSeconds * 1000);
  } catch (e) {
    console.error(e);
    await stopAll(e?.name === "NotAllowedError" ? "Camera permission denied" : (e?.message || "Could not start"));
  }
}
async function stopAll(reason = "") {
  clearTimeout(capTimeout);
  const r = run; run = null;
  const b = bill; bill = null;
  if (b) { clearInterval(b.timer); clearTimeout(b.fallback); api("/api/session/stop", { id: b.id }).then((x) => setBalance(x.balance)).catch(() => {}); }
  try { await r?.stop(); } catch {}
  stopRecording();
  closeCamera();
  ui.outV.srcObject = null;
  ui.start.disabled = false; ui.stop.disabled = true; ui.apply.disabled = true; ui.engine.disabled = false;
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
function setRef(blob) {
  refBlob = blob; refDirty = true;
  if (ui.thumb.src.startsWith("blob:")) URL.revokeObjectURL(ui.thumb.src);
  if (blob) ui.thumb.src = URL.createObjectURL(blob);
  ui.thumb.hidden = !blob; ui.clearImg.hidden = !blob; ui.saveRow.hidden = !blob;
  if (!blob) ui.file.value = "";
}
ui.file.addEventListener("change", async () => {
  const f = ui.file.files[0]; if (!f) return;
  setNote("");
  try { setRef(await fileToJpeg(f)); } catch (e) { setNote(e.message); }
});
ui.clearImg.addEventListener("click", () => setRef(null));

// ---------- saved characters ----------
async function loadChars() {
  const { characters } = await api("/api/characters");
  ui.chars.replaceChildren(...characters.map((c) => {
    const b = document.createElement("button");
    b.className = "char"; b.type = "button"; b.title = c.prompt ? `${c.name} — ${c.prompt}` : c.name;
    const img = document.createElement("img"); img.src = `/api/characters/${c.id}/image`; img.alt = ""; img.loading = "lazy";
    const n = document.createElement("span"); n.textContent = c.name;
    b.append(img, n);
    b.addEventListener("click", async () => {
      try {
        const r = await fetch(img.src); if (!r.ok) throw new Error("Could not load that character");
        setRef(await r.blob()); ui.prompt.value = c.prompt || ""; ui.charName.value = "";
        setNote(run ? `“${c.name}” loaded — press “Apply changes while live”` : `“${c.name}” loaded`);
      } catch (e) { setNote(e.message); }
    });
    if (!c.preset || cfg.user?.isAdmin) {
      const x = document.createElement("i"); x.textContent = "×"; x.title = `Delete ${c.name}`; x.setAttribute("role", "button");
      x.addEventListener("click", async (e) => {
        e.stopPropagation();
        if (!confirm(`Delete “${c.name}”?`)) return;
        try { await fetch(`/api/characters/${c.id}`, { method: "DELETE" }); await loadChars(); } catch (err) { setNote(err.message); }
      });
      b.append(x);
    }
    return b;
  }));
  ui.chars.hidden = !characters.length;
}
ui.saveChar.addEventListener("click", async () => {
  if (!refBlob) return;
  ui.saveChar.disabled = true;
  try {
    const body = { name: ui.charName.value.trim() || "Character", prompt: ui.prompt.value.trim(), image: await blobToDataUrl(refBlob) };
    await api(ui.charPreset.checked ? "/api/admin/presets" : "/api/characters", body);
    ui.charName.value = ""; ui.charPreset.checked = false; setNote("Character saved"); await loadChars();
  } catch (e) { setNote(e.message); }
  finally { ui.saveChar.disabled = false; }
});

function syncEngine() {
  const lucy = ENGINES[ui.engine.value].kind === "lucy";
  ui.orient.disabled = !lucy || !!run;          // Eden Live is landscape only
  document.body.classList.toggle("portrait", isPortrait());
  if (window.livecharDesktop?.vcam?.active()) restartVcam();
}
ui.camSel.addEventListener("change", switchCamera);
navigator.mediaDevices?.addEventListener?.("devicechange", () => listCameras().catch(() => {}));
ui.engine.addEventListener("change", syncEngine);
ui.orient.addEventListener("change", syncEngine);
ui.mirror.addEventListener("change", () => document.body.classList.toggle("mirror", ui.mirror.checked));
ui.start.addEventListener("click", startAll);
ui.stop.addEventListener("click", () => stopAll());
ui.apply.addEventListener("click", applyAll);
ui.prompt.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) applyAll(); });
window.addEventListener("pagehide", () => {
  if (bill) navigator.sendBeacon("/api/session/stop", JSON.stringify({ id: bill.id }));
  run?.stop(); closeCamera();
});

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
// touch: pinch with two fingers to zoom (phones, tablets, the iOS app)
let drag = null, pinch = null;
const touches = new Map();
const spread = () => { const [a, b] = [...touches.values()]; return Math.hypot(a.x - b.x, a.y - b.y) || 1; };
ui.outView.addEventListener("pointerdown", (e) => {
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (touches.size === 2) { pinch = { d: spread(), z: view.z }; drag = null; ui.outView.setPointerCapture(e.pointerId); return; }
  if (view.z > 1) { drag = { x: e.clientX, y: e.clientY }; ui.outView.setPointerCapture(e.pointerId); }
});
ui.outView.addEventListener("pointermove", (e) => {
  if (touches.has(e.pointerId)) touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pinch && touches.size >= 2) return setView(pinch.z * spread() / pinch.d);
  if (!drag) return;
  const r = ui.outView.getBoundingClientRect(), dir = ui.mirror.checked ? -1 : 1;
  setView(view.z, view.ox + dir * (e.clientX - drag.x) / (r.width * view.z), view.oy + (e.clientY - drag.y) / (r.height * view.z));
  drag = { x: e.clientX, y: e.clientY };
});
const endDrag = (e) => { touches.delete(e.pointerId); if (touches.size < 2) pinch = null; drag = null; };
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
      const show = () => {
        const i = desk.info?.() || { names: [desk.name] };
        let text = i.names.length ? `In your other app, choose the camera called “${i.names.join("” or “")}”.` : "Starting the camera…";
        if (i.names.length > 1) text += " Use LiveChar Camera where it shows up; the other is for older apps.";
        if (i.win11 === "error") text += ` The Windows 11 camera did not start: ${i.win11Error}`;
        if (desk.connected()) text += " An app is using it now.";
        ui.vcamHint.textContent = text;
      };
      show(); vcamPoll = setInterval(show, 2000);
    } else { desk.stop(); ui.vcamHint.hidden = true; }
  });
}

// ---------- photo + recording of the output (with the current zoom) ----------
const outSize = () => (isPortrait() ? [720, 1280] : [1280, 720]);
function drawFramed(ctx, W, H) {
  const v = ui.outV;
  ctx.fillStyle = "#000"; ctx.fillRect(0, 0, W, H);
  if (!(v.readyState >= 2 && v.videoWidth)) return false;
  const s = Math.min(W / v.videoWidth, H / v.videoHeight), dw = v.videoWidth * s, dh = v.videoHeight * s;
  ctx.save();
  ctx.translate(W / 2, H / 2); ctx.scale(view.z, view.z);
  ctx.translate(view.ox * W - W / 2, view.oy * H - H / 2);
  ctx.drawImage(v, (W - dw) / 2, (H - dh) / 2, dw, dh);
  ctx.restore();
  return true;
}
function download(blob, ext) {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `livechar-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.${ext}`;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 30000);
}
function takePhoto() {
  const [W, H] = outSize(), c = document.createElement("canvas"); c.width = W; c.height = H;
  if (!drawFramed(c.getContext("2d"), W, H)) return setNote("Go live first, then take a photo");
  c.toBlob((b) => { if (b) { download(b, "png"); setNote("Photo saved"); } }, "image/png");
}
let rec = null;
function stopRecording() {
  if (!rec) return;
  clearInterval(rec.draw); clearInterval(rec.clock);
  try { rec.mr.stop(); } catch {}
  ui.rec.textContent = "Record"; ui.rec.classList.remove("on");
}
function toggleRecording() {
  if (rec) return stopRecording();
  if (!(ui.outV.readyState >= 2 && ui.outV.videoWidth)) return setNote("Go live first, then record");
  const type = ["video/mp4;codecs=avc1.42E01E", "video/webm;codecs=vp9", "video/webm"].find((t) => window.MediaRecorder?.isTypeSupported(t));
  if (!type) return setNote("Recording is not supported in this browser");
  const [W, H] = outSize(), c = document.createElement("canvas"); c.width = W; c.height = H;
  const ctx = c.getContext("2d"); drawFramed(ctx, W, H);
  const mr = new MediaRecorder(c.captureStream(30), { mimeType: type, videoBitsPerSecond: 6_000_000 });
  const chunks = [], t0 = Date.now(), r = { mr };
  mr.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  mr.onstop = () => { rec = null; if (chunks.length) { download(new Blob(chunks, { type: type.split(";")[0] }), type.startsWith("video/mp4") ? "mp4" : "webm"); setNote("Recording saved"); } };
  r.draw = setInterval(() => drawFramed(ctx, W, H), 1000 / 30);
  r.clock = setInterval(() => { const s = Math.floor((Date.now() - t0) / 1000); ui.rec.textContent = `Stop ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }, 500);
  rec = r; mr.start(1000);
  ui.rec.textContent = "Stop 0:00"; ui.rec.classList.add("on");
}
ui.snap.addEventListener("click", takePhoto);
ui.rec.addEventListener("click", toggleRecording);
for (const ev of ["pointerdown", "dblclick", "wheel"]) ui.tools.addEventListener(ev, (e) => e.stopPropagation());

// ---------- hotkeys (desktop app; work while another app is in front) ----------
window.livecharDesktop?.onHotkey?.((name) => {
  if (!cfg.user) return;
  if (name === "toggle") (run || bill) ? stopAll() : startAll();
  else if (name === "zoomIn") setView(view.z * 1.15);
  else if (name === "zoomOut") setView(view.z / 1.15);
  else if (name === "zoomReset") setView(1, 0, 0);
  else if (name === "photo") takePhoto();
  else if (name === "record") toggleRecording();
  else if (name === "vcam" && desk) { ui.vcam.checked = !ui.vcam.checked; ui.vcam.dispatchEvent(new Event("change")); }
});

// ---------- accounts ----------
let authMode = "login";
function showAuth(mode = authMode) {
  authMode = mode;
  const reg = mode === "register";
  ui.authTitle.textContent = !cfg.hasUsers ? "Create the admin account" : reg ? "Create account" : "Log in";
  ui.pwBtn.textContent = reg ? "Create account" : "Log in";
  ui.authSwap.textContent = reg ? "Have an account? Log in" : "New here? Create an account";
  ui.authSwap.hidden = !cfg.hasUsers || (!reg && !cfg.allowSignup);
  ui.pw.autocomplete = reg ? "new-password" : "current-password";
  ui.emRow.hidden = !reg; ui.forgot.hidden = reg || !cfg.hasUsers;
  ui.auLabel.textContent = reg ? "Username" : "Username or email";
  ui.gate.hidden = false;
}
async function submitAuth() {
  ui.pwErr.textContent = "";
  try {
    await api(authMode === "register" ? "/api/register" : "/api/login", { username: ui.au.value.trim(), password: ui.pw.value, ...(authMode === "register" ? { email: ui.em.value.trim() } : {}) });
    ui.pw.value = ""; ui.gate.hidden = true; await boot();
  } catch (e) { ui.pwErr.textContent = e.message; }
}
ui.pwBtn.addEventListener("click", submitAuth);
ui.pw.addEventListener("keydown", (e) => e.key === "Enter" && submitAuth());
ui.au.addEventListener("keydown", (e) => e.key === "Enter" && ui.pw.focus());
ui.authSwap.addEventListener("click", () => { ui.pwErr.textContent = ""; showAuth(authMode === "register" ? "login" : "register"); });
ui.logout.addEventListener("click", async () => { await stopAll(); await api("/api/logout", {}).catch(() => {}); location.reload(); });

const LABELS = { lucy: "Decart Lucy — 720p, fastest", "eden-5b": "Eden Live 5B — 720p @ 24fps", "eden-14b": "Eden Live 14B — 480p @ 16fps" };
async function boot() {
  cfg = await api("/api/config");
  if (!cfg.user) { ui.userBox.hidden = true; showAuth(cfg.hasUsers ? "login" : "register"); return; }
  ui.gate.hidden = true; ui.userBox.hidden = false;
  ui.who.textContent = cfg.user.username; setBalance(cfg.user.balance); ui.adminLink.hidden = !cfg.user.isAdmin;
  ui.presetRow.hidden = !cfg.user.isAdmin;
  loadChars().catch(() => {});
  listCameras().catch(() => {});
  for (const o of ui.engine.options) {
    const on = ENGINES[o.value].kind === "lucy" ? cfg.engines.lucy : cfg.engines.eden;
    const rate = cfg.rates[o.value];
    o.disabled = !on;
    o.textContent = LABELS[o.value] + (!on ? " (not set up)" : rate && rate !== 1 ? ` · ${rate}× rate` : "");
  }
  const first = [...ui.engine.options].find((o) => !o.disabled);
  if (first) { if (ui.engine.selectedOptions[0]?.disabled) ui.engine.value = first.value; }
  else setNote(cfg.user.isAdmin ? "Add your API keys in Admin to go live." : "The service is not set up yet.");
  syncEngine();
  document.body.classList.toggle("mirror", ui.mirror.checked);
  setView();
  setStatus("idle");
}
boot().catch((e) => setNote(e.message));
