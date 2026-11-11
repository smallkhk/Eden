// End-to-end check on a Windows 11 class machine:
// start the real helper, send a test picture the way the app does, read it back through the camera.
// Usage: node e2e.cjs <LiveCharCam.exe> <camtest.exe>     (LCV_FORCE_FILE=1: file hand-off, LCV_NO_FRAMES=1: send nothing)
const { spawn } = require("node:child_process");
const { openWincam, W, H } = require("../../wincam.js");

const [helper, reader] = process.argv.slice(2);
const rgba = new Uint8ClampedArray(W * H * 4);
const put = (x0, y0, x1, y1, r, g, b) => { for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const i = (y * W + x) * 4; rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255; } };
put(0, 0, W / 2, H, 255, 0, 0);              // left half red
put(W / 2, 0, W, H, 0, 0, 255);              // right half blue
put(540, 260, 740, 460, 0, 255, 0);          // green square in the middle
put(0, 0, 100, 100, 255, 255, 255);          // white square top-left

const cam = openWincam({ helper, forceFile: !!process.env.LCV_FORCE_FILE });
const started = Date.now();
const wait = setInterval(() => {
  if (cam.state() === "error") { console.log("HELPER ERROR:", cam.error()); clearInterval(wait); process.exit(2); }
  if (cam.state() !== "ready") { if (Date.now() - started > 15000) { console.log("HELPER TIMEOUT"); process.exit(2); } return; }
  clearInterval(wait);
  console.log("helper ready, frames go through:", cam.kind());
  if (!process.env.LCV_NO_FRAMES) setInterval(() => cam.sendRgba(rgba), 33);
  setTimeout(() => {
    const r = spawn(reader, [], { stdio: "inherit" });
    r.on("error", (e) => { console.log("READER ERROR", e.message); cam.close(); process.exit(2); });
    r.on("exit", (code) => { console.log("reader exit code:", code); cam.close(); setTimeout(() => process.exit(code || 0), 500); });
  }, 1500);
}, 100);
