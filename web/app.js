/**
 * snipetype Web - JavaScript host.
 *
 * The Zig core (dist/snipetype_web.wasm) renders ANSI escape sequences; a
 * ghostty-web terminal emulator (libghostty's VT parser compiled to wasm,
 * vendored in vendor/ghostty-web/) parses and draws them on a canvas.
 *
 *   keyboard ─► keys.js (kitty CSI u) ─► wasm input staging
 *   rAF ─► snipetype_tick ─► ANSI bytes ─► term.write
 *                         ─► arcade pixels ─► #fx canvas (under the terminal)
 *                         ─► sfx records  ─► audio.js (WebAudio synth)
 *
 * Settings and history persist in localStorage (`snipetype.config.v1`,
 * `snipetype.history.v1`, newest 1,000 runs plus one line per personal
 * best, `snipetype.custom.v1` for the custom text): read at startup, handed
 * to the core, and written back whenever the core reports a change. URL
 * parameters beat the saved settings for the visit (saved only along with a
 * later settings change).
 *
 * Page chrome: the custom-text dialog (custom mode; also opened from the
 * settings `text` row), a fullscreen button (fullscreen also locks
 * Ctrl+W/T/N and Esc with `navigator.keyboard.lock` where supported, so
 * Ctrl+W deletes a word instead of closing the tab and a vim Esc stays in
 * fullscreen), the sound toggle, and a
 * smooth caret drawn over the canvas in the simple modes (`caret=0` turns
 * it off). Classic typing sounds (settings → options, URL `sounds=1`) play
 * through the same audio engine and respect the sound toggle.
 *
 * The terminal background is transparent: the page paints the theme
 * background, and in arcade mode the pixel layer shows through every cell
 * that uses the default background. While arcade is active the page chrome
 * (margins, footer) switches to the scene's night color (`html.arcade`).
 */

import { FitAddon, Terminal, init as initGhostty } from "./vendor/ghostty-web/ghostty-web.js";
import { classifyKey, describeKey, detectMac, formatKitty, macCompat } from "./keys.js";
import { SfxEngine, loadSoundPref, readSfxRecords, saveSoundPref } from "./audio.js";
import {
  STORE_CONFIG,
  STORE_CUSTOM,
  STORE_HINT_CTRLW,
  STORE_HISTORY,
  appendHistory,
  caretRect,
  fontSizeFor,
  lockFullscreenKeys,
  smoothCaretWanted,
  storeGet,
  storeSet,
} from "./host.js";

// ============================================================================
// Constants
// ============================================================================

const FONT_FAMILY = '"JetBrains Mono", ui-monospace, monospace';
const ARCADE_MODE_ID = 4;

/** Mode ids (src/web/main.zig `snipetype_set_mode`). */
const MODE_IDS = { words: 0, sentences: 1, code: 2, vim: 3, arcade: ARCADE_MODE_ID, zen: 5, custom: 6, daily: 7 };
const CUSTOM_MODE_ID = 6;
const MODE_NAMES = Object.fromEntries(Object.entries(MODE_IDS).map(([k, v]) => [v, k]));
/** Arcade game ids (src/web/main.zig `snipetype_set_game`). */
const GAME_IDS = { words: 0, keys: 1 };
const GAME_NAMES = Object.fromEntries(Object.entries(GAME_IDS).map(([k, v]) => [v, k]));
const LANG_IDS = {
  mixed: 0,
  zig: 1,
  rust: 2,
  go: 3,
  typescript: 4,
  ts: 4,
  python: 5,
  c: 6,
  bash: 7,
  lua: 8,
  sql: 9,
  java: 10,
  yaml: 11,
};
const THEME_IDS = {
  system: 0,
  one_dark: 1,
  one_light: 2,
  dracula: 3,
  nord: 4,
  gruvbox_dark: 5,
  solarized_dark: 6,
  serika_dark: 7,
  catppuccin_mocha: 8,
  tokyo_night: 9,
  rose_pine: 10,
  everforest: 11,
  gruvbox_light: 12,
};


/**
 * Page/terminal colors per theme id (mirrors src/ui/theme.zig).
 * `insertText` is `cursor_insert_fg`: the vim insert bar is drawn in it over
 * the app's insert cursor cell (one-dark used white on green before).
 */
