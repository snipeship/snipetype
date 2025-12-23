/**
 * ONE Web - JavaScript Host Application
 *
 * This file:
 * - Initializes ghostty-web terminal
 * - Loads and instantiates the WASM module
 * - Bridges input/output between terminal and WASM
 * - Drives the animation loop
 */

import { init as ghosttyInit, Terminal, FitAddon } from "ghostty-web";

// ============================================================================
// Constants
// ============================================================================

const FONT_SIZE = 16;
const FONT_FAMILY =
  '"JetBrains Mono", "Fira Code", "SF Mono", Menlo, Monaco, "Courier New", monospace';

const TERMINAL_THEME_BASE = {
  cursor: "#6366f1",
  cursorAccent: "#ffffff",
  selectionBackground: "rgba(99, 102, 241, 0.3)",
};

const THEME_COLORS_BY_ID = {
  1: { bg: "#282c34", fg: "#abb2bf" }, // one_dark
  2: { bg: "#fafafa", fg: "#0f172a" }, // one_light
  3: { bg: "#282a36", fg: "#f8f8f2" }, // dracula
  4: { bg: "#2e3440", fg: "#eceff4" }, // nord
  5: { bg: "#282828", fg: "#ebdbb2" }, // gruvbox_dark
  6: { bg: "#002b36", fg: "#839496" }, // solarized_dark
};

function systemPrefersLight() {
  return (
    window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: light)").matches
  );
}

