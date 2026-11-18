// Own GPU on RunPod for Eden Live 5B: start/stop the pod, watch it, auto-stop when idle,
// and hand the browser a signed ticket + TURN relay to stream straight to the pod.
import crypto from "node:crypto";

const API = "https://api.runpod.io";
const b64u = (buf) => Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export function setupGpu({ app, setting, setSetting, num, requireUser, requireAdmin, openSession, anyGpuSession, isGpuEngine }) {
  let st = { state: "off", stage: "", ready: false, busy: false, podId: "", cost: null, uptime: 0, ip: "", turnPort: 0, profile: null, error: "", since: 0 };
  let lastUse = Date.now();
  let creating = false;
  let podLight = false;
  let waiting = false, waitTimer = null;   // retrying while no 5090 is free

  const key = () => setting("runpod_key");
  const secret = () => {
    let s = setting("gpu_secret");
    if (!s) { s = crypto.randomBytes(24).toString("hex"); setSetting("gpu_secret", s); }
    return s;
  };
  const podUrl = (id) => `https://${id}-8000.proxy.runpod.net`;

  async function rp(method, path, body) {
    if (!key()) throw new Error("Add your RunPod API key first");
    const r = await fetch(API + path, {
      method,
      headers: { Authorization: `Bearer ${key()}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(20000),
    });
    const text = await r.text();
    let data; try { data = text ? JSON.parse(text) : {}; } catch { data = { error: text }; }
    if (!r.ok) {
      const err = new Error(data?.detail || data?.error || data?.message || `RunPod HTTP ${r.status}`);
      err.status = r.status;
      throw err;
    }
    return data;
  }

  async function ensureVolume() {
    const id = setting("gpu_volume_id");
    if (id) {
      try { await rp("GET", `/v2/network-volumes/${id}`); return id; }
      catch (e) { if (e.status !== 404) throw e; }
    }
    // Reuse an existing "livechar" volume (models already installed) before creating one.
    try {
      const list = await rp("GET", "/v2/network-volumes");
      const found = (list.networkVolumes || list || []).find((x) => x.name === "livechar");
      if (found) { setSetting("gpu_volume_id", found.id); setSetting("gpu_datacenter", found.dataCenter || found.dataCenterId || setting("gpu_datacenter")); return found.id; }
    } catch {}
    const v = await rp("POST", "/v2/network-volumes", { name: "livechar", size: Math.max(50, num("gpu_volume_gb")), dataCenter: setting("gpu_datacenter") });
    setSetting("gpu_volume_id", v.id);
    return v.id;
  }

  async function startPod() {
    if (st.podId || creating) return;
    creating = true;
    try {
      const volumeId = await ensureVolume();
      const code = setting("gpu_code_url");
      podLight = setting("gpu_env_ready") === "1";
      const pod = await rp("POST", "/v2/pods", {
        name: "livechar-gpu",
        image: podLight ? setting("gpu_image_light") : setting("gpu_image"),
        args: `bash -c "curl -fsSL ${code}/start.sh -o /tmp/lc-start.sh && bash /tmp/lc-start.sh"`,
        cloud: setting("gpu_cloud") || "SECURE",
        disk: 40,
        ports: ["8000/http", "3478/tcp"],
        env: { LC_SECRET: secret(), LC_CODE_URL: code },
        mounts: { network: [{ volumeId, path: "/workspace" }] },
        gpu: { id: setting("gpu_type"), count: 1 },
      });
      setSetting("gpu_pod_id", pod.id);
      st = { ...st, state: "starting", stage: "waiting for a GPU", podId: pod.id, error: "", since: Date.now() };
      lastUse = Date.now();
    } finally { creating = false; }
  }

  async function stopPod() {
    if (waiting) { waiting = false; clearTimeout(waitTimer); st = { ...st, state: "off", stage: "" }; }
    const id = setting("gpu_pod_id");
    if (id) {
      try { await rp("DELETE", `/v2/pods/${id}`); }
      catch (e) { if (e.status !== 404) throw e; }
    }
    setSetting("gpu_pod_id", "");
    st = { ...st, state: "off", stage: "", ready: false, busy: false, podId: "", cost: null, uptime: 0, ip: "", turnPort: 0 };
  }

  async function refresh() {
    const id = setting("gpu_pod_id");
    if (!id || !key()) { st = waiting ? { ...st, ready: false, podId: "" } : { ...st, state: "off", ready: false, podId: "" }; return st; }
    try {
      const pod = await rp("GET", `/v2/pods/${id}`);
      const tcp = (pod.runtime?.ports || []).find((p) => p.type === "tcp" && p.private === 3478 && p.ip);
      st = { ...st, podId: id, cost: pod.cost ?? null, uptime: pod.runtime?.uptime || 0, ip: tcp?.ip || "", turnPort: tcp?.public || 0 };
      const status = String(pod.status || "").toLowerCase();
      if (status !== "running" || !pod.runtime?.uptime) {
        st = { ...st, state: "starting", stage: status === "running" ? "pulling image" : `pod ${status || "pending"}`, ready: false };
        return st;
      }
      try {
        const h = await (await fetch(`${podUrl(id)}/health`, { signal: AbortSignal.timeout(6000) })).json();
        st = { ...st, state: h.ready ? "ready" : "starting", stage: h.stage || "", ready: !!h.ready && !!st.ip, busy: !!h.busy, profile: h.profile || null };
        if (h.ready && h.env && setting("gpu_env_ready") !== "1") setSetting("gpu_env_ready", "1");
        if (podLight && /^load failed/.test(h.stage || "")) setSetting("gpu_env_ready", "0");   // next start uses the full image
        if (h.ready && !st.ip) st.stage = "ready, waiting for public TCP port";
      } catch { st = { ...st, state: "starting", stage: "container starting", ready: false }; }
    } catch (e) {
      if (e.status === 404) { setSetting("gpu_pod_id", ""); st = { ...st, state: "off", ready: false, podId: "" }; }
      else st = { ...st, error: e.message };
    }
    return st;
  }

  // Watch the pod; stop it after N idle minutes so it never bills while nobody uses it.
  setInterval(async () => {
    if (!setting("gpu_pod_id")) return;
    await refresh();
    if (st.busy || anyGpuSession()) lastUse = Date.now();
    // Never bill for a pod that failed or is stuck starting.
    const failed = /^(load failed|setup failed)/.test(st.stage || "");
    if (!st.ready && (failed || (st.since && Date.now() - st.since > 45 * 60000))) {
      console.log("gpu: failed or stuck, stopping pod:", st.stage);
      st.error = failed ? st.stage : "GPU took too long to start, stopped it";
      return stopPod().catch((e) => console.error("gpu stop:", e.message));
    }
    const idle = Math.max(1, num("gpu_idle_minutes")) * 60000;
    if (st.ready && Date.now() - lastUse > idle) {
      console.log("gpu: idle, stopping pod");
      stopPod().catch((e) => console.error("gpu stop:", e.message));
    }
  }, 10000).unref();
  refresh().catch(() => {});

  // ---------- admin ----------
  app.get("/api/admin/gpu", requireAdmin, async (_req, res) => {
    await refresh().catch(() => {});
    res.json({ ...st, hasKey: !!key(), volumeId: setting("gpu_volume_id"), gpuType: setting("gpu_type"), datacenter: setting("gpu_datacenter"), idleMinutes: num("gpu_idle_minutes") });
  });
  // No free 5090 in the volume's region: keep retrying every 20 s for up to 20 min.
  const noStock = (e) => e.status === 400 && /no longer any instances|not enough free gpus/i.test(e.message);
  function waitForGpu(startedAt) {
    clearTimeout(waitTimer);
    waitTimer = setTimeout(async () => {
      if (!waiting) return;
      try { await startPod(); waiting = false; }
      catch (e) {
        if (noStock(e) && Date.now() - startedAt < 20 * 60000) return waitForGpu(startedAt);
        waiting = false;
        st = { ...st, state: "off", stage: "", error: noStock(e) ? "No RTX 5090 free right now. Try again later." : e.message };
      }
    }, 20000);
  }
  app.post("/api/admin/gpu/start", requireAdmin, async (_req, res) => {
    try { await startPod(); res.json(st); }
    catch (e) {
      if (noStock(e)) {
        waiting = true;
        st = { ...st, state: "starting", stage: "waiting for a free RTX 5090 (retrying)", error: "" };
        waitForGpu(Date.now());
        return res.json(st);
      }
      console.error("gpu start:", e.message); res.status(502).json({ error: `Could not start the GPU: ${e.message}` });
    }
  });
  app.post("/api/admin/gpu/stop", requireAdmin, async (_req, res) => {
    try { await stopPod(); res.json(st); }
    catch (e) { res.status(502).json({ error: `Could not stop the GPU: ${e.message}` }); }
  });

  // ---------- user: ticket to stream to the pod ----------
  app.post("/api/gpu/connect", requireUser, (req, res) => {
    const s = openSession(req.user.id);
    if (!s || !isGpuEngine(s.engine)) return res.status(403).json({ error: "No active GPU session" });
    if (!st.ready) return res.status(503).json({ error: "The GPU is not running. Ask the admin to start it." });
    lastUse = Date.now();
    const left = Math.max(5, Math.floor((s.started_at + s.cap_seconds * 1000 - Date.now()) / 1000));
    const body = b64u(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 120, sid: s.id, max: left }));
    const token = `${body}.${b64u(crypto.createHmac("sha256", secret()).update(body).digest())}`;
    const username = `${Math.floor(Date.now() / 1000) + left + 600}:${req.user.id}`;
    const credential = crypto.createHmac("sha1", secret()).update(username).digest("base64");
    res.json({
      url: podUrl(st.podId), token,
      iceServers: [{ urls: [`turn:${st.ip}:${st.turnPort}?transport=tcp`], username, credential }],
    });
  });

  return { status: () => st, touch: () => { lastUse = Date.now(); } };
}
