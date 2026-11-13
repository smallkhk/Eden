// Natural voice changer for the web / Windows app (same engine as the iOS app):
// mic → phrases split at short pauses → /api/voice/convert (ElevenLabs speech-to-speech) → the new voice.
// Each phrase keeps the moment it was spoken, so it can be put back in line with the lips.

// Splits 16 kHz mono speech into phrases (port of Courier's SpeechChunker).
class SpeechChunker {
  constructor() {
    this.frame = 320; this.frameMs = 20; this.pauseMs = 350; this.maxMs = 2500; this.minSpeechMs = 200; this.preRollFrames = 6;
    this.pending = new Int16Array(0); this.pendingT = 0;
    this.frames = []; this.start = 0; this.pre = []; this.speaking = false; this.silent = 0; this.speech = 0; this.noise = 300;
  }
  push(samples, t) {
    if (!this.pending.length) this.pendingT = t;
    const p = new Int16Array(this.pending.length + samples.length); p.set(this.pending); p.set(samples, this.pending.length); this.pending = p;
    const out = [];
    while (this.pending.length >= this.frame) {
      const f = this.pending.slice(0, this.frame); this.pending = this.pending.slice(this.frame);
      const ft = this.pendingT; this.pendingT += this.frameMs;
      const ph = this.feed(f, ft); if (ph) out.push(ph);
    }
    return out;
  }
  flush() {
    const ok = this.speaking && this.speech >= this.minSpeechMs;
    const n = this.frames.reduce((a, f) => a + f.length, 0), pcm = new Int16Array(n);
    let o = 0; for (const f of this.frames) { pcm.set(f, o); o += f.length; }
    const r = ok ? { pcm, start: this.start } : null;
    this.frames = []; this.speaking = false; this.silent = 0; this.speech = 0;
    return r;
  }
  feed(f, t) {
    let sum = 0; for (let i = 0; i < f.length; i++) sum += f[i] * f[i];
    const level = Math.sqrt(sum / f.length), loud = level > Math.max(500, this.noise * 3);
    if (!this.speaking) {
      if (!loud) this.noise = this.noise * 0.95 + level * 0.05;
      this.pre.push([f, t]); if (this.pre.length > this.preRollFrames) this.pre.shift();
      if (loud) { this.speaking = true; this.frames = this.pre.map((x) => x[0]); this.start = this.pre[0][1]; this.pre = []; this.speech = this.frameMs; this.silent = 0; }
      return null;
    }
    this.frames.push(f);
    if (loud) { this.speech += this.frameMs; this.silent = 0; } else this.silent += this.frameMs;
    if (this.silent >= this.pauseMs || this.frames.length * this.frameMs >= this.maxMs) return this.flush();
    return null;
  }
}

export class WebVoice {
  // onPhrase(Float32Array 16 kHz, spokenAtMs performance.now) for every converted phrase
  constructor({ voiceId, micId = "", onPhrase, onState = () => {}, onError = () => {}, onBalance = () => {} }) {
    Object.assign(this, { voiceId, micId, onPhrase, onState, onError, onBalance });
    this.chunker = new SpeechChunker();
    this.queue = []; this.busy = false; this.stopped = false;
  }

