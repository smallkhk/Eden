// Windows 11 camera ("LiveChar Camera"): start the helper and hand it frames.
// Frame layout is described in wincam/README.md. Frames here are always 1280x720.
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

const W = 1280, H = 720, HEADER = 64, SIZE = HEADER + W * H * 4;
const FILE_MAP_WRITE = 0x0002;

function packFrame(buf, rgba, counter) {
  buf.write("LCVCAM1\0", 0, "latin1");
  buf.writeUInt32LE(W, 8); buf.writeUInt32LE(H, 12); buf.writeUInt32LE(counter >>> 0, 16);
  buf.writeBigUInt64LE(BigInt(Date.now()), 24);
  // RGBA -> BGRA, four bytes at a time
  const src = new Uint32Array(rgba.buffer, rgba.byteOffset, W * H);
  const dst = new Uint32Array(buf.buffer, buf.byteOffset + HEADER, W * H);
  for (let i = 0, n = src.length; i < n; i++) {
    const v = src[i];
    dst[i] = (v & 0xff00ff00) | ((v & 0xff) << 16) | ((v >>> 16) & 0xff);
  }
  return buf;
}

// Shared memory created by the helper (Windows only).
function openSection(kernel32Path = "kernel32.dll") {
  const koffi = require("koffi");
  const k32 = koffi.load(kernel32Path);
  const OpenFileMappingW = k32.func("void* __stdcall OpenFileMappingW(uint32_t access, int inherit, str16 name)");
  const MapViewOfFile = k32.func("void* __stdcall MapViewOfFile(void* mapping, uint32_t access, uint32_t offsetHigh, uint32_t offsetLow, size_t bytes)");
  const UnmapViewOfFile = k32.func("int __stdcall UnmapViewOfFile(void* view)");
  const CloseHandle = k32.func("int __stdcall CloseHandle(void* handle)");
  const RtlMoveMemory = k32.func("void __stdcall RtlMoveMemory(void* dest, const void* src, size_t bytes)");

  const mapping = OpenFileMappingW(FILE_MAP_WRITE, 0, "Local\\LiveCharVCamFrame");
  if (!mapping) throw new Error("shared memory not found");
  const view = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, SIZE);
  if (!view) { CloseHandle(mapping); throw new Error("shared memory could not be mapped"); }
  return {
    kind: "section",
    write(buf) { RtlMoveMemory(view, buf, SIZE); },
    close() { UnmapViewOfFile(view); CloseHandle(mapping); },
  };
}

// Fallback: a fixed-size file the camera maps read-only.
function openFile(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  let fd;
  try {
    if (fs.statSync(filePath).size !== SIZE) throw new Error("resize");
    fd = fs.openSync(filePath, "r+");
  } catch {
    fd = fs.openSync(filePath, "w+");
    fs.writeSync(fd, Buffer.alloc(SIZE), 0, SIZE, 0);
  }
  return {
    kind: "file",
    write(buf) { fs.writeSync(fd, buf, 0, SIZE, 0); },
    close() { try { fs.closeSync(fd); } catch {} },
  };
}

/**
 * opts: { helper, args?, filePath?, kernel32?, forceFile? }
 * Returns { state(), error(), sendRgba(rgba), close() }. state: "starting" | "ready" | "error" | "closed".
 */
function openWincam(opts) {
  const filePath = opts.filePath || path.join(process.env.ProgramData || "C:\\ProgramData", "LiveChar", "vcam.frame");
  const buf = Buffer.alloc(SIZE);
  let state = "starting", error = "", sink = null, counter = 0, out = "";

  const child = spawn(opts.helper, opts.args || [String(process.pid)], { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
  const fail = (msg) => { if (state !== "closed") { state = "error"; error = msg; } };
  child.on("error", (e) => fail(`Could not start the camera helper (${e.code || e.message})`));
  child.on("exit", (code) => { if (state === "starting" || state === "ready") fail(error || `The camera helper stopped (code ${code})`); try { sink?.close(); } catch {} sink = null; });
  child.stdin.on("error", () => {});
  child.stdout.on("data", (d) => {
    out += d.toString("latin1");
    const line = out.split(/\r?\n/).find((l) => /^(READY|ERROR)/.test(l));
    if (!line || state !== "starting") return;
    if (line.startsWith("ERROR")) return fail(explain(line));
    try {
      if (line.includes("section") && !opts.forceFile) { try { sink = openSection(opts.kernel32); } catch (e) { console.warn("wincam: section unavailable, using file:", e.message); } }
      if (!sink) sink = openFile(filePath);
      state = "ready";
    } catch (e) { fail(`Could not open the frame buffer (${e.message})`); }
  });

  function explain(line) {
    const code = (line.match(/0x[0-9A-Fa-f]{8}/) || [""])[0].toUpperCase();
    if (code === "0X80070005") return "Windows blocked the camera. Turn on Settings > Privacy & security > Camera > “Let desktop apps access your camera”, then switch the virtual camera off and on.";
    if (code === "0X80040154") return "The camera is not registered. Reinstall LiveChar.";
    return `Windows could not start the camera (${line.replace(/^ERROR\s*/, "").trim()})`;
  }

  return {
    state: () => state,
    error: () => error,
    kind: () => sink?.kind || "",
    sendRgba(rgba) {
      if (state !== "ready" || !sink) return;
      try { sink.write(packFrame(buf, rgba, ++counter)); }
      catch (e) { fail(`Could not write frames (${e.message})`); }
    },
    close() {
      state = "closed";
      try { child.stdin.end(); } catch {}
      setTimeout(() => { try { child.kill(); } catch {} }, 1500).unref?.();
      try { sink?.close(); } catch {}
      sink = null;
    },
  };
}

module.exports = { openWincam, packFrame, W, H, HEADER, SIZE };
