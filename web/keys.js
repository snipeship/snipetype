/**
 * Keyboard → kitty keyboard protocol encoder for the snipetype web host.
 *
 * Every keydown/keyup is encoded as `CSI code;mods:event;text u` (kitty
 * flags 1|2|8|16 semantics) and fed to the wasm input parser, exactly like
 * a kitty-protocol terminal would. Pure functions only (unit tested with
 * `bun test`), no DOM access at import time.
 *
 * - code: unshifted key. Letters are lowercase, digits/symbols use the
 *   unshifted US-layout character, functional keys use kitty's Private Use
 *   Area values (must match src/platform/keys.zig `code.*`).
 * - mods: 1 + bits (shift 1, alt 2, ctrl 4, super 8, caps_lock 64).
 * - event: 1 press, 2 repeat, 3 release.
 * - text: codepoint the key types (press/repeat only, no ctrl/alt/super).
 */

/** kitty functional key codes (src/platform/keys.zig `code.*`). */
export const KEY = Object.freeze({
  escape: 27,
  enter: 13,
  tab: 9,
  backspace: 127,
  space: 32,
  insert: 57348,
  delete: 57349,
  left: 57350,
  right: 57351,
  up: 57352,
  down: 57353,
  page_up: 57354,
  page_down: 57355,
  home: 57356,
  end: 57357,
  caps_lock: 57358,
  scroll_lock: 57359,
  num_lock: 57360,
  print_screen: 57361,
  pause: 57362,
  menu: 57363,
  f1: 57364,
  left_shift: 57441,
  left_control: 57442,
  left_alt: 57443,
  left_super: 57444,
  right_shift: 57447,
  right_control: 57448,
  right_alt: 57449,
  right_super: 57450,
});

/** KeyboardEvent.code → kitty code for non-text keys. */
const FUNCTIONAL = {
  Escape: KEY.escape,
  Enter: KEY.enter,
  NumpadEnter: KEY.enter,
  Tab: KEY.tab,
  Backspace: KEY.backspace,
  Space: KEY.space,
  Insert: KEY.insert,
  Delete: KEY.delete,
  ArrowLeft: KEY.left,
  ArrowRight: KEY.right,
  ArrowUp: KEY.up,
  ArrowDown: KEY.down,
  PageUp: KEY.page_up,
  PageDown: KEY.page_down,
  Home: KEY.home,
  End: KEY.end,
  CapsLock: KEY.caps_lock,
  ScrollLock: KEY.scroll_lock,
  NumLock: KEY.num_lock,
  PrintScreen: KEY.print_screen,
  Pause: KEY.pause,
  ContextMenu: KEY.menu,
  ShiftLeft: KEY.left_shift,
  ControlLeft: KEY.left_control,
  AltLeft: KEY.left_alt,
  MetaLeft: KEY.left_super,
  OSLeft: KEY.left_super,
  ShiftRight: KEY.right_shift,
  ControlRight: KEY.right_control,
  AltRight: KEY.right_alt,
  MetaRight: KEY.right_super,
  OSRight: KEY.right_super,
};
for (let i = 1; i <= 12; i++) FUNCTIONAL[`F${i}`] = KEY.f1 + i - 1;

/** Unshifted characters of the US layout, by KeyboardEvent.code. */
const US_UNSHIFTED = {
  Minus: "-",
  Equal: "=",
  BracketLeft: "[",
  BracketRight: "]",
  Backslash: "\\",
  IntlBackslash: "\\",
  Semicolon: ";",
  Quote: "'",
  Backquote: "`",
  Comma: ",",
  Period: ".",
  Slash: "/",
  NumpadAdd: "+",
  NumpadSubtract: "-",
  NumpadMultiply: "*",
  NumpadDivide: "/",
  NumpadDecimal: ".",
  NumpadEqual: "=",
  NumpadComma: ",",
};

const MODIFIER_CODES = new Set([
  KEY.left_shift,
  KEY.left_control,
  KEY.left_alt,
  KEY.left_super,
  KEY.right_shift,
  KEY.right_control,
  KEY.right_alt,
  KEY.right_super,
  KEY.caps_lock,
  KEY.num_lock,
]);

/** True when `s` is exactly one Unicode codepoint. */
function singleCodepoint(s) {
  if (typeof s !== "string" || s.length === 0 || s.length > 2) return false;
  return [...s].length === 1;
}

