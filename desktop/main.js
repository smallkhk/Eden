const { app, BrowserWindow, Menu, Tray, ipcMain, shell, dialog, globalShortcut, nativeImage } = require("electron");
const path = require("node:path");
const fs = require("node:fs");

// Keep video + the frame pump running while another app is in front.
app.commandLine.appendSwitch("disable-renderer-backgrounding");
app.commandLine.appendSwitch("disable-background-timer-throttling");
app.commandLine.appendSwitch("disable-backgrounding-occluded-windows");
app.commandLine.appendSwitch("disable-features", "CalculateNativeWinOcclusion");
// Use the graphics card for video decoding and drawing even on older drivers.
app.commandLine.appendSwitch("ignore-gpu-blocklist");

if (!app.requestSingleInstanceLock()) app.quit();

const userCfgPath = () => path.join(app.getPath("userData"), "config.json");
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return {}; } };

function normalizeUrl(raw) {
  let u;
  try { u = new URL(String(raw || "").trim()); } catch { return null; }
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) return null;
  return u.origin + "/";
}
// Build-time URL (config.json, written by CI) wins unless the user set their own.
function serverUrl() {
  return normalizeUrl(process.env.LIVECHAR_URL) || normalizeUrl(readJson(userCfgPath()).url) ||
         normalizeUrl(readJson(path.join(__dirname, "config.json")).url);
}

function softcamPath() {
  if (process.env.LIVECHAR_SOFTCAM) return process.env.LIVECHAR_SOFTCAM; // dev/testing
  const base = app.isPackaged ? process.resourcesPath : __dirname;
  return path.join(base, "softcam", "x64", "softcam.dll");
}

const ICON = path.join(__dirname, "icon.png");
const HOTKEYS = [
  ["Ctrl+Alt+S", "toggle", "Start / stop"],
  ["Ctrl+Alt+Up", "zoomIn", "Zoom in"],
  ["Ctrl+Alt+Down", "zoomOut", "Zoom out"],
  ["Ctrl+Alt+0", "zoomReset", "Reset zoom"],
  ["Ctrl+Alt+V", "vcam", "Virtual camera on / off"],
  ["Ctrl+Alt+P", "photo", "Take a photo"],
  ["Ctrl+Alt+R", "record", "Start / stop recording"],
];
const sendHotkey = (name) => win?.webContents.send("hotkey", name);
const showWindow = () => { if (!win) return; win.show(); if (win.isMinimized()) win.restore(); win.focus(); };

let win = null, tray = null, trayTipShown = false;
function createWindow() {
  const url = serverUrl();
  const origin = url ? new URL(url).origin : "";

  win = new BrowserWindow({
    width: 1360, height: 820, minWidth: 900, minHeight: 600,
    backgroundColor: "#0b0d12", title: "LiveChar", autoHideMenuBar: true, icon: ICON,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true, nodeIntegration: false,
      sandbox: false,               // preload loads the native virtual-camera library
      backgroundThrottling: false,
      additionalArguments: [`--livechar-origin=${origin}`, `--livechar-softcam=${softcamPath()}`],
    },
  });

  // Only the configured server gets the camera; nothing else gets any permission.
  const ses = win.webContents.session;
  const okOrigin = (wc) => { try { return !!origin && new URL(wc.getURL()).origin === origin; } catch { return false; } };
  ses.setPermissionRequestHandler((wc, permission, cb) => cb(permission === "media" && okOrigin(wc)));
  ses.setPermissionCheckHandler((wc, permission) => permission === "media" && !!wc && okOrigin(wc));

  // Stay on the configured server; open anything else in the default browser.
  const external = (target) => { if (/^https?:/i.test(target)) shell.openExternal(target); };
  win.webContents.setWindowOpenHandler(({ url: t }) => { external(t); return { action: "deny" }; });
  win.webContents.on("will-navigate", (ev, t) => {
    let same = false;
    try { same = (!!origin && new URL(t).origin === origin) || t.startsWith("file:"); } catch {}
    if (!same) { ev.preventDefault(); external(t); }
  });
  win.webContents.on("did-fail-load", (_e, code, desc, failedUrl, isMain) => {
    if (!isMain || code === -3) return;
    dialog.showMessageBox(win, {
      type: "error", message: "Could not reach the LiveChar server", detail: `${failedUrl}\n${desc}`,
      buttons: ["Retry", "Change server"],
    }).then(({ response }) => (response === 0 ? win.loadURL(failedUrl) : win.loadFile(path.join(__dirname, "setup.html"))));
  });

  if (url) win.loadURL(url); else win.loadFile(path.join(__dirname, "setup.html"));
  // Minimize goes to the tray and keeps the video + virtual camera running. Closing the window quits.
  win.on("minimize", (ev) => {
    ev.preventDefault(); win.hide();
    if (!trayTipShown && process.platform === "win32") {
      trayTipShown = true;
      tray?.displayBalloon({ title: "LiveChar is still running", content: "It keeps working from the tray. Click the icon to bring it back." });
    }
  });
  win.on("closed", () => { win = null; });
}

