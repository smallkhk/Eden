// Thin wrapper over softcam.dll (https://github.com/tshino/softcam, MIT).
// Frames are BGR24, top-down, WIDTH x HEIGHT.
const koffi = require("koffi");

function rgbaToBgr(rgba, bgr) {
  for (let i = 0, j = 0, n = rgba.length; i < n; i += 4, j += 3) {
    bgr[j] = rgba[i + 2];
    bgr[j + 1] = rgba[i + 1];
    bgr[j + 2] = rgba[i];
  }
  return bgr;
}

function openVcam(libPath, width, height) {
  if (width % 4 || height % 4) throw new Error("Width and height must be multiples of 4");
  const lib = koffi.load(libPath);
  const scCreateCamera = lib.func("void* __cdecl scCreateCamera(int width, int height, float framerate)");
  const scDeleteCamera = lib.func("void __cdecl scDeleteCamera(void* camera)");
  const scSendFrame = lib.func("void __cdecl scSendFrame(void* camera, const void* image_bits)");
  const scIsConnected = lib.func("bool __cdecl scIsConnected(void* camera)");

  // framerate 0 = send every frame immediately (we already have a realtime source)
  let cam = scCreateCamera(width, height, 0);
  if (!cam) throw new Error("Virtual camera could not start (already in use by another app, or not installed)");
  const bgr = Buffer.alloc(width * height * 3);

  return {
    width, height,
    sendRgba(rgba) { if (cam) scSendFrame(cam, rgbaToBgr(rgba, bgr)); },
    connected() { return cam ? !!scIsConnected(cam) : false; },
    close() { if (cam) { scDeleteCamera(cam); cam = null; } },
  };
}

module.exports = { openVcam, rgbaToBgr };