function isPrintable(cp) {
  return cp >= 0x20 && cp !== 0x7f && !(cp >= 0x80 && cp < 0xa0);
}

/** Unshifted kitty key code for a KeyboardEvent, or null if unmappable. */
export function keyCode(e) {
  const code = e.code || "";
  if (code in FUNCTIONAL) return FUNCTIONAL[code];
  // Keypad with NumLock off: e.key names the navigation key (End, ArrowUp,
  // Delete, ...); send that key, not the digit printed on the keycap.
  if (code.startsWith("Numpad") && e.key in FUNCTIONAL) return FUNCTIONAL[e.key];
  // Letters: prefer the layout's letter (Dvorak/AZERTY users press the
  // key labelled Z for Ctrl+Z), fall back to the physical position (e.g.
  // macOS Option turns KeyA into "å").
  if (singleCodepoint(e.key) && /^[a-z]$/i.test(e.key)) return e.key.toLowerCase().charCodeAt(0);
  if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3) + 32;
  if (/^Digit[0-9]$/.test(code)) return code.charCodeAt(5);
  if (/^Numpad[0-9]$/.test(code)) return code.charCodeAt(6);
  // Symbols: the layout's own character when unshifted, else US table.
  const plain = !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey;
  if (plain && singleCodepoint(e.key)) {
    const cp = e.key.codePointAt(0);
    if (isPrintable(cp)) return cp;
  }
  if (code in US_UNSHIFTED) return US_UNSHIFTED[code].charCodeAt(0);
  if (singleCodepoint(e.key)) {
    const cp = e.key.toLowerCase().codePointAt(0);
    if (isPrintable(cp)) return cp;
  }
  return null;
}

function modState(e, name) {
  try {
    return typeof e.getModifierState === "function" && e.getModifierState(name);
  } catch {
    return false;
  }
}

/** True for AltGr-composed characters (Windows/Linux report ctrl+alt). */
function isAltGraph(e) {
  return modState(e, "AltGraph") && singleCodepoint(e.key) && isPrintable(e.key.codePointAt(0));
}

/**
 * Describe a KeyboardEvent as a kitty key event.
 * @param {KeyboardEvent} e
 * @param {{isMac?: boolean}} [opts]
 * @returns {{code:number, mods:number, event:number, text:number}|null}
 */
export function describeKey(e, opts = {}) {
  if (e.isComposing || e.keyCode === 229) return null;
  if (e.key === "Dead" || e.key === "Process") return null;
  const code = keyCode(e);
  if (code === null) return null;

  let shift = !!e.shiftKey;
  let alt = !!e.altKey;
  let ctrl = !!e.ctrlKey;
  const sup = !!e.metaKey;
  const caps = modState(e, "CapsLock");
  const release = e.type === "keyup";
  const isModifier = MODIFIER_CODES.has(code);

  // Characters composed with a layout modifier (AltGr, macOS Option) are
  // text, not chords: drop the composing modifiers so `@` from AltGr+Q or
  // `{` from Option+8 types normally.
  const composed = !release && !isModifier && singleCodepoint(e.key) && isPrintable(e.key.codePointAt(0));
  if (composed && isAltGraph(e)) {
    ctrl = false;
    alt = false;
  } else if (composed && opts.isMac && alt && !ctrl && !sup && e.key.codePointAt(0) >= 0x80) {
    alt = false;
  }

  const mods = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0) + (sup ? 8 : 0) + (caps ? 64 : 0);
  const event = release ? 3 : e.repeat ? 2 : 1;

  let text = 0;
  if (!release && !ctrl && !alt && !sup && !isModifier) {
    if (code === KEY.enter || code === KEY.tab || code === KEY.backspace || code === KEY.escape) text = 0;
    else if (singleCodepoint(e.key)) {
      const cp = e.key.codePointAt(0);
      if (isPrintable(cp)) text = cp;
    }
  }
  return { code, mods, event, text };
}

/** Serialize a kitty key event: `CSI code[;mods[:event][;text]] u`. */
export function formatKitty({ code, mods, event, text }) {
  let s = `\x1b[${code}`;
  if (mods !== 1 || event !== 1 || text) {
    s += `;${mods}`;
    if (event !== 1) s += `:${event}`;
  }
  if (text) s += `;${text}`;
  return s + "u";
}

