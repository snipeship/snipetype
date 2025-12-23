/**
 * ONE Web - JavaScript Host Application (Canvas2D Version)
 *
 * Uses Canvas 2D API for crisp font rendering with JetBrains Mono.
 * Reads cell grid directly from WASM memory.
 */

// ============================================================================
// Constants
// ============================================================================

const FONT_SIZE = 16;
const FONT_FAMILY = '"JetBrains Mono", "Fira Code", "SF Mono", Menlo, monospace';
const LINE_HEIGHT = 1.2;

// Cell structure: 8 bytes (char, flags, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b)
const CELL_SIZE = 8;

// Theme colors for page background
const THEME_COLORS_BY_ID = {
  0: null, // system
  1: { bg: "#282c34", fg: "#abb2bf" }, // one_dark
  2: { bg: "#fafafa", fg: "#0f172a" }, // one_light
  3: { bg: "#282a36", fg: "#f8f8f2" }, // dracula
  4: { bg: "#2e3440", fg: "#eceff4" }, // nord
  5: { bg: "#282828", fg: "#ebdbb2" }, // gruvbox_dark
  6: { bg: "#002b36", fg: "#839496" }, // solarized_dark
};

function systemPrefersLight() {
  return window.matchMedia?.("(prefers-color-scheme: light)").matches;
}

function resolveThemeColors(themeId) {
  if (themeId === 0) {
    return systemPrefersLight() ? THEME_COLORS_BY_ID[2] : THEME_COLORS_BY_ID[1];
  }
  return THEME_COLORS_BY_ID[themeId] ?? THEME_COLORS_BY_ID[1];
}

function randomU32() {
  return crypto.getRandomValues(new Uint32Array(1))[0] >>> 0;
}

// ============================================================================
// Canvas Terminal Renderer
// ============================================================================

class CanvasTerminal {
  constructor(container, cols, rows) {
    this.cols = cols;
    this.rows = rows;
    this.charWidth = 0;
    this.charHeight = 0;

    // Create canvas
    this.canvas = document.createElement("canvas");
    this.canvas.tabIndex = 0;
    this.canvas.style.outline = "none";
    container.appendChild(this.canvas);

    this.ctx = this.canvas.getContext("2d");

    // Measure character dimensions
    this.measureFont();

    // Size canvas
    this.resize(cols, rows);
  }

  measureFont() {
    this.ctx.font = `${FONT_SIZE}px ${FONT_FAMILY}`;
    const metrics = this.ctx.measureText("M");
    this.charWidth = Math.ceil(metrics.width);
    this.charHeight = Math.ceil(FONT_SIZE * LINE_HEIGHT);
  }

  resize(cols, rows) {
    this.cols = cols;
    this.rows = rows;

    const dpr = window.devicePixelRatio || 1;
    const width = cols * this.charWidth;
    const height = rows * this.charHeight;

    this.canvas.width = width * dpr;
    this.canvas.height = height * dpr;
    this.canvas.style.width = `${width}px`;
    this.canvas.style.height = `${height}px`;

    this.ctx.scale(dpr, dpr);
    this.ctx.font = `${FONT_SIZE}px ${FONT_FAMILY}`;
    this.ctx.textBaseline = "top";
  }

  clear(bgColor = "#282c34") {
    this.ctx.fillStyle = bgColor;
    this.ctx.fillRect(
      0,
      0,
      this.cols * this.charWidth,
      this.rows * this.charHeight,
    );
  }

  drawCell(x, y, char, fgR, fgG, fgB, bgR, bgG, bgB, bold = false) {
    const px = x * this.charWidth;
    const py = y * this.charHeight;

    // Draw background
    this.ctx.fillStyle = `rgb(${bgR},${bgG},${bgB})`;
    this.ctx.fillRect(px, py, this.charWidth, this.charHeight);

    // Draw character
    if (char > 32 && char < 127) {
      this.ctx.fillStyle = `rgb(${fgR},${fgG},${fgB})`;
      this.ctx.font = `${bold ? "bold " : ""}${FONT_SIZE}px ${FONT_FAMILY}`;
      // Center vertically with a small offset for better alignment
      const textY = py + (this.charHeight - FONT_SIZE) / 2 + 1;
      this.ctx.fillText(String.fromCharCode(char), px, textY);
    }
  }

  focus() {
    this.canvas.focus();
  }
}

// ============================================================================
// Main Application
// ============================================================================

class OneApp {
  constructor() {
    this.term = null;
    this.wasm = null;
    this.wasmMemory = null;
    this.encoder = new TextEncoder();
    this.stagingPtr = 0;
    this.stagingCap = 0;
    this.lastThemeId = null;
    this.cols = 80;
    this.rows = 24;
    this.animationId = null;
  }

  async init() {
    const container = document.getElementById("terminal");

    // Calculate optimal grid size
    this.calculateSize(container);

    // Create canvas terminal
    this.term = new CanvasTerminal(container, this.cols, this.rows);

    // Load WASM
    await this.loadWasm();

    // Initialize WASM app
    const rc = this.wasm.one_web_init(this.cols, this.rows, randomU32());
    if (rc !== 0) throw new Error(`one_web_init failed: ${rc}`);

    // Setup input
    this.setupInput();

    // Setup resize
    this.setupResize(container);

    // Start render loop
    this.startLoop();

    // Sync theme
    this.syncWebTheme(true);

    // Hide loading
    document.getElementById("loading").classList.add("hidden");

    // Focus
    this.term.focus();
  }