  async start() {
    this.mic = await navigator.mediaDevices.getUserMedia({
      audio: { deviceId: this.micId ? { exact: this.micId } : undefined, channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    this.ctx = new AudioContext({ sampleRate: 16000 });
    const src = this.ctx.createMediaStreamSource(this.mic);
    this.proc = this.ctx.createScriptProcessor(1024, 1, 1);
    const mute = this.ctx.createGain(); mute.gain.value = 0;
    this.proc.onaudioprocess = (e) => {
      if (this.stopped) return;
      const x = e.inputBuffer.getChannelData(0), pcm = new Int16Array(x.length);
      for (let i = 0; i < x.length; i++) pcm[i] = Math.max(-32768, Math.min(32767, Math.round(x[i] * 32768)));
      const t = performance.now() - (x.length / 16000) * 1000 - (this.ctx.baseLatency || 0) * 1000;
      for (const ph of this.chunker.push(pcm, t)) this.queue.push(ph);
      if (this.queue.length > 4) this.queue.splice(0, this.queue.length - 4);   // far behind: drop old phrases
      this.next();
    };
    src.connect(this.proc); this.proc.connect(mute); mute.connect(this.ctx.destination);
    await this.ctx.resume();
    this.onState("listening");
  }

  async next() {
    if (this.busy || this.stopped || !this.queue.length) return;
    this.busy = true;
    const ph = this.queue.shift();
    try { await this.convert(ph); } catch { if (!this.stopped) this.onState("network problem, trying the next phrase"); }
    this.busy = false;
    this.next();
  }

  async convert({ pcm, start }) {
    this.onState("changing voice…");
    const r = await fetch(`/api/voice/convert?voice=${encodeURIComponent(this.voiceId)}`, {
      method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: pcm.buffer,
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      this.onError(j.error || `Voice error (HTTP ${r.status})`, r.status);
      return;
    }
    const bal = Number(r.headers.get("X-Balance")); if (Number.isFinite(bal) && r.headers.get("X-Balance")) this.onBalance(bal);
    const bytes = new Uint8Array(await r.arrayBuffer());
    const n = bytes.length >> 1; if (!n) return;
    const dv = new DataView(bytes.buffer), f = new Float32Array(n);
    for (let i = 0; i < n; i++) f[i] = dv.getInt16(i * 2, true) / 32768;
    this.onPhrase(f, start);
    this.onState("listening");
  }

  stop() {
    this.stopped = true; this.queue = [];
    try { this.proc?.disconnect(); } catch {}
    this.mic?.getTracks().forEach((t) => t.stop());
    this.ctx?.close().catch(() => {});
  }
}

// Plays the new voice at the right moment on a timeline that runs `delayMs` behind real time,
// to an output device (speakers / a virtual cable) and into a MediaStream for recordings.
export class VoiceOut {
  constructor() {
    this.ctx = new AudioContext({ latencyHint: "interactive" });
    this.dest = this.ctx.createMediaStreamDestination();      // for recordings
    this.speaker = this.ctx.createGain(); this.speaker.connect(this.ctx.destination);
    this.speaker.gain.value = 0;
  }
  setHear(on) { this.speaker.gain.value = on ? 1 : 0; }
  async setDevice(id) { if (this.ctx.setSinkId) { try { await this.ctx.setSinkId(id || ""); return true; } catch { return false; } } return false; }
  get stream() { return this.dest.stream; }
  resume() { if (this.ctx.state === "suspended") this.ctx.resume().catch(() => {}); }
  // plays at performance time `atMs` (or as soon as possible if that has passed)
  play(f32, atMs) {
    this.resume();
    const ts = this.ctx.getOutputTimestamp ? this.ctx.getOutputTimestamp() : {};
    const ctxNow = ts.contextTime ?? this.ctx.currentTime, perfNow = ts.performanceTime ?? performance.now();
    const when = Math.max(this.ctx.currentTime + 0.02, ctxNow + (atMs - perfNow) / 1000);
    const buf = this.ctx.createBuffer(1, f32.length, 16000); buf.copyToChannel(f32, 0);
    const s = this.ctx.createBufferSource(); s.buffer = buf;
    s.connect(this.dest); s.connect(this.speaker);
    s.start(when);
  }
  close() { this.ctx.close().catch(() => {}); }
}

// Holds the output video back by `delayMs` (so it lines up with the new voice) and plays it in a
// <video> element: for the virtual camera and recordings while the voice changer is on.
export class DelayLine {
  constructor(source, delayMs) {
    this.source = source; this.delayMs = delayMs; this.frames = [];
    this.canvas = document.createElement("canvas"); this.canvas.width = 1280; this.canvas.height = 720;
    this.cx = this.canvas.getContext("2d");
    this.cx.fillStyle = "#000"; this.cx.fillRect(0, 0, 1280, 720);
    this.video = document.createElement("video");
    this.video.id = "outDelayed"; this.video.muted = true; this.video.playsInline = true; this.video.hidden = true;
    this.video.srcObject = this.canvas.captureStream(30);
    document.body.append(this.video); this.video.play().catch(() => {});
    this.grab = setInterval(() => this.capture(), 1000 / 30);
    this.draw = setInterval(() => this.release(), 10);
  }
  capture() {
    const v = this.source;
    if (!(v.readyState >= 2 && v.videoWidth)) return;
    try { this.frames.push({ t: performance.now(), f: new VideoFrame(v, { timestamp: Math.round(performance.now() * 1000) }) }); } catch {}
    while (this.frames.length > 300) this.frames.shift().f.close();
  }
  release() {
    const due = performance.now() - this.delayMs;
    let show = null;
    while (this.frames.length && this.frames[0].t <= due) { if (show) show.close(); show = this.frames.shift().f; }
    if (!show) return;
    if (this.canvas.width !== show.displayWidth || this.canvas.height !== show.displayHeight) { this.canvas.width = show.displayWidth; this.canvas.height = show.displayHeight; }
    this.cx.drawImage(show, 0, 0); show.close();
  }
  close() {
    clearInterval(this.grab); clearInterval(this.draw);
    for (const x of this.frames) x.f.close();
    this.frames = []; this.video.remove();
  }
}