ipcMain.handle("setup:current", () => readJson(userCfgPath()).url || "");
ipcMain.handle("setup:save", (_e, raw) => {
  const url = normalizeUrl(raw);
  if (!url) return { error: "Enter a valid https:// address" };
  fs.mkdirSync(path.dirname(userCfgPath()), { recursive: true });
  fs.writeFileSync(userCfgPath(), JSON.stringify({ url }, null, 2));
  app.relaunch(); app.exit(0);
  return { ok: true };
});

function setupAutoUpdate() {
  if (!app.isPackaged) return;
  let autoUpdater;
  try { ({ autoUpdater } = require("electron-updater")); } catch { return; }
  autoUpdater.autoDownload = true;
  autoUpdater.on("error", (e) => console.error("update:", e?.message || e));
  autoUpdater.on("update-downloaded", async (info) => {
    const { response } = await dialog.showMessageBox(win, {
      type: "info", message: `LiveChar ${info.version} is ready to install`, detail: "Restart now to update? Any live session will stop.",
      buttons: ["Restart now", "Later"], defaultId: 0, cancelId: 1,
    });
    if (response === 0) autoUpdater.quitAndInstall();   // "Later" installs on next quit
  });
  const check = () => autoUpdater.checkForUpdates().catch(() => {});
  check(); setInterval(check, 6 * 3600000);
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: "LiveChar", submenu: [
      { label: "Change server…", click: () => win?.loadFile(path.join(__dirname, "setup.html")) },
      { label: "Hotkeys…", click: () => dialog.showMessageBox(win, { type: "info", message: "Hotkeys (work even when another app is in front)", detail: HOTKEYS.map(([k, , what]) => `${k}   ${what}`).join("\n") }) },
      { label: "Reload", accelerator: "CmdOrCtrl+R", click: () => win?.webContents.reload() },
      { type: "separator" }, { role: "quit" },
    ] },
  ]));
  createWindow();

  tray = new Tray(nativeImage.createFromPath(ICON).resize({ width: 16, height: 16 }));
  tray.setToolTip("LiveChar");
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "Show LiveChar", click: showWindow },
    { label: "Start / stop", click: () => sendHotkey("toggle") },
    { type: "separator" }, { label: "Quit", click: () => app.quit() },
  ]));
  tray.on("click", showWindow);

  for (const [keys, name] of HOTKEYS) {
    try { if (!globalShortcut.register(keys, () => sendHotkey(name))) console.warn("hotkey in use by another app:", keys); }
    catch (e) { console.warn("hotkey failed:", keys, e?.message); }
  }
  setupAutoUpdate();
});
app.on("second-instance", showWindow);
app.on("will-quit", () => globalShortcut.unregisterAll());
app.on("window-all-closed", () => app.quit());