  calculateSize(container) {
    // Create temp canvas to measure font
    const tempCanvas = document.createElement("canvas");
    const ctx = tempCanvas.getContext("2d");
    ctx.font = `${FONT_SIZE}px ${FONT_FAMILY}`;
    const charWidth = Math.ceil(ctx.measureText("M").width);
    const charHeight = Math.ceil(FONT_SIZE * LINE_HEIGHT);

    // Calculate grid size based on container
    const maxWidth = container.clientWidth - 32; // padding
    const maxHeight = container.clientHeight - 32;

    this.cols = Math.max(40, Math.floor(maxWidth / charWidth));
    this.rows = Math.max(10, Math.floor(maxHeight / charHeight));
  }

  setupInput() {
    this.term.canvas.addEventListener("keydown", (e) => {
      const bytes = this.keyToBytes(e);
      if (bytes) {
        e.preventDefault();
        this.sendToWasm(bytes);
      }
    });

    // Prevent tab from losing focus
    this.term.canvas.addEventListener("keydown", (e) => {
      if (e.key === "Tab") e.preventDefault();
    });
  }

  keyToBytes(e) {
    const { key, ctrlKey, metaKey, shiftKey } = e;

    // Ctrl combinations
    if (ctrlKey || metaKey) {
      if (key === "c" || key === "C") return "\x03";
      if (key === "p" || key === "P") return "\x10";
    }

    // Special keys
    switch (key) {
      case "Escape":
        return "\x1b";
      case "Enter":
        return "\r";
      case "Backspace":
        return "\x7f";
      case "Tab":
        return "\t";
      case "ArrowUp":
        return ctrlKey || metaKey
          ? "\x1b[1;5A"
          : shiftKey
            ? "\x1b[1;2A"
            : "\x1b[A";
      case "ArrowDown":
        return ctrlKey || metaKey
          ? "\x1b[1;5B"
          : shiftKey
            ? "\x1b[1;2B"
            : "\x1b[B";
      case "ArrowRight":
        return ctrlKey || metaKey
          ? "\x1b[1;5C"
          : shiftKey
            ? "\x1b[1;2C"
            : "\x1b[C";
      case "ArrowLeft":
        return ctrlKey || metaKey
          ? "\x1b[1;5D"
          : shiftKey
            ? "\x1b[1;2D"
            : "\x1b[D";
      case "Home":
        return "\x1b[H";
      case "End":
        return "\x1b[F";
      case "Delete":
        return "\x1b[3~";
    }

    // Printable characters
    if (key.length === 1) return key;
    return null;
  }

  setupResize(container) {
    const resizeObserver = new ResizeObserver(() => {
      this.calculateSize(container);
      this.term.resize(this.cols, this.rows);
      this.wasm.one_web_resize(this.cols, this.rows);
    });
    resizeObserver.observe(container);
  }

  async loadWasm() {
    const imports = {
      env: {
        js_now_ms: () => performance.now(),
        js_system_prefers_light: () => systemPrefersLight(),
        js_random_u32: () => randomU32(),
      },
    };

    const response = await fetch("./dist/one_web.wasm");
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, imports);

    this.wasm = result.instance.exports;
    this.wasmMemory = this.wasm.memory;
    this.stagingPtr = this.wasm.one_web_input_staging_ptr();
    this.stagingCap = this.wasm.one_web_input_staging_cap();
  }

  sendToWasm(dataStr) {
    const bytes = this.encoder.encode(dataStr);
    let offset = 0;

    while (offset < bytes.length) {
      const chunkSize = Math.min(bytes.length - offset, this.stagingCap);
      const staging = new Uint8Array(
        this.wasmMemory.buffer,
        this.stagingPtr,
        chunkSize,
      );
      staging.set(bytes.subarray(offset, offset + chunkSize));
      this.wasm.one_web_input_commit(chunkSize);
      offset += chunkSize;
    }
  }

  startLoop() {
    const loop = () => {
      this.wasm.one_web_tick();

      if (this.wasm.one_web_is_dirty()) {
        this.render();
        this.wasm.one_web_clear_dirty();
      }

      this.syncWebTheme();
      this.animationId = requestAnimationFrame(loop);
    };
    this.animationId = requestAnimationFrame(loop);
  }

  render() {
    const ptr = this.wasm.one_web_get_cells_ptr();
    const w = this.wasm.one_web_get_grid_width();
    const h = this.wasm.one_web_get_grid_height();

    if (!ptr || !w || !h) return;

    const cells = new Uint8Array(this.wasmMemory.buffer, ptr, w * h * CELL_SIZE);

    // Get background color from first cell for clear
    const bgR = cells[5],
      bgG = cells[6],
      bgB = cells[7];
    this.term.clear(`rgb(${bgR},${bgG},${bgB})`);

    // Draw all cells
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * CELL_SIZE;
        const char = cells[i];
        const flags = cells[i + 1];
        const fgR = cells[i + 2],
          fgG = cells[i + 3],
          fgB = cells[i + 4];
        const bgR = cells[i + 5],
          bgG = cells[i + 6],
          bgB = cells[i + 7];
        const bold = (flags & 1) !== 0;

        this.term.drawCell(x, y, char, fgR, fgG, fgB, bgR, bgG, bgB, bold);
      }
    }
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
