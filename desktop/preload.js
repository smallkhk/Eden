const { contextBridge, ipcRenderer } = require("electron");

const arg = (name) => (process.argv.find((a) => a.startsWith(`--${name}=`)) || "").split("=").slice(1).join("=");
const ALLOWED_ORIGIN = arg("livechar-origin");
const SOFTCAM = arg("livechar-softcam");
const WINCAM_DIR = arg("livechar-wincam");          // empty unless Windows 11 and the camera is installed
const WINCAM_HELPER = arg("livechar-wincam-helper"); // testing only
const WIN_W = 1280, WIN_H = 720;

const FPS = 30;
let W = 1280, H = 720;   // 1280x720 landscape or 720x1280 portrait

if (location.protocol === "file:") {
  // first-run / "Change server" page
  contextBridge.exposeInMainWorld("livecharSetup", {
    current: () => ipcRenderer.invoke("setup:current"),
    save: (url) => ipcRenderer.invoke("setup:save", url),
  });
} else if (ALLOWED_ORIGIN && location.origin === ALLOWED_ORIGIN) {
  // Two cameras are fed from the same output:
  //   soft = "DirectShow Softcam" (classic apps), win = "LiveChar Camera" (Windows 11, all apps)
  let soft = null, win = null, timer = null, softCtx = null, winCtx = null, softErr = "";
  const view = { z: 1, ox: 0, oy: 0 };   // output zoom + pan, set by the page

  function draw(ctx, v, CW, CH) {
    ctx.fillStyle = "#000"; ctx.fillRect(0, 0, CW, CH);
    if (v && v.readyState >= 2 && v.videoWidth) {
      const s = Math.min(CW / v.videoWidth, CH / v.videoHeight);       // letterbox, never crop
      const dw = v.videoWidth * s, dh = v.videoHeight * s;
      ctx.save();
      ctx.translate(CW / 2, CH / 2); ctx.scale(view.z, view.z);
      ctx.translate(view.ox * CW - CW / 2, view.oy * CH - CH / 2);
      ctx.drawImage(v, (CW - dw) / 2, (CH - dh) / 2, dw, dh);
      ctx.restore();
    }
    return ctx.getImageData(0, 0, CW, CH).data;
  }
  function pump(videoId) {
    const v = document.getElementById(videoId);
    let frame = null;
    if (soft) { frame = draw(softCtx, v, W, H); soft.sendRgba(frame); }
    if (win && win.state() === "ready") {
      // the Windows 11 camera is always 1280x720; reuse the frame when the sizes match
      win.sendRgba(frame && W === WIN_W && H === WIN_H ? frame : draw(winCtx, v, WIN_W, WIN_H));
    }
  }
  const canvasCtx = (w, h) => { const c = document.createElement("canvas"); c.width = w; c.height = h; return c.getContext("2d", { willReadFrequently: true }); };

  function stop() {
    clearInterval(timer); timer = null;
    try { soft?.close(); } catch {}
    try { win?.close(); } catch {}
    soft = null; win = null;
  }

  const hotkeyHandlers = [];
  ipcRenderer.on("hotkey", (_e, name) => { for (const h of hotkeyHandlers) { try { h(String(name)); } catch (e) { console.error("hotkey:", e); } } });

  contextBridge.exposeInMainWorld("livecharDesktop", {
    onHotkey(handler) { if (typeof handler === "function") hotkeyHandlers.push(handler); },
    vcam: {
      name: "DirectShow Softcam",
      start(videoId = "outV", w = 1280, h = 720) {
        if (soft || win) return { ok: true };
        [W, H] = +w === 720 && +h === 1280 ? [720, 1280] : [1280, 720];
        softErr = "";
        try {
          soft = require("./vcam.js").openVcam(SOFTCAM, W, H);
          softCtx = canvasCtx(W, H);
        } catch (e) { soft = null; softErr = String(e?.message || e); }
        if (WINCAM_DIR) {
          try {
            win = require("./wincam.js").openWincam({ helper: WINCAM_HELPER || require("node:path").join(WINCAM_DIR, "LiveCharCam.exe") });
            winCtx = canvasCtx(WIN_W, WIN_H);
          } catch (e) { win = null; console.error("wincam:", e); }
        }
        if (!soft && !win) return { ok: false, error: softErr || "No virtual camera is available" };
        timer = setInterval(() => { try { pump(videoId); } catch (e) { console.error("vcam:", e); } }, 1000 / FPS);
        return { ok: true };
      },
      stop() { stop(); return { ok: true }; },
      // which cameras other apps can pick right now
      info() {
        const names = [];
        const state = win ? win.state() : "off";
        if (state === "ready" || state === "starting") names.push("LiveChar Camera");
        if (soft) names.push("DirectShow Softcam");
        return { names, win11: state, win11Error: win ? win.error() : "", classicError: softErr };
      },
      setView(z, ox, oy) {
        const n = (x, d) => (Number.isFinite(+x) ? +x : d);
        view.z = Math.min(4, Math.max(1, n(z, 1)));
        const lim = (view.z - 1) / (2 * view.z);
        view.ox = Math.min(lim, Math.max(-lim, n(ox, 0)));
        view.oy = Math.min(lim, Math.max(-lim, n(oy, 0)));
      },
      active: () => !!(soft || win),
      connected: () => (soft ? soft.connected() : false),
    },
  });
  window.addEventListener("pagehide", stop);
}
