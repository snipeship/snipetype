/**
 * Host helpers without DOM dependencies (unit-tested with `bun test`):
 * localStorage access, the history cap (personal bests survive it), the
 * viewport font size, and small URL / caret helpers.
 */

/** localStorage keys (every access is wrapped in try/catch). */
export const STORE_CONFIG = "snipetype.config.v1";
export const STORE_HISTORY = "snipetype.history.v1";
/** "1" once the "ctrl+w belongs to the browser" hint was shown. */
export const STORE_HINT_CTRLW = "snipetype.hint.ctrlw";
/** The custom-mode text (the dialog's last "use"). */
export const STORE_CUSTOM = "snipetype.custom.v1";
export const HISTORY_MAX_LINES = 1000;

/** Font size range; the size scales so the terminal is about 100 columns. */
export const FONT_MIN = 14;
export const FONT_MAX = 22;
export const TARGET_COLS = 100;
/** JetBrains Mono advance width per px of font size. */
const FONT_ADVANCE = 0.6;

/** Font size (px) giving about TARGET_COLS columns in `width` CSS px. */
export function fontSizeFor(width) {
  const size = Math.floor(width / (TARGET_COLS * FONT_ADVANCE));
  return Math.max(FONT_MIN, Math.min(FONT_MAX, size || FONT_MIN));
}

/** localStorage read; null when missing, blocked or throwing. */
export function storeGet(key, storage = globalThis.localStorage) {
  try {
    return storage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

/** localStorage write; false when blocked or full. */
export function storeSet(key, value, storage = globalThis.localStorage) {
  try {
    storage?.setItem(key, value);
    return !!storage;
  } catch {
    return false;
  }
}

const isPbLine = (l) => l.includes('"pb":true');

/**
 * Append one JSONL record, keeping the newest `max` runs. When lines would
 * be dropped and `pbLines` is given (a function returning the core's
 * `"pb":true` lines, one per personal best), those lines go first so the
 * bests survive the cap; older PB lines are replaced by them.
 * @param {string|null} existing
 * @param {string} line
 * @param {number} [max]
 * @param {(() => string) | null} [pbLines]
 */
export function appendHistory(existing, line, max = HISTORY_MAX_LINES, pbLines = null) {
  const lines = (existing || "").split("\n").filter((l) => l.length > 0);
  lines.push(line);
  if (lines.length <= max) return lines.join("\n") + "\n";
  if (!pbLines) return lines.slice(-max).join("\n") + "\n";
  const runs = lines.filter((l) => !isPbLine(l)).slice(-max);
  const pbs = (pbLines() || "").split("\n").filter((l) => l.length > 0);
  return [...pbs, ...runs].join("\n") + "\n";
}

/**
 * The smooth caret is on unless the URL says `caret=0` or the user asked
 * for reduced motion.
 * @param {URLSearchParams} params
 * @param {boolean} reducedMotion
 */
export function smoothCaretWanted(params, reducedMotion) {
  const v = params.get("caret");
  if (v === "0" || v === "off" || v === "false") return false;
  if (v === "1" || v === "on" || v === "true") return true;
  return !reducedMotion;
}

/**
 * Where the smooth caret goes: cell (x, y) of a canvas at `rect` (CSS px,
 * relative to the play area) with `cellW` x `cellH` cells.
 */
export function caretRect(x, y, cellW, cellH, rect) {
  return { left: rect.left + x * cellW, top: rect.top + y * cellH, width: Math.max(2, Math.round(cellW * 0.12)), height: cellH };
}

/**
 * Keys the fullscreen keyboard lock asks for: Ctrl+W/T/N reach the app
 * instead of closing/opening tabs and windows, and Escape so the constant
 * Esc of vim (and the arcade pause) does not drop out of fullscreen, which
 * would also drop the lock. With Escape locked, holding Esc leaves
 * fullscreen (Chromium shows that hint); the footer button still works.
 */
export const FULLSCREEN_LOCK_KEYS = ["KeyW", "KeyT", "KeyN", "Escape"];

/**
 * Ask `navigator.keyboard` (Chromium, fullscreen only) for
 * `FULLSCREEN_LOCK_KEYS`. Resolves to true when locked; false without the
 * API or when the browser refuses.
 * @param {{ lock?: (codes: string[]) => Promise<void> } | undefined} kb
 */
export async function lockFullscreenKeys(kb) {
  if (typeof kb?.lock !== "function") return false;
  try {
    await kb.lock(FULLSCREEN_LOCK_KEYS);
    return true;
  } catch {
    return false;
  }
}
