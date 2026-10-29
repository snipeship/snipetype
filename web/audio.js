/**
 * Procedural WebAudio sound effects for snipetype (no samples).
 *
 * The wasm queues 12-byte records `{kind: u32, pan: f32, intensity: f32}`
 * (see src/web/main.zig `SfxRecord`); the host drains them every frame
 * with `readSfxRecords` and plays each through `SfxEngine.play`.
 *
 * Signal chain: voice → StereoPanner → master gain → compressor (limiter)
 * → destination. The AudioContext is created lazily on the first user
 * gesture (browsers refuse to start audio before one).
 */

/** Sound kinds (wire values match `SfxKind` in src/web/main.zig). */
export const SFX = Object.freeze({
  key_letter: 0,
  key_digit: 1,
  key_big: 2,
  key_arrow: 3,
  wrong: 4,
  miss: 5,
  level_up: 6,
  milestone: 7,
  fx_tier1: 8,
  fx_tier2: 9,
  fx_tier3: 10,
  phrase_done: 11,
  game_over: 12,
  start: 13,
});

export const SFX_RECORD_BYTES = 12;
const SFX_KIND_COUNT = Object.keys(SFX).length;

/**
 * Decode `len` sfx records starting at byte offset `ptr` of `buffer`.
 * @param {ArrayBuffer} buffer wasm memory buffer
 * @returns {{kind:number, pan:number, intensity:number}[]}
 */
export function readSfxRecords(buffer, ptr, len) {
  if (!len || !ptr) return [];
  const words = len * 3;
  if (ptr % 4 !== 0 || ptr + words * 4 > buffer.byteLength) return [];
  const u32 = new Uint32Array(buffer, ptr, words);
  const f32 = new Float32Array(buffer, ptr, words);
  const out = [];
  for (let i = 0; i < len; i++) {
    const kind = u32[i * 3];
    if (kind >= SFX_KIND_COUNT) continue;
    const pan = f32[i * 3 + 1];
    const intensity = f32[i * 3 + 2];
    out.push({
      kind,
      pan: Number.isFinite(pan) ? Math.max(-1, Math.min(1, pan)) : 0,
      intensity: Number.isFinite(intensity) ? Math.max(0, Math.min(1, intensity)) : 0.5,
    });
  }
  return out;
}

/** Max voices started per frame (a 60-cap chain explosion stays sane). */
const MAX_VOICES_PER_FRAME = 10;

export class SfxEngine {
  constructor({ muted = false } = {}) {
    this.muted = muted;
    this.ctx = null;
    this.master = null;
    this.noise = null;
    this.frameVoices = 0;
  }

  /** Create/resume the AudioContext. Call from a user gesture handler. */
  unlock() {
    if (this.muted) return;
    try {
      if (!this.ctx) this.#build();
      if (this.ctx.state === "suspended") this.ctx.resume().catch(() => {});
    } catch {
      this.ctx = null; // WebAudio unavailable: stay silent
    }
  }

  setMuted(muted) {
    this.muted = muted;
    if (!this.ctx) {
      if (!muted) this.unlock();
      return;
    }
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setTargetAtTime(muted ? 0 : 0.8, t, 0.02);
    if (!muted && this.ctx.state === "suspended") this.ctx.resume().catch(() => {});
  }

  /** Reset the per-frame voice budget (call once per animation frame). */
  beginFrame() {
    this.frameVoices = 0;
  }

  get ready() {
    return !this.muted && this.ctx !== null && this.ctx.state === "running";
  }

