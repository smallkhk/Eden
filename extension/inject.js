// Runs in the page (MAIN world) before the page's own scripts.
// Makes getUserMedia hand out the LiveChar iPhone stream as a camera, and lists it in enumerateDevices.
// The video arrives from bridge.js (extension world) over a private MessageChannel, so the page's
// Content-Security-Policy can't block the download.
(() => {
  if (window.__livecharCamera) return;
  Object.defineProperty(window, "__livecharCamera", { value: true });
  if (typeof MediaDevices === "undefined" || !MediaDevices.prototype.getUserMedia) return;

  const DEVICE_ID = "livechar-iphone-camera";
  const GROUP_ID = "livechar";
  const LABEL = "LiveChar (iPhone)";
  const MIC_ID = "livechar-iphone-voice";
  const MIC_LABEL = "LiveChar voice (iPhone)";
  const proto = MediaDevices.prototype;
  const realGetUserMedia = proto.getUserMedia;
  const realEnumerate = proto.enumerateDevices;

  // ---- link to bridge.js ----
  let port = null, cfg = null;
  const cfgWaiters = [];
  const getConfig = () => cfg ? Promise.resolve(cfg) : new Promise((ok) => {
    cfgWaiters.push(ok);
    setTimeout(() => ok(cfg || { enabled: false }), 1500);   // no bridge (e.g. a sandboxed frame): behave normally
  });
  window.addEventListener("message", (e) => {
    if (port || e.source !== window || !e.data || e.data.__livechar_bridge !== 1 || !e.ports || !e.ports[0]) return;
    e.stopImmediatePropagation();
    port = e.ports[0];
    port.onmessage = (m) => {
      const d = m.data || {};
      if (d.type === "config") { cfg = d; cfgWaiters.splice(0).forEach((f) => f(cfg)); }
      else if (d.type === "pkt" && shared) shared.player.push(new Uint8Array(d.buf));
    };
    if (shared) port.postMessage({ type: "open" });
  }, true);

  // ---- one decoder + canvas shared by every track handed out ----
  let shared = null;
  function acquireTrack(kind = "video") {
    if (!shared) {
      const canvas = document.createElement("canvas");
      canvas.width = 1280; canvas.height = 720;
      const player = LiveCharPlayer.create(canvas, { waitingText: "Waiting for LiveChar on your iPhone…", audio: "stream" });
      const stream = canvas.captureStream(30);
      shared = { canvas, player, stream, users: 0 };
      port?.postMessage({ type: "open" });
    }
    shared.users++;
    const src = kind === "audio" ? shared.player.audioStream().getAudioTracks()[0] : shared.stream.getVideoTracks()[0];
    const track = src.clone();
    dress(track, kind);
    return track;
  }
  function release() {
    if (!shared || --shared.users > 0) return;
    port?.postMessage({ type: "close" });
    shared.player.close();
    shared.stream.getTracks().forEach((t) => t.stop());
    shared = null;
  }
  function dress(track, kind = "video") {
    let released = false;
    const done = () => { if (!released) { released = true; release(); } };
    const stop = track.stop.bind(track);
    Object.defineProperty(track, "stop", { configurable: true, value: () => { stop(); done(); } });
    track.addEventListener("ended", done);
    Object.defineProperty(track, "label", { configurable: true, get: () => (kind === "audio" ? MIC_LABEL : LABEL) });
    const settings = track.getSettings.bind(track);
    Object.defineProperty(track, "getSettings", { configurable: true, value: () => ({ ...settings(), deviceId: kind === "audio" ? MIC_ID : DEVICE_ID, groupId: GROUP_ID }) });
    const clone = track.clone.bind(track);
    Object.defineProperty(track, "clone", { configurable: true, value: () => { shared && shared.users++; const c = clone(); dress(c, kind); return c; } });
  }

  // which camera the page asked for: true = ours, false = another one, null = any
  function asksForUs(c, id = DEVICE_ID) {
    if (!c || c === true) return null;
    const d = c.deviceId;
    if (d == null) return null;
    const ids = typeof d === "string" ? [d] : Array.isArray(d) ? d : [d.exact, d.ideal].flat().filter(Boolean);
    return ids.length ? ids.includes(id) : null;
  }

  function fakeDevice(kind = "videoinput") {
    const info = kind === "audioinput"
      ? { deviceId: MIC_ID, kind, label: MIC_LABEL, groupId: GROUP_ID }
      : { deviceId: DEVICE_ID, kind, label: LABEL, groupId: GROUP_ID };
    const props = {};
    for (const [k, v] of Object.entries(info)) props[k] = { value: v, enumerable: true };
    props.toJSON = { value: () => ({ ...info }) };
    return Object.create(MediaDeviceInfo.prototype, props);
  }

  proto.getUserMedia = async function (constraints) {
    const c = await getConfig();
    if (!c.enabled || !constraints) return realGetUserMedia.call(this, constraints);
    const vWant = constraints.video ? asksForUs(constraints.video) : false;
    const useCam = !!constraints.video && (vWant === true || (vWant === null && c.replaceAll));
    // the new voice as the microphone: only when turned on in the extension
    const aWant = constraints.audio ? asksForUs(constraints.audio, MIC_ID) : false;
    const useMic = !!constraints.audio && c.voice && (aWant === true || (aWant === null && c.replaceAll));
    if (!useCam && !useMic) return realGetUserMedia.call(this, constraints);
    const out = new MediaStream();
    const rest = {};
    if (constraints.video && !useCam) rest.video = constraints.video;
    if (constraints.audio && !useMic) rest.audio = constraints.audio;    // the real microphone/camera for the rest
    if (rest.video || rest.audio) (await realGetUserMedia.call(this, rest)).getTracks().forEach((t) => out.addTrack(t));
    if (useMic) out.addTrack(acquireTrack("audio"));
    if (useCam) out.addTrack(acquireTrack("video"));
    return out;
  };

  proto.enumerateDevices = async function () {
    const list = await realEnumerate.call(this);
    const c = await getConfig();
    if (!c.enabled) return list;
    // "for every request": hide the real ones so no picker offers a device that won't be used
    const hide = (d) => c.replaceAll && (d.kind === "videoinput" || (c.voice && d.kind === "audioinput"));
    const ours = [fakeDevice("videoinput")];
    if (c.voice) ours.push(fakeDevice("audioinput"));
    return [...ours, ...list.filter((d) => !hide(d))];
  };

  // old callback API
  for (const name of ["getUserMedia", "webkitGetUserMedia"]) {
    if (typeof navigator[name] === "function") {
      navigator[name] = (c, ok, bad) => navigator.mediaDevices.getUserMedia(c).then(ok, bad);
    }
  }
})();