/** Encode a KeyboardEvent to kitty bytes, or null if it isn't a key we send. */
export function encodeKey(e, opts = {}) {
  const k = describeKey(e, opts);
  return k ? formatKitty(k) : null;
}

/**
 * Decide who handles a key event.
 *  - "send":    encode it for the app and preventDefault.
 *  - "paste":   leave it to ghostty-web / the browser (clipboard paste).
 *  - "browser": let the browser act (reload, devtools, tabs, zoom, ...).
 *  - "ignore":  not a key we understand (IME composition, dead keys).
 * In vim mode (`vim`) on Windows/Linux, Ctrl+R (redo) and Ctrl+V reach the
 * app; Ctrl+Shift+V still pastes and F5 still reloads. On macOS
 * Cmd+Backspace is sent (`macCompat` turns it into Ctrl+U, delete line).
 * @param {KeyboardEvent} e
 * @param {{isMac?: boolean, arcade?: boolean, vim?: boolean}} [opts]
 */
export function classifyKey(e, opts = {}) {
  const { isMac = false, arcade = false, vim = false } = opts;
  if (e.isComposing || e.keyCode === 229 || e.key === "Dead" || e.key === "Process") return "ignore";
  if (keyCode(e) === null) return "ignore";
  const code = e.code || "";
  const down = e.type !== "keyup";

  // Clipboard paste (outside the arcade, where Ctrl+V is a game key).
  if (!arcade && down) {
    if (isMac && e.metaKey && !e.ctrlKey && code === "KeyV") return "paste";
    if (!isMac && e.ctrlKey && !e.altKey && code === "KeyV" && (!vim || e.shiftKey)) return "paste";
    if (e.shiftKey && !e.ctrlKey && !e.metaKey && code === "Insert") return "paste";
  }

  // Function keys the browser owns: reload, fullscreen, devtools.
  if (code === "F5" || code === "F11" || code === "F12") return "browser";

  if (isMac) {
    // Cmd chords belong to the browser (Cmd+R/L/T/W/Q, Cmd+arrows, ...),
    // except Cmd+P which keeps opening settings like Ctrl+P (print is
    // useless here). Bare Cmd presses/releases are still sent.
    if (e.metaKey && !MODIFIER_CODES.has(keyCode(e))) {
      if (!arcade && code === "KeyP" && !e.shiftKey && !e.altKey) return "send";
      if (!arcade && code === "Backspace" && !e.ctrlKey) return "send";
      return "browser";
    }
    return "send";
  }

  if (e.ctrlKey && !MODIFIER_CODES.has(keyCode(e))) {
    // Devtools, zoom, tab switching, address bar.
    if (e.shiftKey && (code === "KeyI" || code === "KeyJ" || code === "KeyC")) return "browser";
    if (code === "Equal" || code === "Minus" || code === "Digit0" || code === "NumpadAdd" || code === "NumpadSubtract")
      return "browser";
    if (code === "Tab" || code === "PageUp" || code === "PageDown") return "browser";
    if (code === "KeyL" && !e.shiftKey) return "browser";
    // Reload stays available outside the arcade and vim (Ctrl+R = redo);
    // F5 always reloads.
    if (code === "KeyR" && !arcade && !vim) return "browser";
  }
  if (e.altKey && code === "F4") return "browser";
  return "send";
}

/** Mac detection (Cmd is the browser's chord key there). */
export function detectMac(nav = globalThis.navigator) {
  const p = nav?.userAgentData?.platform || nav?.platform || "";
  return /mac|iphone|ipad|ipod/i.test(p);
}

/**
 * macOS remaps: Cmd+P → Ctrl+P (settings shortcut parity with the old host)
 * and Cmd+Backspace → Ctrl+U (delete to line start, as in macOS text
 * fields). Returns the event description to send.
 */
export function macCompat(desc, e, opts = {}) {
  if (!desc || !opts.isMac || !e.metaKey) return desc;
  // Clear super, set ctrl (bit math: Cmd+Ctrl+P must stay ctrl-only).
  const bits = ((desc.mods - 1) & ~8) | 4;
  if (e.code === "KeyP") return { ...desc, mods: bits + 1 };
  if (e.code === "Backspace" && !e.ctrlKey) return { ...desc, code: 117, mods: (bits & ~1) + 1, text: 0 };
  return desc;
}
