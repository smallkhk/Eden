// Extension world: reads the settings and downloads the live stream, then hands packets to inject.js.
// (Chrome injects a file only once per frame, so this world can't load player.js too: the two helpers
// it needs are repeated here.)
(() => {
  if (window.__livecharBridge) return;
  window.__livecharBridge = true;

  const sleep = (ms, signal) => new Promise((ok) => { const t = setTimeout(ok, ms); signal?.addEventListener("abort", () => { clearTimeout(t); ok(); }, { once: true }); });
  const LiveCharPlayer = {
    parseLink(link) {
      try {
        const u = new URL(String(link || "").trim());
        const m = u.pathname.match(/\/watch\/([A-Za-z0-9_-]{6,})/);
        if (!m || !/^https?:$/.test(u.protocol)) return null;
        return { origin: u.origin, id: m[1], stream: `${u.origin}/api/share/${m[1]}/stream` };
      } catch { return null; }
    },
    // same as player.js follow(): [u32 length][payload] packets, reconnects until aborted
    async follow(url, onPacket, { signal } = {}) {
      while (!signal?.aborted) {
        try {
          const r = await fetch(url, { signal, cache: "no-store" });
          if (!r.ok || !r.body) throw new Error(`HTTP ${r.status}`);
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
        } catch { if (signal?.aborted) return; }
        await sleep(1500, signal);
      }
    },
  };

  const { port1: port, port2 } = new MessageChannel();
  let cfg = { enabled: true, link: "", replaceAll: true };
  let ac = null, wanted = false;

  const link = () => LiveCharPlayer.parseLink(cfg.link);
  const sendConfig = () => port.postMessage({ type: "config", enabled: !!(cfg.enabled && link()), replaceAll: !!cfg.replaceAll });

  function open() {
    wanted = true;
    if (ac) return;
    const l = link();
    if (!l) return;
    ac = new AbortController();
    LiveCharPlayer.follow(l.stream, (u) => port.postMessage({ type: "pkt", buf: u.buffer }, [u.buffer]), { signal: ac.signal });
  }
  function close() { wanted = false; ac?.abort(); ac = null; }

  port.onmessage = (e) => {
    if (e.data?.type === "open") open();
    else if (e.data?.type === "close") close();
  };

  chrome.storage.local.get({ enabled: true, link: "", replaceAll: true }, (v) => { cfg = v; sendConfig(); });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    for (const [k, { newValue }] of Object.entries(changes)) cfg[k] = newValue;
    sendConfig();
    if (wanted && changes.link) { ac?.abort(); ac = null; open(); }   // new link: switch streams
  });

  window.postMessage({ __livechar_bridge: 1 }, "*", [port2]);
})();
