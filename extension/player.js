// LiveChar live player: plays the H.264 stream the iOS app sends to a watch link.
// Used by public/watch.html and (a copy) by the Chrome extension. Keep the two files identical.
//
// Wire format, from GET /api/share/<id>/stream:
//   [u32 length][payload], repeated. length 0 = keep-alive.
//   payload = [u8 flags][u64 timestamp µs][H.264 Annex B]; flags 1 = keyframe, 2 = stream ended.
(() => {
  if (globalThis.LiveCharPlayer) return;

  const hex = (n) => n.toString(16).padStart(2, "0");

  // first SPS NAL unit (type 7) in an Annex B buffer, header byte included
  function findSps(d) {
    for (let i = 0; i + 4 < d.length; i++) {
      if (d[i] !== 0 || d[i + 1] !== 0) continue;
      const sc = d[i + 2] === 1 ? 3 : d[i + 2] === 0 && d[i + 3] === 1 ? 4 : 0;
      if (!sc) continue;
      const start = i + sc;
      if ((d[start] & 0x1f) !== 7) { i = start; continue; }
      let end = start + 1;
      while (end + 2 < d.length && !(d[end] === 0 && d[end + 1] === 0 && (d[end + 2] === 1 || d[end + 2] === 0))) end++;
      return d.subarray(start, end + 2 < d.length ? end : d.length);
    }
    return null;
  }

  // Draws decoded frames on `canvas`. Shows a waiting card while nothing is live.
  function create(canvas, { onState = () => {}, waitingText = "Waiting for LiveChar…" } = {}) {
    const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
    let dec = null, sig = "", needKey = true, live = false, lastFrame = 0, closed = false;
    if (!canvas.width || canvas.width === 300) { canvas.width = 1280; canvas.height = 720; }

    function setLive(v) { if (live !== v) { live = v; onState(v ? "live" : "waiting"); } }
    function waiting() {
      const W = canvas.width, H = canvas.height;
      ctx.fillStyle = "#0e1020"; ctx.fillRect(0, 0, W, H);
      const g = ctx.createLinearGradient(W * 0.3, 0, W * 0.7, 0);
      g.addColorStop(0, "#4fd8eb"); g.addColorStop(1, "#ff5c8a");
      const r = Math.round(Math.min(W, H) * 0.035), t = (performance.now() / 600) % (Math.PI * 2);
      ctx.globalAlpha = 0.55 + 0.45 * Math.sin(t);
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(W / 2, H / 2 - r * 2.2, r, 0, Math.PI * 2); ctx.fill();
      ctx.globalAlpha = 1;
      ctx.fillStyle = "#eef0ff"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.font = `600 ${Math.round(H * 0.045)}px system-ui, -apple-system, Segoe UI, sans-serif`;
      ctx.fillText(waitingText, W / 2, H / 2 + r);
    }
    // keep frames flowing while waiting (a captured canvas only sends frames when it is drawn on)
    const idle = setInterval(() => { if (!live || performance.now() - lastFrame > 4000) { setLive(false); waiting(); } }, 250);
    waiting(); onState("waiting");

    function configure(codec) {
      try { dec?.close(); } catch {}
      dec = new VideoDecoder({
        output: (f) => {
          if (canvas.width !== f.displayWidth || canvas.height !== f.displayHeight) { canvas.width = f.displayWidth; canvas.height = f.displayHeight; }
          ctx.drawImage(f, 0, 0); f.close();
          lastFrame = performance.now(); setLive(true);
        },
        error: (e) => { console.warn("LiveChar decoder:", e?.message || e); dec = null; sig = ""; needKey = true; },
      });
      dec.configure({ codec, optimizeForLatency: true });
    }

    function push(buf) {
      if (closed) return;
      const u = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
      if (u.length < 9) return;
      const flags = u[0];
      if (flags & 2) { needKey = true; lastFrame = 0; setLive(false); waiting(); return; }
      const key = (flags & 1) === 1;
      const ts = Number(new DataView(u.buffer, u.byteOffset + 1, 8).getBigUint64(0));
      const data = u.subarray(9);
      if (key) {
        const sps = findSps(data);
        if (sps) {
          const s = Array.from(sps, hex).join("");
          if (!dec || dec.state === "closed" || s !== sig) { configure(`avc1.${hex(sps[1])}${hex(sps[2])}${hex(sps[3])}`); sig = s; }
        }
        if (dec) needKey = false;
      }
      if (needKey || !dec || dec.state !== "configured") return;
      if (!key && dec.decodeQueueSize > 8) { needKey = true; return; }   // fell behind: skip to the next keyframe
      try { dec.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: ts, data })); }
      catch (e) { console.warn("LiveChar decode:", e?.message || e); needKey = true; }
    }

    return {
      push,
      get live() { return live; },
      close() { closed = true; clearInterval(idle); try { dec?.close(); } catch {} dec = null; },
    };
  }

  // Reads a watch stream and calls onPacket(Uint8Array) per packet. Reconnects until signal aborts.
  async function follow(url, onPacket, { signal, onStatus = () => {} } = {}) {
    while (!signal?.aborted) {
      try {
        const r = await fetch(url, { signal, cache: "no-store" });
        if (r.status === 404) { onStatus("unknown"); await sleep(10000, signal); continue; }
        if (!r.ok || !r.body) throw new Error(`HTTP ${r.status}`);
        onStatus("connected");
        const reader = r.body.getReader();
        let buf = new Uint8Array(0);
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          const next = new Uint8Array(buf.length + value.length);
          next.set(buf); next.set(value, buf.length); buf = next;
          let o = 0;
          while (buf.length - o >= 4) {
            const len = new DataView(buf.buffer, buf.byteOffset + o, 4).getUint32(0);
            if (buf.length - o - 4 < len) break;
            if (len) onPacket(buf.slice(o + 4, o + 4 + len));
            o += 4 + len;
          }
          buf = buf.slice(o);
        }
      } catch (e) {
        if (signal?.aborted) return;
        onStatus("offline");
      }
      await sleep(1500, signal);
    }
  }
  const sleep = (ms, signal) => new Promise((ok) => { const t = setTimeout(ok, ms); signal?.addEventListener("abort", () => { clearTimeout(t); ok(); }, { once: true }); });

  // "https://host/watch/ID" (or just the link pasted with spaces) -> { origin, id, stream, info }
  function parseLink(link) {
    try {
      const u = new URL(String(link || "").trim());
      const m = u.pathname.match(/\/watch\/([A-Za-z0-9_-]{6,})/);
      if (!m || !/^https?:$/.test(u.protocol)) return null;
      return { origin: u.origin, id: m[1], stream: `${u.origin}/api/share/${m[1]}/stream`, info: `${u.origin}/api/share/${m[1]}/info` };
    } catch { return null; }
  }

  globalThis.LiveCharPlayer = { create, follow, parseLink, supported: typeof VideoDecoder === "function" };
})();