const THEME_COLORS_BY_ID = {
  0: null, // system: resolved to one_light / one_dark
  1: { bg: "#282c34", fg: "#abb2bf", cursor: "#6366f1", cursorText: "#ffffff", insertText: "#282c34" }, // one_dark
  2: { bg: "#fafafa", fg: "#0f172a", cursor: "#4f46e5", cursorText: "#ffffff", insertText: "#0f172a" }, // one_light
  3: { bg: "#282a36", fg: "#f8f8f2", cursor: "#bd93f9", cursorText: "#282a36", insertText: "#282a36" }, // dracula
  4: { bg: "#2e3440", fg: "#eceff4", cursor: "#81a1c1", cursorText: "#2e3440", insertText: "#2e3440" }, // nord
  5: { bg: "#282828", fg: "#ebdbb2", cursor: "#665c54", cursorText: "#fbf1c7", insertText: "#282828" }, // gruvbox_dark
  6: { bg: "#002b36", fg: "#839496", cursor: "#268bd2", cursorText: "#002b36", insertText: "#002b36" }, // solarized_dark
  7: { bg: "#323437", fg: "#d1d0c5", cursor: "#e2b714", cursorText: "#323437", insertText: "#323437" }, // serika_dark
  8: { bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc", cursorText: "#1e1e2e", insertText: "#1e1e2e" }, // catppuccin_mocha
  9: { bg: "#1a1b26", fg: "#c0caf5", cursor: "#7aa2f7", cursorText: "#1a1b26", insertText: "#1a1b26" }, // tokyo_night
  10: { bg: "#191724", fg: "#e0def4", cursor: "#c4a7e7", cursorText: "#191724", insertText: "#191724" }, // rose_pine
  11: { bg: "#2d353b", fg: "#d3c6aa", cursor: "#a7c080", cursorText: "#2d353b", insertText: "#2d353b" }, // everforest
  12: { bg: "#fbf1c7", fg: "#3c3836", cursor: "#af3a03", cursorText: "#fbf1c7", insertText: "#ffffff", light: true }, // gruvbox_light
};
THEME_COLORS_BY_ID[2].light = true;

/** Transparent default background: cells without an explicit bg are see-through. */
const TRANSPARENT = "rgba(0, 0, 0, 0)";
const CURSOR_STYLES = { 1: "block", 2: "bar", 3: "underline" };

let lightQuery; // cached MediaQueryList (syncTheme polls it every frame)
function systemPrefersLight() {
  lightQuery ??= window.matchMedia?.("(prefers-color-scheme: light)") ?? null;
  return !!lightQuery?.matches;
}

function resolveThemeColors(themeId) {
  if (themeId === 0) return systemPrefersLight() ? THEME_COLORS_BY_ID[2] : THEME_COLORS_BY_ID[1];
  return THEME_COLORS_BY_ID[themeId] ?? THEME_COLORS_BY_ID[1];
}

function randomU32() {
  return crypto.getRandomValues(new Uint32Array(1))[0] >>> 0;
}

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((resolve) => setTimeout(resolve, ms))]).catch(() => {});
}

// ============================================================================
// Main Application
// ============================================================================