function resolveThemeColors(themeId) {
  if (themeId === 0) {
    return systemPrefersLight() ? THEME_COLORS_BY_ID[2] : THEME_COLORS_BY_ID[1];
  }
  return THEME_COLORS_BY_ID[themeId] ?? THEME_COLORS_BY_ID[1];
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Generate a random 32-bit unsigned integer
 */
function randomU32() {
  const arr = new Uint32Array(1);
  crypto.getRandomValues(arr);
  return arr[0] >>> 0;
}

// ============================================================================
// Main Application
// ============================================================================

class OneApp {
  constructor() {
    this.term = null;
    this.fitAddon = null;
    this.wasm = null;
    this.wasmMemory = null;
    this.decoder = new TextDecoder("utf-8");
    this.encoder = new TextEncoder();
    this.stagingPtr = 0;
    this.stagingCap = 0;
    this.animationFrameId = null;
    this.lastThemeId = null;
  }

  /**
   * Initialize the application
   */
  async init() {
    // Initialize ghostty-web
    await ghosttyInit();

    const { bg: initialBg, fg: initialFg } = resolveThemeColors(0);

    // Create terminal
    this.term = new Terminal({
      fontSize: FONT_SIZE,
      fontFamily: FONT_FAMILY,
      cursorBlink: false,
      cursorStyle: "block",
      allowProposedApi: true,
      theme: {
        ...TERMINAL_THEME_BASE,
        background: initialBg,
        foreground: initialFg,
      },
    });

    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);

    const termEl = document.getElementById("terminal");
    this.term.open(termEl);
    this.fitAddon.fit();
    this.fitAddon.observeResize();

    // Prevent browser shortcuts that conflict with the app
    this.setupKeyboardOverrides();

    // Load WASM module
    await this.loadWasm();

    // Connect terminal to WASM
    this.connectTerminal();

    // Resize WASM to match terminal on container resize
    this.term.onResize(({ cols, rows }) => {
      this.wasm.one_web_resize(cols, rows);
      this.wasm.one_web_tick();
    });

    // Initial fit and WASM init
    const rc = this.wasm.one_web_init(
      this.term.cols,
      this.term.rows,
      randomU32(),
    );
    if (rc !== 0) {
      throw new Error(`one_web_init failed with code ${rc}`);
    }

    // Initial render
    this.wasm.one_web_tick();
    this.syncWebTheme(true);

    // Start animation loop
    this.startLoop();

    // Hide loading screen
    document.getElementById("loading").classList.add("hidden");

    // Focus terminal
    this.term.focus();
  }

  /**
   * Prevent browser default behavior for keys we need
   * and send modified arrow escape sequences
   */
  setupKeyboardOverrides() {
    window.addEventListener(
      "keydown",
      (e) => {
        // Ctrl+P (print dialog)
        if ((e.ctrlKey || e.metaKey) && (e.key === "p" || e.key === "P")) {
          e.preventDefault();
        }
        // Tab (focus navigation)
        if (e.key === "Tab") {
          e.preventDefault();
        }
        // Arrow keys - prevent scroll and handle modifiers
        if (
          ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.key)
        ) {
          e.preventDefault();

          // For modified arrows, send escape sequences directly
          // since some terminal emulators may not handle them
          if (e.shiftKey || e.ctrlKey || e.metaKey) {
            const dirMap = {
              ArrowUp: "A",
              ArrowDown: "B",
              ArrowRight: "C",
              ArrowLeft: "D",
            };
            const dir = dirMap[e.key];
            // Modifier: 2 = Shift, 5 = Ctrl (or Cmd on Mac)
            const mod = e.shiftKey ? "2" : "5";
            const seq = `\x1b[1;${mod}${dir}`;
            this.sendToWasm(seq);
            this.wasm.one_web_tick();
            this.syncWebTheme();
          }
        }
      },
      { capture: true },
    );
  }

  /**
   * Load and instantiate the WASM module
   */
  async loadWasm() {
    const imports = {
      env: {
        // Output: WASM writes ANSI bytes to terminal
        js_write: (ptr, len) => {
          const bytes = new Uint8Array(
            this.wasmMemory.buffer,
            ptr >>> 0,
            len >>> 0,
          );
          this.term.write(this.decoder.decode(bytes));
        },

        // Time: return current time in milliseconds
        js_now_ms: () => performance.now(),

        // Theme: check if system prefers light mode
        js_system_prefers_light: () => {
          return (
            window.matchMedia &&
            window.matchMedia("(prefers-color-scheme: light)").matches
          );
        },

        // Random: return a random 32-bit integer
        js_random_u32: () => randomU32(),
      },
    };

    const response = await fetch("./dist/one_web.wasm");
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, imports);

    this.wasm = result.instance.exports;
    this.wasmMemory = this.wasm.memory;

    // Get staging buffer info
    this.stagingPtr = this.wasm.one_web_input_staging_ptr();
    this.stagingCap = this.wasm.one_web_input_staging_cap();
  }

  /**
   * Connect terminal input to WASM
   */
  connectTerminal() {
    this.term.onData((data) => {
      this.sendToWasm(data);
      // Immediate tick for responsiveness
      this.wasm.one_web_tick();
      this.syncWebTheme();
    });
  }

  /**
   * Send input data to WASM via staging buffer
   */
  sendToWasm(dataStr) {
    const bytes = this.encoder.encode(dataStr);
    let offset = 0;

    while (offset < bytes.length) {
      const chunkSize = Math.min(bytes.length - offset, this.stagingCap);
      const chunk = bytes.subarray(offset, offset + chunkSize);

      // Copy to staging buffer
      const staging = new Uint8Array(
        this.wasmMemory.buffer,
        this.stagingPtr,
        chunkSize,
      );
      staging.set(chunk);

      // Commit to WASM
      this.wasm.one_web_input_commit(chunkSize);

      offset += chunkSize;
    }
  }

  /**
   * Fit terminal to container
   */
  fit() {
    this.fitAddon.fit();
    return { cols: this.term.cols, rows: this.term.rows };
  }

  /**
   * Start the animation loop
   */
  startLoop() {
    const loop = () => {
      this.wasm.one_web_tick();
      this.syncWebTheme();
      this.animationFrameId = requestAnimationFrame(loop);
    };
    this.animationFrameId = requestAnimationFrame(loop);
  }

  syncWebTheme(force = false) {
    if (!this.wasm?.one_web_get_theme) return;
    const themeId = this.wasm.one_web_get_theme();
    if (!force && themeId === this.lastThemeId) return;
    this.lastThemeId = themeId;

    const { bg, fg } = resolveThemeColors(themeId);
    document.documentElement.style.setProperty("--one-bg", bg);
    document.documentElement.style.setProperty("--one-fg", fg);

    if (this.term?.renderer?.setTheme && this.term?.renderer?.resize) {
      this.term.renderer.setTheme({
        ...TERMINAL_THEME_BASE,
        background: bg,
        foreground: fg,
      });
      this.term.renderer.resize(this.term.cols, this.term.rows);
    }
  }

  /**
   * Stop the animation loop
   */
  stopLoop() {
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = null;
    }
  }

  /**
   * Public API: Set typing mode
   * @param {string} mode - 'words' | 'sentences' | 'code' | 'vim'
   */
  setMode(mode) {
    const modeMap = { words: 0, sentences: 1, code: 2, vim: 3 };
    this.wasm.one_web_set_mode(modeMap[mode] ?? 0);
  }

  /**
   * Public API: Set word count
   * @param {number} count - Number of words (1-100)
   */
  setWordCount(count) {
    this.wasm.one_web_set_word_count(count);
  }

  /**
   * Public API: Set time limit
   * @param {number} seconds - Time limit in seconds (0 = no limit)
   */
  setTimeLimit(seconds) {
    this.wasm.one_web_set_time_limit(seconds);
  }

  /**
   * Public API: Set programming language
   * @param {string} lang - 'mixed' | 'zig' | 'rust' | 'go' | 'typescript' | 'python' | 'c'
   */
  setLang(lang) {
    const langMap = {
      mixed: 0,
      zig: 1,
      rust: 2,
      go: 3,
      typescript: 4,
      python: 5,
      c: 6,
    };
    this.wasm.one_web_set_lang(langMap[lang] ?? 0);
  }

  /**
   * Public API: Set theme
   * @param {string} theme - 'system' | 'one_dark' | 'one_light' | 'dracula' | 'nord' | 'gruvbox_dark' | 'solarized_dark'
   */
  setTheme(theme) {
    const themeMap = {
      system: 0,
      one_dark: 1,
      one_light: 2,
      dracula: 3,
      nord: 4,
      gruvbox_dark: 5,
      solarized_dark: 6,
    };
    this.wasm.one_web_set_theme(themeMap[theme] ?? 0);
    this.syncWebTheme(true);
  }

  /**
   * Public API: Reset the current test
   */
  reset() {
    this.wasm.one_web_reset();
  }

  /**
   * Public API: Get current state
   * @returns {{ state: string, wpm: number, accuracy: number }}
   */
  getStats() {
    const stateMap = ["waiting", "typing", "finished"];
    return {
      state: stateMap[this.wasm.one_web_get_state()] ?? "waiting",
      wpm: this.wasm.one_web_get_wpm(),
      accuracy: this.wasm.one_web_get_accuracy(),
    };
  }

  /**
   * Clean up resources
   */
  destroy() {
    this.stopLoop();
    this.wasm.one_web_deinit();
    this.term.dispose();
  }
}

// ============================================================================
// Application Entry Point
// ============================================================================

async function main() {
  try {
    const app = new OneApp();
    await app.init();

    // Parse URL parameters for initial config
    const params = new URLSearchParams(window.location.search);

    if (params.has("mode")) {
      app.setMode(params.get("mode"));
    }
    if (params.has("words")) {
      app.setWordCount(parseInt(params.get("words"), 10));
    }
    if (params.has("time")) {
      app.setTimeLimit(parseInt(params.get("time"), 10));
    }
    if (params.has("lang")) {
      app.setLang(params.get("lang"));
    }
    if (params.has("theme")) {
      app.setTheme(params.get("theme"));
    }

    // Expose app for debugging and external control
    window.oneApp = app;

    console.log("ONE Web initialized. Access via window.oneApp");
    console.log('Example: oneApp.setMode("vim"), oneApp.setTheme("dracula")');
  } catch (error) {
    console.error("Failed to initialize ONE:", error);
    document.getElementById("loading").innerHTML = `
      <span style="color: #ef4444; font-family: monospace;">
        Failed to load. Check console for details.
      </span>
    `;
  }
}

main();