  /** Play one sound. `pan` -1..1, `intensity` 0..1. */
  play(kind, pan = 0, intensity = 0.5) {
    if (!this.ready) return;
    if (this.frameVoices >= MAX_VOICES_PER_FRAME) return;
    this.frameVoices++;
    const fn = VOICES[kind];
    if (!fn) return;
    const ctx = this.ctx;
    const out = ctx.createStereoPanner();
    out.pan.value = Math.max(-1, Math.min(1, pan || 0));
    out.connect(this.master);
    const t = ctx.currentTime + 0.005;
    const i = Math.max(0, Math.min(1, intensity ?? 0.5));
    try {
      const end = fn(this, out, t, i);
      // Disconnect the voice bus once everything has rung out.
      setTimeout(() => out.disconnect(), Math.max(50, (end - ctx.currentTime) * 1000 + 100));
    } catch {
      out.disconnect();
    }
  }

  #build() {
    const AC = globalThis.AudioContext || globalThis.webkitAudioContext;
    if (!AC) throw new Error("no WebAudio");
    const ctx = new AC({ latencyHint: "interactive" });
    const limiter = ctx.createDynamicsCompressor();
    limiter.threshold.value = -10;
    limiter.knee.value = 0;
    limiter.ratio.value = 20;
    limiter.attack.value = 0.002;
    limiter.release.value = 0.12;
    const master = ctx.createGain();
    master.gain.value = this.muted ? 0 : 0.8;
    master.connect(limiter).connect(ctx.destination);
    // One second of white noise, shared by all noisy voices.
    const noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
    const data = noise.getChannelData(0);
    for (let k = 0; k < data.length; k++) data[k] = Math.random() * 2 - 1;
    this.ctx = ctx;
    this.master = master;
    this.noise = noise;
  }

  // --------------------------------------------------------------------------
  // Building blocks (all return the time the sound has fully decayed)
  // --------------------------------------------------------------------------

  /** Oscillator with an exponential pitch glide and AD envelope. */
  tone(dest, t, { type = "sine", f0, f1 = f0, glide = 0.05, gain = 0.2, attack = 0.002, decay = 0.1 }) {
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    osc.type = type;
    osc.frequency.setValueAtTime(f0, t);
    if (f1 !== f0) osc.frequency.exponentialRampToValueAtTime(Math.max(1, f1), t + glide);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(Math.max(0.0002, gain), t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
    osc.connect(g).connect(dest);
    osc.start(t);
    osc.stop(t + attack + decay + 0.02);
    return t + attack + decay + 0.02;
  }

  /** Filtered noise burst. `sweep` = [f0, f1] glides the filter frequency. */
  burst(dest, t, { filter = "bandpass", freq = 2000, sweep = null, q = 1, gain = 0.2, attack = 0.001, decay = 0.05 }) {
    const ctx = this.ctx;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.loop = true; // random offset + long decays can outrun the 1 s buffer
    const f = ctx.createBiquadFilter();
    f.type = filter;
    f.Q.value = q;
    f.frequency.setValueAtTime(sweep ? sweep[0] : freq, t);
    if (sweep) f.frequency.exponentialRampToValueAtTime(sweep[1], t + attack + decay);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(Math.max(0.0002, gain), t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
    src.connect(f).connect(g).connect(dest);
    const offset = Math.random() * 0.5;
    src.start(t, offset);
    src.stop(t + attack + decay + 0.02);
    return t + attack + decay + 0.02;
  }

  /** Struck bell: fundamental plus inharmonic partials, long decay. */
  bell(dest, t, freq, gain, decay = 1.2) {
    let end = t;
    const partials = [
      [1, 1],
      [2.756, 0.35],
      [5.404, 0.12],
    ];
    for (const [ratio, amp] of partials) {
      end = Math.max(end, this.tone(dest, t, { f0: freq * ratio, gain: gain * amp, attack: 0.003, decay: decay / ratio ** 0.5 }));
    }
    return end;
  }
}

const jitter = (amount) => 1 + (Math.random() * 2 - 1) * amount;

/** Voice table: (engine, dest, t, intensity) → end time. */
const VOICES = {
  // Clicky switch: bright tick + high click.
  [SFX.key_letter](e, d, t, i) {
    const j = jitter(0.08);
    e.burst(d, t, { freq: 3800 * j * (1 + i * 0.3), q: 1.4, gain: 0.16 + 0.14 * i, decay: 0.025 });
    return e.tone(d, t, { type: "square", f0: 2100 * j, f1: 1400 * j, glide: 0.012, gain: 0.035 + 0.03 * i, decay: 0.014 });
  },
  // Tactile: duller bump with a short body.
  [SFX.key_digit](e, d, t, i) {
    const j = jitter(0.06);
    e.burst(d, t, { freq: 2300 * j, q: 1.1, gain: 0.15 + 0.12 * i, decay: 0.032 });
    return e.tone(d, t, { type: "triangle", f0: 950 * j, f1: 620 * j, glide: 0.02, gain: 0.08 + 0.05 * i, decay: 0.03 });
  },
  // Thock: big stabilized key (space/enter/backspace).
  [SFX.key_big](e, d, t, i) {
    const j = jitter(0.05);
    e.burst(d, t, { filter: "lowpass", freq: 900 + 900 * i, q: 0.8, gain: 0.22 + 0.12 * i, decay: 0.045 });
    return e.tone(d, t, { f0: 150 * j, f1: 85 * j, glide: 0.07, gain: 0.32 + 0.18 * i, decay: 0.1 });
  },
  // Linear: smooth, soft bottom-out.
  [SFX.key_arrow](e, d, t, i) {
    const j = jitter(0.06);
    e.burst(d, t, { freq: 1500 * j, q: 0.9, gain: 0.12 + 0.1 * i, decay: 0.04 });
    return e.tone(d, t, { type: "triangle", f0: 620 * j, f1: 480 * j, glide: 0.03, gain: 0.06 + 0.05 * i, decay: 0.04 });
  },
  // Wrong key: low 180 Hz thunk with a muffled noise layer.
  [SFX.wrong](e, d, t, i) {
    e.burst(d, t, { filter: "lowpass", freq: 600, q: 0.7, gain: 0.18 + 0.1 * i, decay: 0.09 });
    return e.tone(d, t, { type: "triangle", f0: 180, f1: 140, glide: 0.15, gain: 0.4 + 0.2 * i, attack: 0.004, decay: 0.18 });
  },
  // Missed cap: sharp crack + low knock.
  [SFX.miss](e, d, t, i) {
    e.burst(d, t, { filter: "highpass", freq: 1600, q: 0.7, gain: 0.35 + 0.2 * i, attack: 0.0008, decay: 0.11 });
    e.burst(d, t + 0.012, { freq: 4200, q: 3, gain: 0.12, decay: 0.05 });
    return e.tone(d, t, { type: "square", f0: 95, f1: 60, glide: 0.08, gain: 0.12 + 0.08 * i, decay: 0.12 });
  },
  // Level up: two bells, 880 Hz then 1318.5 Hz.
  [SFX.level_up](e, d, t, i) {
    const g = 0.18 + 0.12 * i;
    e.bell(d, t, 880, g, 1.1);
    return e.bell(d, t + 0.14, 1318.5, g * 0.9, 1.4);
  },
  // Milestone: shimmering sparkle of high pentatonic pings.
  [SFX.milestone](e, d, t, i) {
    const notes = [1567.98, 1760, 2093, 2349.32, 2637.02, 3135.96];
    let end = t;
    const n = 5 + Math.round(3 * i);
    for (let k = 0; k < n; k++) {
      const f = notes[Math.floor(Math.random() * notes.length)] * (k > 3 ? 2 : 1);
      end = Math.max(end, e.tone(d, t + k * 0.045 + Math.random() * 0.015, { f0: f, gain: 0.06 + 0.05 * i, attack: 0.002, decay: 0.25 }));
    }
    return end;
  },
  // Tier 1 effect: tick/pop.
  [SFX.fx_tier1](e, d, t, i) {
    e.burst(d, t, { freq: 5000, q: 2, gain: 0.05 + 0.05 * i, decay: 0.015 });
    return e.tone(d, t, { f0: 1300 * (1 + 0.4 * i), f1: 520, glide: 0.04, gain: 0.1 + 0.08 * i, decay: 0.05 });
  },
  // Tier 2 effect: electric crackle + zap.
  [SFX.fx_tier2](e, d, t, i) {
    let end = e.tone(d, t, { type: "sawtooth", f0: 900 + 600 * i, f1: 160, glide: 0.16, gain: 0.07 + 0.06 * i, decay: 0.17 });
    const n = 8 + Math.round(12 * i);
    for (let k = 0; k < n; k++) {
      const tk = t + Math.random() * (0.18 + 0.12 * i);
      end = Math.max(end, e.burst(d, tk, { filter: "highpass", freq: 2500 + Math.random() * 4000, q: 0.7, gain: 0.05 + 0.08 * Math.random(), attack: 0.0005, decay: 0.008 }));
    }
    return end;
  },
  // Tier 3 effect: whoosh + sub boom.
  [SFX.fx_tier3](e, d, t, i) {
    e.burst(d, t, { freq: 400, sweep: [300, 3200 + 2000 * i], q: 1.2, gain: 0.16 + 0.1 * i, attack: 0.18, decay: 0.32 });
    e.burst(d, t + 0.2, { filter: "lowpass", freq: 300, sweep: [1800, 120], q: 0.7, gain: 0.3 + 0.15 * i, attack: 0.002, decay: 0.5 });
    return e.tone(d, t + 0.2, { f0: 75, f1: 32, glide: 0.7, gain: 0.55 + 0.3 * i, attack: 0.006, decay: 0.85 });
  },
  // Phrase done: C-E-G arpeggio.
  [SFX.phrase_done](e, d, t, i) {
    const notes = [523.25, 659.25, 784];
    let end = t;
    notes.forEach((f, k) => {
      const tk = t + k * 0.09;
      e.tone(d, tk, { type: "triangle", f0: f, gain: 0.14 + 0.08 * i, attack: 0.004, decay: 0.38 });
      end = Math.max(end, e.tone(d, tk, { f0: f * 2, gain: 0.04 + 0.03 * i, attack: 0.004, decay: 0.3 }));
    });
    return end;
  },
  // Game over: descending minor line.
  [SFX.game_over](e, d, t, i) {
    const notes = [392, 311.13, 261.63, 196];
    let end = t;
    notes.forEach((f, k) => {
      const tk = t + k * 0.2;
      e.tone(d, tk, { type: "triangle", f0: f, f1: f * 0.985, glide: 0.2, gain: 0.2 + 0.08 * i, attack: 0.01, decay: k === 3 ? 0.9 : 0.28 });
      end = Math.max(end, e.tone(d, tk, { type: "sine", f0: f / 2, gain: 0.12, attack: 0.01, decay: k === 3 ? 0.9 : 0.25 }));
    });
    return end;
  },
  // Start ("clock in"): click + rising octave.
  [SFX.start](e, d, t, i) {
    e.burst(d, t, { freq: 3000, q: 1.2, gain: 0.15, decay: 0.03 });
    e.tone(d, t + 0.02, { type: "triangle", f0: 523.25, gain: 0.16 + 0.08 * i, attack: 0.004, decay: 0.16 });
    return e.tone(d, t + 0.12, { type: "triangle", f0: 1046.5, gain: 0.16 + 0.08 * i, attack: 0.004, decay: 0.4 });
  },
};

/** Persisted mute preference (`localStorage`, guarded). */
const STORAGE_KEY = "snipetype.sound";

export function loadSoundPref() {
  try {
    return globalThis.localStorage?.getItem(STORAGE_KEY) !== "0";
  } catch {
    return true;
  }
}

export function saveSoundPref(on) {
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, on ? "1" : "0");
  } catch {
    // storage blocked (private window, previews): preference not kept
  }
}