class OneApp {
  constructor() {
    this.wasm = null;
    this.memory = null;
    this.term = null;
    this.fit = null;
    this.encoder = new TextEncoder();
    this.stagingPtr = 0;
    this.stagingCap = 0;
    this.animationId = null;
    this.isMac = detectMac();
    this.modeId = 0;
    this.lastThemeKey = null;
    this.colors = THEME_COLORS_BY_ID[1];
    this.termFg = null; // default fg baked into the current Terminal
    this.cursorStyleId = -1;
    this.heldKeys = new Map(); // e.code → kitty description (for blur releases)
    this.handled = new WeakSet();
    this.listeners = [];
    this.fxShown = false;
    this.fxRect = null;
    this.arcadeChrome = false;
    this.fontSize = fontSizeFor(window.innerWidth);
    this.pasteAt = -Infinity;
    this.decoder = new TextDecoder();
    this.isVim = false;
    this.hintSeen = false;
    this.kbLocked = false;
    this.caretShown = false;
    this.caretKey = "";

    this.appEl = document.getElementById("app");
    this.screenEl = document.getElementById("screen");
    this.termEl = document.getElementById("terminal");
    this.fxCanvas = document.getElementById("fx");
    this.fxCtx = this.fxCanvas.getContext("2d", { alpha: true });
    this.fxOff = document.createElement("canvas");
    this.fxOffCtx = this.fxOff.getContext("2d", { alpha: false });
    this.caretEl = document.getElementById("caret");
    this.dialogEl = document.getElementById("custom-dialog");
    this.customTextEl = document.getElementById("custom-text");
    this.customBtn = document.getElementById("custom-button");
    this.fullscreenBtn = document.getElementById("fullscreen-toggle");

    const params = new URLSearchParams(location.search);
    this.smoothCaret = smoothCaretWanted(params, !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
    const soundParam = params.get("sound");
    const soundOn = soundParam === "0" ? false : soundParam === "1" ? true : loadSoundPref();
    this.sfx = new SfxEngine({ muted: !soundOn });
  }

  async init() {
    // JetBrains Mono comes from Google Fonts; measuring before it arrives
    // gives the wrong cell size, so wait (bounded) for it first.
    await withTimeout(document.fonts?.load(`${this.fontSize}px "JetBrains Mono"`), 1500);
    await initGhostty();
    await this.loadWasm();

    this.createTerminal(resolveThemeColors(0).fg);
    const rc = this.wasm.snipetype_init(this.term.cols, this.term.rows, randomU32());
    if (rc !== 0) throw new Error(`snipetype_init failed: ${rc}`);
    this.reportCellSize();
    this.hintSeen = storeGet(STORE_HINT_CTRLW) === "1";
    this.syncHost();
    this.wasm.snipetype_set_smooth_caret?.(this.smoothCaret ? 1 : 0);
    this.loadSaved();

    this.setupKeyboard();
    this.setupSoundToggle();
    this.setupCustomDialog();
    this.setupFullscreen();
    this.on(window.matchMedia?.("(prefers-color-scheme: light)"), "change", () => this.syncTheme(true));
    this.on(this.screenEl, "mousedown", () => setTimeout(() => this.term?.focus(), 0));
    // Clipboard paste reaches us through ghostty-web's onData; remember when
    // one happened so onTermData can tell it from IME/mobile text.
    this.on(window, "paste", () => (this.pasteAt = performance.now()), { capture: true });
    // Leaving mid-run (Ctrl+W/Ctrl+T on Windows/Linux can't be blocked).
    this.on(window, "beforeunload", (e) => {
      if (this.wasm?.snipetype_confirm_leave()) {
        e.preventDefault();
        e.returnValue = "";
      }
    });
    this.on(window, "resize", () => this.updateFontSize());
    // The terminal canvas is centered in #terminal, so it moves when the
    // container resizes by less than a cell (no term.onResize): re-place #fx.
    if (typeof ResizeObserver === "function") {
      const ro = new ResizeObserver(() => (this.fxRect = null));
      ro.observe(this.termEl);
      this.listeners.push(() => ro.disconnect());
    }

    // Late font load (or a fallback font swap): remeasure cells and refit.
    document.fonts?.ready.then(() => this.remeasure());

    this.syncTheme(true);
    this.startLoop();
    document.getElementById("loading").classList.add("hidden");
    this.term.focus();
  }

  // --------------------------------------------------------------------------
  // WASM
  // --------------------------------------------------------------------------

  async loadWasm() {
    const imports = {
      env: {
        js_now_ms: () => performance.now(),
        js_unix_ms: () => Date.now(),
        js_system_prefers_light: () => systemPrefersLight(),
        js_random_u32: () => randomU32(),
      },
    };
    const response = await fetch("./dist/snipetype_web.wasm");
    if (!response.ok) throw new Error(`wasm fetch failed: ${response.status}`);
    let result;
    try {
      result = await WebAssembly.instantiateStreaming(response.clone(), imports);
    } catch {
      result = await WebAssembly.instantiate(await response.arrayBuffer(), imports);
    }
    this.wasm = result.instance.exports;
    this.memory = this.wasm.memory;
    this.stagingPtr = this.wasm.snipetype_input_staging_ptr();
    this.stagingCap = this.wasm.snipetype_input_staging_cap();
  }

  /** Copy bytes into wasm memory; returns [ptr, len] (free with freeBytes). */
  allocBytes(str) {
    if (!str) return [0, 0];
    const bytes = this.encoder.encode(str);
    const ptr = this.wasm.snipetype_alloc(bytes.length);
    if (!ptr) return [0, 0];
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return [ptr, bytes.length];
  }

  freeBytes([ptr, len]) {
    if (ptr) this.wasm.snipetype_free(ptr, len);
  }

  readBytes(ptr, len) {
    if (!ptr || !len) return "";
    return this.decoder.decode(new Uint8Array(this.memory.buffer, ptr, len).slice());
  }

  /** Saved config + history + custom text → core (personal bests, theme, options). */
  loadSaved() {
    const custom = this.allocBytes(storeGet(STORE_CUSTOM));
    if (custom[0]) this.wasm.snipetype_load_custom_text?.(custom[0], custom[1]);
    this.freeBytes(custom);
    const cfg = this.allocBytes(storeGet(STORE_CONFIG));
    const hist = this.allocBytes(storeGet(STORE_HISTORY));
    this.wasm.snipetype_load_saved(cfg[0], cfg[1], hist[0], hist[1]);
    this.freeBytes(cfg);
    this.freeBytes(hist);
  }

  /**
   * Host facts for the core: bit 0 macOS, bit 1 "no ctrl+w hint" (seen
   * before, or Ctrl+W is captured by the fullscreen keyboard lock).
   */
  syncHost() {
    const noHint = this.hintSeen || this.kbLocked;
    this.wasm.snipetype_set_host((this.isMac ? 1 : 0) | (noHint ? 2 : 0));
  }

  /** The core's personal-best lines (history trimming keeps them). */
  pbLines() {
    const ptr = this.wasm.snipetype_pb_lines_ptr?.();
    return ptr ? this.readBytes(ptr, this.wasm.snipetype_pb_lines_len()) : "";
  }

  /**
   * URL parameters (mode, words, time, lang, tier, punct, numbers, theme,
   * vim, drill, keys, pace, stop, nobs, layout, focus, syntax, sounds):
   * not saved by themselves.
   */
  applyQuery(query) {
    if (!query || query === "?") return;
    const q = this.allocBytes(query);
    this.wasm.snipetype_apply_query(q[0], q[1]);
    this.freeBytes(q);
    this.syncTheme(true);
  }

  /** Write what the core reports: new history lines, changed config, hints. */
  persist() {
    const wasm = this.wasm;
    const recPtr = wasm.snipetype_take_record_ptr();
    if (recPtr) {
      const line = this.readBytes(recPtr, wasm.snipetype_take_record_len());
      if (line) storeSet(STORE_HISTORY, appendHistory(storeGet(STORE_HISTORY), line, undefined, () => this.pbLines()));
    }
    const cfgPtr = wasm.snipetype_take_config_ptr();
    if (cfgPtr) {
      const json = this.readBytes(cfgPtr, wasm.snipetype_take_config_len());
      if (json) storeSet(STORE_CONFIG, json);
    }
    if (wasm.snipetype_take_hint_shown()) {
      this.hintSeen = true;
      storeSet(STORE_HINT_CTRLW, "1");
    }
    const customPtr = wasm.snipetype_take_custom_ptr?.();
    if (customPtr) storeSet(STORE_CUSTOM, this.readBytes(customPtr, wasm.snipetype_take_custom_len()));
    if (wasm.snipetype_take_custom_dialog?.()) this.openCustomDialog();
  }

  sendToWasm(data) {
    if (!this.wasm) return;
    const bytes = typeof data === "string" ? this.encoder.encode(data) : data;
    for (let offset = 0; offset < bytes.length; ) {
      const n = Math.min(bytes.length - offset, this.stagingCap);
      new Uint8Array(this.memory.buffer, this.stagingPtr, n).set(bytes.subarray(offset, offset + n));
      this.wasm.snipetype_input_commit(n);
      offset += n;
    }
  }

  // --------------------------------------------------------------------------
  // Terminal
  // --------------------------------------------------------------------------

  /**
   * (Re)create the ghostty-web terminal. The default foreground is baked in
   * at creation (ghostty-web ignores theme changes after open() and OSC 10),
   * so the System theme — the only one that relies on the terminal default
   * fg — recreates the terminal when the OS color scheme flips.
   */
  createTerminal(fg) {
    if (this.term) {
      this.fit?.dispose();
      this.term.dispose();
      this.termEl.replaceChildren();
    }
    const c = this.colors;
    const term = new Terminal({
      fontFamily: FONT_FAMILY,
      fontSize: this.fontSize,
      cursorBlink: false,
      cursorStyle: "bar",
      scrollback: 0,
      allowTransparency: true,
      theme: {
        background: TRANSPARENT,
        foreground: fg,
        cursor: c.cursorText,
        cursorAccent: c.cursorText,
        selectionBackground: "rgba(99, 102, 241, 0.35)",
      },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(this.termEl);
    fit.fit();
    fit.observeResize();
    term.onResize(({ cols, rows }) => this.onTermResize(cols, rows));
    term.onData((data) => this.onTermData(data));
    // Our window-level capture listener handles keys before ghostty-web sees
    // them; this hook is a safety net that never lets ghostty-web encode a
    // key we would send ourselves (it would use legacy encodings).
    term.attachCustomKeyEventHandler((e) => this.handleKey(e, true));
    this.term = term;
    this.fit = fit;
    this.termFg = fg;
    this.cursorStyleId = -1;
    if (this.wasm) {
      this.wasm.snipetype_resize(term.cols, term.rows);
      this.reportCellSize();
    }
    this.fxRect = null;
  }

  onTermResize(cols, rows) {
    this.fxRect = null;
    if (!this.wasm) return;
    this.wasm.snipetype_resize(cols, rows);
    this.reportCellSize();
  }

  /**
   * Text from ghostty-web itself: clipboard paste, IME composition, mobile
   * input. Pasted text is never typed (it would finish a test instantly);
   * the core marks the run as pasted instead.
   */
  onTermData(data) {
    if (this.modeId === ARCADE_MODE_ID) return; // pasted text is not keystrokes
    if (performance.now() - this.pasteAt < 250) {
      // Custom idle screen: the paste becomes the custom text.
      if (this.modeId === CUSTOM_MODE_ID && this.wasm?.snipetype_get_state() === 0) {
        const bytes = this.allocBytes(data);
        this.wasm.snipetype_set_custom_text(bytes[0], bytes[1]);
        this.freeBytes(bytes);
        return;
      }
      this.wasm?.snipetype_note_paste();
      return;
    }
    this.sendToWasm(data);
  }

  /** Rescale the font so the terminal stays about 100 columns wide. */
  updateFontSize() {
    const size = fontSizeFor(window.innerWidth);
    if (size === this.fontSize || !this.term) return;
    this.fontSize = size;
    this.term.options.fontSize = size;
    this.remeasure();
  }

  reportCellSize() {
    const m = this.term?.renderer?.getMetrics?.();
    if (m && this.wasm) this.wasm.snipetype_set_cell_px(Math.round(m.width), Math.round(m.height));
  }

  remeasure() {
    const term = this.term;
    if (!term?.renderer) return;
    term.renderer.remeasureFont();
    term.renderer.resize(term.cols, term.rows);
    this.fit.fit();
    // Same grid size → no onResize: force the app to repaint everything.
    this.wasm?.snipetype_resize(term.cols, term.rows);
    this.reportCellSize();
    this.fxRect = null;
  }

  // --------------------------------------------------------------------------
  // Keyboard
  // --------------------------------------------------------------------------

  setupKeyboard() {
    const onKey = (e) => this.handleKey(e, false);
    this.on(window, "keydown", onKey, { capture: true });
    this.on(window, "keyup", onKey, { capture: true });
    // Keys held while the window loses focus never get a keyup: release them.
    this.on(window, "blur", () => this.releaseHeldKeys());
  }

  /**
   * Route one KeyboardEvent. Returns true when consumed (the contract of
   * ghostty-web's custom key handler).
   */
  handleKey(e, fromTerminal) {
    if (!this.wasm) return false;
    if (this.handled.has(e)) return true;
    if (e.target instanceof HTMLElement && e.target.closest("#controls, #custom-dialog")) return false;
    // The custom-text dialog owns the keyboard while it is open.
    if (this.dialogEl?.open) return false;

    const opts = { isMac: this.isMac, arcade: this.modeId === ARCADE_MODE_ID, vim: this.isVim };
    const kind = classifyKey(e, opts);
    if (kind === "ignore" || kind === "paste") {
      // ghostty-web handles IME text; clipboard paste arrives via onData.
      // Keep ghostty-web's legacy encoder away from paste chords.
      if (kind === "paste" && !fromTerminal) e.stopPropagation();
      return false;
    }
    if (kind === "browser") {
      // No preventDefault: reload/devtools/tab chords keep working.
      if (!fromTerminal) e.stopPropagation();
      return false;
    }

    const desc = macCompat(describeKey(e, opts), e, opts);
    if (!desc) return false;
    this.handled.add(e);
    e.preventDefault();
    e.stopPropagation();
    if (e.type === "keyup") this.heldKeys.delete(e.code);
    else this.heldKeys.set(e.code, desc);
    if (this.term && !this.hasFocus()) this.term.focus();
    this.sendToWasm(formatKitty(desc));
    return true;
  }

  releaseHeldKeys() {
    for (const desc of this.heldKeys.values()) {
      this.sendToWasm(formatKitty({ code: desc.code, mods: 1, event: 3, text: 0 }));
    }
    this.heldKeys.clear();
  }

  // --------------------------------------------------------------------------
  // Sound
  // --------------------------------------------------------------------------

  setupSoundToggle() {
    const btn = document.getElementById("sound-toggle");
    const render = () => {
      btn.setAttribute("aria-pressed", String(!this.sfx.muted));
      btn.dataset.state = this.sfx.muted ? "off" : "on";
      btn.title = this.sfx.muted ? "Sound off (click to enable)" : "Sound on (click to mute)";
    };
    render();
    this.on(btn, "click", () => {
      this.setSound(this.sfx.muted);
      render();
      this.term?.focus();
    });
    // Browsers only start audio from a user gesture.
    const unlock = () => this.sfx.unlock();
    this.on(window, "pointerdown", unlock, { capture: true, passive: true });
    this.on(window, "keydown", unlock, { capture: true, passive: true });
    this.renderSoundToggle = render;
  }

  setSound(on) {
    this.sfx.setMuted(!on);
    if (on) this.sfx.unlock();
    saveSoundPref(on);
    this.renderSoundToggle?.();
  }

  // --------------------------------------------------------------------------
  // Custom text dialog
  // --------------------------------------------------------------------------

  setupCustomDialog() {
    const dlg = this.dialogEl;
    if (!dlg) return;
    this.on(this.customBtn, "click", () => this.openCustomDialog());
    this.on(dlg, "close", () => {
      if (dlg.returnValue === "use") {
        const bytes = this.allocBytes(this.customTextEl.value);
        this.wasm.snipetype_set_custom_text(bytes[0], bytes[1]);
        this.freeBytes(bytes);
      }
      this.term?.focus();
    });
  }

  /** Open the dialog with the current custom text (from storage). */
  openCustomDialog() {
    const dlg = this.dialogEl;
    if (!dlg || dlg.open) return;
    this.releaseHeldKeys();
    this.customTextEl.value = storeGet(STORE_CUSTOM) ?? "";
    dlg.returnValue = "";
    if (typeof dlg.showModal === "function") dlg.showModal();
    else dlg.setAttribute("open", "");
    this.customTextEl.focus();
  }

  // --------------------------------------------------------------------------
  // Fullscreen + keyboard lock
  // --------------------------------------------------------------------------

  setupFullscreen() {
    const btn = this.fullscreenBtn;
    if (!btn) return;
    if (!document.fullscreenEnabled) {
      btn.hidden = true;
      return;
    }
    this.on(btn, "click", async () => {
      try {
        if (document.fullscreenElement) await document.exitFullscreen();
        else await document.documentElement.requestFullscreen({ navigationUI: "hide" });
      } catch {
        // Denied (iframe, permissions): nothing changes.
      }
      this.term?.focus();
    });
    this.on(document, "fullscreenchange", () => this.onFullscreenChange());
  }

  /**
   * Fullscreen on: ask for Ctrl+W/T/N and Esc (Chromium's keyboard lock
   * only works in fullscreen; see `FULLSCREEN_LOCK_KEYS`). The lock is feature-detected; without it the browser
   * keeps those chords and the ctrl+w hint stays.
   */
  async onFullscreenChange() {
    const on = !!document.fullscreenElement;
    this.fullscreenBtn.dataset.state = on ? "on" : "off";
    this.fullscreenBtn.title = on ? "Exit fullscreen" : "Fullscreen (ctrl+w deletes a word there)";
    const kb = navigator.keyboard;
    if (on) {
      this.kbLocked = (await lockFullscreenKeys(kb)) && !!document.fullscreenElement;
    } else {
      try {
        kb?.unlock?.();
      } catch {
        // ignore
      }
      this.kbLocked = false;
    }
    this.syncHost();
  }

  drainSfx() {
    const n = this.wasm.snipetype_get_sfx_len();
    if (!n) return;
    const records = readSfxRecords(this.memory.buffer, this.wasm.snipetype_get_sfx_ptr(), n);
    this.wasm.snipetype_clear_sfx();
    for (const r of records) this.sfx.play(r.kind, r.pan, r.intensity);
  }

  // --------------------------------------------------------------------------
  // Frame loop
  // --------------------------------------------------------------------------

  startLoop() {
    const loop = () => {
      this.animationId = requestAnimationFrame(loop);
      try {
        this.frame();
      } catch (err) {
        console.error("frame failed:", err);
        cancelAnimationFrame(this.animationId);
      }
    };
    this.animationId = requestAnimationFrame(loop);
  }

  frame() {
    const wasm = this.wasm;
    this.sfx.beginFrame();
    wasm.snipetype_tick();
    this.modeId = wasm.snipetype_get_mode();
    this.isVim = !!wasm.snipetype_is_vim?.();

    const len = wasm.snipetype_get_output_len();
    if (len > 0) {
      // Copy: term.write may hold on to the data and wasm memory can grow.
      const bytes = new Uint8Array(this.memory.buffer, wasm.snipetype_get_output_ptr(), len).slice();
      wasm.snipetype_clear_output();
      this.term.write(bytes);
    }

    this.drawFx();
    this.drainSfx();
    this.persist();
    this.syncCursor();
    this.syncCaret();
    this.syncTheme(false);
    this.syncChrome();
  }

  /** Smooth caret: follow the core's caret cell with a CSS transition. */
  syncCaret() {
    const el = this.caretEl;
    if (!el) return;
    const wasm = this.wasm;
    const show = this.smoothCaret && !!wasm.snipetype_caret_visible?.();
    if (!show) {
      if (this.caretShown) {
        el.hidden = true;
        this.caretShown = false;
        this.caretKey = "";
      }
      return;
    }
    const m = this.term?.renderer?.getMetrics?.();
    const canvas = this.term?.canvas;
    if (!m || !canvas) return;
    const x = wasm.snipetype_get_caret_x();
    const y = wasm.snipetype_get_caret_y();
    const key = `${x}:${y}:${m.width}:${m.height}:${this.fxRect ? 1 : 0}`;
    if (key === this.caretKey) return;
    const screen = this.screenEl.getBoundingClientRect();
    const r = canvas.getBoundingClientRect();
    const rect = caretRect(x, y, m.width, m.height, { left: r.left - screen.left, top: r.top - screen.top });
    el.style.width = `${rect.width}px`;
    el.style.height = `${rect.height}px`;
    // First show: jump there instead of sliding in from the last spot.
    if (!this.caretShown) el.style.transition = "none";
    el.style.transform = `translate(${rect.left}px, ${rect.top}px)`;
    if (!this.caretShown) {
      el.hidden = false;
      void el.offsetWidth;
      el.style.transition = "";
    }
    this.caretShown = true;
    this.caretKey = key;
  }

  /** Arcade: page margins/footer take the scene's night color; else the theme bg. */
  syncChrome() {
    const arcade = this.modeId === ARCADE_MODE_ID;
    if (this.customBtn) this.customBtn.hidden = this.modeId !== CUSTOM_MODE_ID;
    if (arcade === this.arcadeChrome) return;
    this.arcadeChrome = arcade;
    const root = document.documentElement;
    root.classList.toggle("arcade", arcade);
    root.style.colorScheme = arcade ? "dark" : this.colors.light ? "light" : "dark";
  }

  // --------------------------------------------------------------------------
  // Arcade pixel layer
  // --------------------------------------------------------------------------

  /** Place #fx exactly under the terminal canvas (same CSS box, device px). */
  layoutFx() {
    const canvas = this.term?.canvas;
    if (!canvas) return false;
    const screen = this.screenEl.getBoundingClientRect();
    const r = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const rect = {
      left: r.left - screen.left,
      top: r.top - screen.top,
      width: r.width,
      height: r.height,
      pw: Math.max(1, Math.round(r.width * dpr)),
      ph: Math.max(1, Math.round(r.height * dpr)),
    };
    const fx = this.fxCanvas;
    fx.style.left = `${rect.left}px`;
    fx.style.top = `${rect.top}px`;
    fx.style.width = `${rect.width}px`;
    fx.style.height = `${rect.height}px`;
    if (fx.width !== rect.pw) fx.width = rect.pw;
    if (fx.height !== rect.ph) fx.height = rect.ph;
    this.fxRect = rect;
    return true;
  }

  drawFx() {
    const wasm = this.wasm;
    if (!wasm.snipetype_fx_active()) {
      if (this.fxShown) {
        this.fxCtx.clearRect(0, 0, this.fxCanvas.width, this.fxCanvas.height);
        this.fxCanvas.hidden = true;
        this.fxShown = false;
      }
      return;
    }
    const w = wasm.snipetype_get_fx_width();
    const h = wasm.snipetype_get_fx_height();
    const ptr = wasm.snipetype_get_fx_ptr();
    if (!w || !h || !ptr || ptr + w * h * 4 > this.memory.buffer.byteLength) return;
    if (!this.fxRect && !this.layoutFx()) return;

    if (this.fxOff.width !== w || this.fxOff.height !== h) {
      this.fxOff.width = w;
      this.fxOff.height = h;
    }
    const pixels = new Uint8ClampedArray(this.memory.buffer, ptr, w * h * 4);
    this.fxOffCtx.putImageData(new ImageData(pixels, w, h), 0, 0);

    const ctx = this.fxCtx;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(this.fxOff, 0, 0, this.fxCanvas.width, this.fxCanvas.height);
    if (!this.fxShown) {
      this.fxCanvas.hidden = false;
      this.fxShown = true;
    }
  }

  // --------------------------------------------------------------------------
  // Theme & cursor
  // --------------------------------------------------------------------------

  syncTheme(force) {
    const themeId = this.wasm.snipetype_get_theme();
    const key = `${themeId}:${themeId === 0 ? systemPrefersLight() : ""}`;
    if (!force && key === this.lastThemeKey) return;
    this.lastThemeKey = key;

    const colors = resolveThemeColors(themeId);
    this.colors = colors;
    const root = document.documentElement.style;
    root.setProperty("--one-bg", colors.bg);
    root.setProperty("--one-fg", colors.fg);
    root.setProperty("--one-accent", colors.cursor);
    root.setProperty("--caret-color", colors.cursor);
    document.documentElement.style.colorScheme =
      this.arcadeChrome || !colors.light ? "dark" : "light";

    // Only the System theme draws with the terminal's default fg.
    if (themeId === 0 && this.termFg !== colors.fg) {
      const focused = this.hasFocus();
      this.createTerminal(colors.fg);
      if (focused) this.term.focus();
    }
    this.cursorStyleId = -1; // re-apply cursor colors
    this.syncCursor();
  }

  syncCursor() {
    const id = this.wasm.snipetype_get_cursor_style();
    // Vim insert bars use the insert text color: re-apply when vim changes.
    const styleKey = id + (this.isVim ? 16 : 0);
    if (styleKey === this.cursorStyleId) return;
    this.cursorStyleId = styleKey;
    const style = CURSOR_STYLES[id];
    if (!style || !this.term) return; // hidden: the app sent DECTCEM off
    // The app paints its own cursor cell (cursor bg); a block uses the same
    // colors, a bar is a caret drawn in the cursor-text color on top of it.
    const theme = this.term.renderer?.theme;
    if (theme) {
      theme.cursor =
        style === "block" ? this.colors.cursor : this.isVim ? this.colors.insertText : this.colors.cursorText;
      theme.cursorAccent = this.colors.cursorText;
    }
    this.term.options.cursorStyle = style;
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /** ghostty-web focuses its container element (it also owns a textarea). */
  hasFocus() {
    return this.termEl.contains(document.activeElement);
  }

  on(target, type, fn, opts) {
    if (!target) return;
    target.addEventListener(type, fn, opts);
    this.listeners.push(() => target.removeEventListener(type, fn, opts));
  }

  // --------------------------------------------------------------------------
  // Public API (window.oneApp)
  // --------------------------------------------------------------------------

  setMode(mode) {
    const id = typeof mode === "number" ? mode : (MODE_IDS[mode] ?? 0);
    this.wasm.snipetype_set_mode(id);
    this.modeId = this.wasm.snipetype_get_mode();
  }

  /** Arcade game: "words" (default) or "keys" (or its numeric id). */
  setGame(game) {
    if (!this.wasm.snipetype_set_game) return;
    const id = typeof game === "number" ? game : (GAME_IDS[game] ?? 0);
    this.wasm.snipetype_set_game(id);
  }

  setWordCount(count) {
    this.wasm.snipetype_set_word_count(Math.max(1, Math.min(250, count | 0)));
  }

  setTimeLimit(seconds) {
    this.wasm.snipetype_set_time_limit(Math.max(0, seconds | 0));
  }

  setLang(lang) {
    this.wasm.snipetype_set_lang(LANG_IDS[lang] ?? 0);
  }

  setTheme(theme) {
    this.wasm.snipetype_set_theme(THEME_IDS[theme] ?? 0);
    this.syncTheme(true);
  }

  reset() {
    this.wasm.snipetype_reset();
  }

  getStats() {
    const states = ["waiting", "typing", "finished"];
    return {
      mode: MODE_NAMES[this.wasm.snipetype_get_mode()] ?? "words",
      game: GAME_NAMES[this.wasm.snipetype_get_game?.() ?? 0] ?? "words",
      state: states[this.wasm.snipetype_get_state()] ?? "waiting",
      wpm: this.wasm.snipetype_get_wpm(),
      accuracy: this.wasm.snipetype_get_accuracy(),
    };
  }

  /** Play a sound effect directly (debugging / sound check). */
  playSfx(kind, pan = 0, intensity = 0.6) {
    this.sfx.unlock();
    this.sfx.play(kind, pan, intensity);
  }

  destroy() {
    if (this.animationId) cancelAnimationFrame(this.animationId);
    this.animationId = null;
    for (const off of this.listeners.splice(0)) off();
    this.fit?.dispose();
    this.term?.dispose();
    this.wasm?.snipetype_deinit();
    this.sfx.setMuted(true);
  }
}

// ============================================================================
// Entry Point
// ============================================================================

async function main() {
  try {
    const app = new OneApp();
    await app.init();

    const params = new URLSearchParams(location.search);
    // Game first: entering arcade then starts with it.
    if (params.has("game")) app.setGame(params.get("game"));
    // Everything else beats the saved settings for this visit only.
    app.applyQuery(location.search);

    window.oneApp = app;
    console.log("snipetype Web ready. Use window.oneApp for API access.");
  } catch (err) {
    console.error("Failed to init:", err);
    const loading = document.getElementById("loading");
    loading.classList.remove("hidden");
    loading.innerHTML = '<span class="loading-error">Failed to load snipetype</span>';
  }
}

main();
