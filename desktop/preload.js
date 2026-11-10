const { contextBridge, ipcRenderer } = require("electron");

const arg = (name) => (process.argv.find((a) => a.startsWith(`--${name}=`)) || "").split("=").slice(1).join("=");
const ALLOWED_ORIGIN = arg("livechar-origin");
const SOFTCAM = arg("livechar-softcam");

const FPS = 30;
let W = 1280, H = 720;   // 1280x720 landscape or 720x1280 portrait

if (location.protocol === "file:") {
  // first-run / "Change server" page
  contextBridge.exposeInMainWorld("livecharSetup", {
    current: () => ipcRenderer.invoke("setup:current"),
    save: (url) => ipcRenderer.invoke("setup:save", url),
  });
} else if (ALLOWED_ORIGIN && location.origin === ALLOWED_ORIGIN) {
  let cam = null, timer = null, ctx = null;
  const view = { z: 1, ox: 0, oy: 0 };   // output zoom + pan, set by the page

  function pump(videoId) {
    const v = document.getElementById(videoId);
    ctx.fillStyle = "#000"; ctx.fillRect(0, 0, W, H);
    if (v && v.readyState >= 2 && v.videoWidth) {
      const s = Math.min(W / v.videoWidth, H / v.videoHeight);       // letterbox, never crop
      const dw = v.videoWidth * s, dh = v.videoHeight * s;
      ctx.save();
      ctx.translate(W / 2, H / 2); ctx.scale(view.z, view.z);
      ctx.translate(view.ox * W - W / 2, view.oy * H - H / 2);
      ctx.drawImage(v, (W - dw) / 2, (H - dh) / 2, dw, dh);
      ctx.restore();
    }
    cam.sendRgba(ctx.getImageData(0, 0, W, H).data);
  }

  function stop() {
    clearInterval(timer); timer = null;
    try { cam?.close(); } catch {}
    cam = null;
  }

  const hotkeyHandlers = [];
  ipcRenderer.on("hotkey", (_e, name) => { for (const h of hotkeyHandlers) { try { h(String(name)); } catch (e) { console.error("hotkey:", e); } } });

  contextBridge.exposeInMainWorld("livecharDesktop", {
    onHotkey(handler) { if (typeof handler === "function") hotkeyHandlers.push(handler); },
    vcam: {
      name: "DirectShow Softcam",
      start(videoId = "outV", w = 1280, h = 720) {
        if (cam) return { ok: true };
        try {
          [W, H] = +w === 720 && +h === 1280 ? [720, 1280] : [1280, 720];
          const { openVcam } = require("./vcam.js");
          cam = openVcam(SOFTCAM, W, H);
          const c = document.createElement("canvas"); c.width = W; c.height = H;
          ctx = c.getContext("2d", { willReadFrequently: true });
          timer = setInterval(() => { try { pump(videoId); } catch (e) { console.error("vcam:", e); } }, 1000 / FPS);
          return { ok: true };
        } catch (e) {
          stop();
          return { ok: false, error: String(e?.message || e) };
        }
      },
      stop() { stop(); return { ok: true }; },
      setView(z, ox, oy) {
        const n = (x, d) => (Number.isFinite(+x) ? +x : d);
        view.z = Math.min(4, Math.max(1, n(z, 1)));
        const lim = (view.z - 1) / (2 * view.z);
        view.ox = Math.min(lim, Math.max(-lim, n(ox, 0)));
        view.oy = Math.min(lim, Math.max(-lim, n(oy, 0)));
      },
      active: () => !!cam,
      connected: () => (cam ? cam.connected() : false),
    },
  });
  window.addEventListener("pagehide", stop);
}
