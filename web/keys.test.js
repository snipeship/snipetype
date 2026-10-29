// Run: cd web && bun test
import { describe, expect, test } from "bun:test";
import { KEY, classifyKey, describeKey, encodeKey, formatKitty, keyCode, macCompat } from "./keys.js";

/** Minimal KeyboardEvent stand-in. */
function ev(code, key, init = {}) {
  const { type = "keydown", shift = false, ctrl = false, alt = false, meta = false, repeat = false, caps = false, altGraph = false } = init;
  return {
    type,
    code,
    key,
    shiftKey: shift,
    ctrlKey: ctrl,
    altKey: alt,
    metaKey: meta,
    repeat,
    isComposing: false,
    keyCode: 0,
    getModifierState: (m) => (m === "CapsLock" ? caps : m === "AltGraph" ? altGraph : false),
  };
}

describe("formatKitty", () => {
  test("bare press omits defaults", () => {
    expect(formatKitty({ code: 57350, mods: 1, event: 1, text: 0 })).toBe("\x1b[57350u");
  });
  test("text forces the mods field", () => {
    expect(formatKitty({ code: 97, mods: 1, event: 1, text: 97 })).toBe("\x1b[97;1;97u");
  });
  test("event type rides on mods", () => {
    expect(formatKitty({ code: 97, mods: 1, event: 3, text: 0 })).toBe("\x1b[97;1:3u");
    expect(formatKitty({ code: 97, mods: 6, event: 2, text: 0 })).toBe("\x1b[97;6:2u");
  });
});

describe("encodeKey", () => {
  test("plain letter press with text", () => {
    expect(encodeKey(ev("KeyA", "a"))).toBe("\x1b[97;1;97u");
  });
  test("shifted letter: lowercase code, uppercase text", () => {
    expect(encodeKey(ev("KeyV", "V", { shift: true }))).toBe("\x1b[118;2;86u");
  });
  test("ctrl+shift+v has no text", () => {
    expect(encodeKey(ev("KeyV", "V", { shift: true, ctrl: true }))).toBe("\x1b[118;6u");
  });
  test("shift+4 → code '4', text '$'", () => {
    expect(encodeKey(ev("Digit4", "$", { shift: true }))).toBe("\x1b[52;2;36u");
  });
  test("shifted symbol uses US unshifted code", () => {
    expect(encodeKey(ev("Semicolon", ":", { shift: true }))).toBe("\x1b[59;2;58u");
    expect(encodeKey(ev("Digit9", "(", { shift: true }))).toBe("\x1b[57;2;40u");
  });
  test("unshifted symbol uses the layout character", () => {
    expect(encodeKey(ev("Slash", "/"))).toBe("\x1b[47;1;47u");
  });
  test("functional keys use kitty PUA codes", () => {
    expect(encodeKey(ev("ArrowUp", "ArrowUp"))).toBe(`\x1b[${KEY.up}u`);
    expect(encodeKey(ev("ArrowDown", "ArrowDown", { alt: true, shift: true }))).toBe(`\x1b[${KEY.down};4u`);
    expect(encodeKey(ev("Home", "Home"))).toBe("\x1b[57356u");
    expect(encodeKey(ev("End", "End"))).toBe("\x1b[57357u");
    expect(encodeKey(ev("Delete", "Delete", { alt: true }))).toBe("\x1b[57349;3u");
    expect(encodeKey(ev("F1", "F1"))).toBe("\x1b[57364u");
    expect(encodeKey(ev("F12", "F12"))).toBe("\x1b[57375u");
    expect(encodeKey(ev("PageDown", "PageDown"))).toBe("\x1b[57355u");
    expect(encodeKey(ev("Insert", "Insert"))).toBe("\x1b[57348u");
  });
  test("control keys keep ASCII codes and carry no text", () => {
    expect(encodeKey(ev("Enter", "Enter"))).toBe("\x1b[13u");
    expect(encodeKey(ev("Tab", "Tab"))).toBe("\x1b[9u");
    expect(encodeKey(ev("Tab", "Tab", { shift: true }))).toBe("\x1b[9;2u");
    expect(encodeKey(ev("Backspace", "Backspace"))).toBe("\x1b[127u");
    expect(encodeKey(ev("Backspace", "Backspace", { alt: true }))).toBe("\x1b[127;3u");
    expect(encodeKey(ev("Escape", "Escape"))).toBe("\x1b[27u");
    expect(encodeKey(ev("Enter", "Enter", { ctrl: true, shift: true }))).toBe("\x1b[13;6u");
  });
  test("space types a space", () => {
    expect(encodeKey(ev("Space", " "))).toBe("\x1b[32;1;32u");
  });
  test("modifier keys themselves", () => {
    expect(encodeKey(ev("ShiftLeft", "Shift", { shift: true }))).toBe("\x1b[57441;2u");
    expect(encodeKey(ev("ShiftLeft", "Shift", { type: "keyup" }))).toBe("\x1b[57441;1:3u");
    expect(encodeKey(ev("ControlRight", "Control", { ctrl: true }))).toBe("\x1b[57448;5u");
    expect(encodeKey(ev("MetaLeft", "Meta", { meta: true }))).toBe("\x1b[57444;9u");
    expect(encodeKey(ev("AltRight", "Alt", { alt: true }))).toBe("\x1b[57449;3u");
  });
  test("repeat and release", () => {
    expect(encodeKey(ev("KeyJ", "j", { repeat: true }))).toBe("\x1b[106;1:2;106u");
    expect(encodeKey(ev("KeyJ", "j", { type: "keyup" }))).toBe("\x1b[106;1:3u");
  });
  test("caps lock bit and text", () => {
    expect(encodeKey(ev("KeyA", "A", { caps: true }))).toBe("\x1b[97;65;65u");
  });
  test("macOS Option letter keeps physical code, no text", () => {
    // Option+A = "å" on US Mac: still alt+a for chords.
    expect(encodeKey(ev("KeyA", "å", { alt: true }), { isMac: false })).toBe("\x1b[97;3u");
  });
  test("macOS Option-composed symbol types the symbol", () => {
    // German Mac layout: Option+8 = "{"... (non-ASCII example: Option+2 = "™" on US)
    expect(encodeKey(ev("Digit2", "™", { alt: true }), { isMac: true })).toBe("\x1b[50;1;8482u");
  });
  test("AltGr-composed character types the character", () => {
    expect(encodeKey(ev("KeyQ", "@", { ctrl: true, alt: true, altGraph: true }))).toBe("\x1b[113;1;64u");
  });
  test("layout letters win over physical position", () => {
    // AZERTY: physical KeyQ types "a".
    expect(keyCode(ev("KeyQ", "a"))).toBe(97);
  });
  test("composition and dead keys are not encoded", () => {
    expect(encodeKey(ev("KeyE", "Dead"))).toBeNull();
    const c = ev("KeyA", "a");
    c.isComposing = true;
    expect(encodeKey(c)).toBeNull();
  });
  test("numpad digits", () => {
    expect(encodeKey(ev("Numpad7", "7"))).toBe("\x1b[55;1;55u");
    expect(encodeKey(ev("NumpadEnter", "Enter"))).toBe("\x1b[13u");
  });
  test("ctrl+c → code 99 mods 5 (app maps to Ctrl+C)", () => {
    expect(encodeKey(ev("KeyC", "c", { ctrl: true }))).toBe("\x1b[99;5u");
  });
});

describe("classifyKey", () => {
  const mac = { isMac: true };
  const pc = { isMac: false };
  test("typing keys are sent", () => {
    expect(classifyKey(ev("KeyA", "a"), pc)).toBe("send");
    expect(classifyKey(ev("Tab", "Tab"), pc)).toBe("send");
    expect(classifyKey(ev("Space", " "), mac)).toBe("send");
  });
  test("paste chords go to the browser outside the arcade", () => {
    expect(classifyKey(ev("KeyV", "v", { meta: true }), mac)).toBe("paste");
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), pc)).toBe("paste");
    expect(classifyKey(ev("KeyV", "V", { ctrl: true, shift: true }), pc)).toBe("paste");
    expect(classifyKey(ev("Insert", "Insert", { shift: true }), pc)).toBe("paste");
  });
  test("ctrl+v is a game key in the arcade", () => {
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), { isMac: false, arcade: true })).toBe("send");
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), { isMac: true, arcade: true })).toBe("send");
  });
  test("mac Cmd chords belong to the browser", () => {
    expect(classifyKey(ev("KeyR", "r", { meta: true }), mac)).toBe("browser");
    expect(classifyKey(ev("KeyL", "l", { meta: true }), mac)).toBe("browser");
    expect(classifyKey(ev("ArrowLeft", "ArrowLeft", { meta: true }), mac)).toBe("browser");
    expect(classifyKey(ev("MetaLeft", "Meta", { meta: true }), mac)).toBe("send");
    expect(classifyKey(ev("KeyR", "r", { ctrl: true }), mac)).toBe("send");
  });
  test("mac Cmd+P opens settings outside the arcade", () => {
    const e = ev("KeyP", "p", { meta: true });
    expect(classifyKey(e, mac)).toBe("send");
    expect(formatKitty(macCompat(describeKey(e, mac), e, mac))).toBe("\x1b[112;5u");
    expect(classifyKey(e, { isMac: true, arcade: true })).toBe("browser");
    // Cmd+Ctrl+P must not turn into Super+P (or Hyper+P).
    const both = ev("KeyP", "p", { meta: true, ctrl: true });
    expect(formatKitty(macCompat(describeKey(both, mac), both, mac))).toBe("\x1b[112;5u");
  });
  test("keypad with NumLock off sends the navigation key", () => {
    expect(keyCode(ev("Numpad1", "End"))).toBe(KEY.end);
    expect(keyCode(ev("Numpad8", "ArrowUp"))).toBe(KEY.up);
    expect(keyCode(ev("NumpadDecimal", "Delete"))).toBe(KEY.delete);
    expect(keyCode(ev("Numpad1", "1"))).toBe(49);
    expect(encodeKey(ev("Numpad1", "End"))).toBe("\x1b[57357u");
  });
  test("pc browser chords", () => {
    expect(classifyKey(ev("KeyR", "r", { ctrl: true }), pc)).toBe("browser");
    expect(classifyKey(ev("KeyR", "r", { ctrl: true }), { isMac: false, arcade: true })).toBe("send");
    expect(classifyKey(ev("KeyI", "I", { ctrl: true, shift: true }), pc)).toBe("browser");
    expect(classifyKey(ev("Equal", "=", { ctrl: true }), pc)).toBe("browser");
    expect(classifyKey(ev("F5", "F5"), pc)).toBe("browser");
    expect(classifyKey(ev("KeyS", "s", { ctrl: true }), pc)).toBe("send");
    expect(classifyKey(ev("KeyZ", "Z", { ctrl: true, shift: true }), pc)).toBe("send");
    expect(classifyKey(ev("ArrowLeft", "ArrowLeft", { alt: true }), pc)).toBe("send");
  });
  test("vim mode on pc: ctrl+r redoes, ctrl+v reaches the app", () => {
    const vim = { isMac: false, vim: true };
    expect(classifyKey(ev("KeyR", "r", { ctrl: true }), vim)).toBe("send");
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), vim)).toBe("send");
    expect(classifyKey(ev("KeyV", "V", { ctrl: true, shift: true }), vim)).toBe("paste");
    expect(classifyKey(ev("F5", "F5"), vim)).toBe("browser");
    // Outside vim the browser keeps them.
    expect(classifyKey(ev("KeyR", "r", { ctrl: true }), pc)).toBe("browser");
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), pc)).toBe("paste");
  });
  test("mac Cmd+Backspace deletes the line (sent as ctrl+u)", () => {
    const e = ev("Backspace", "Backspace", { meta: true });
    expect(classifyKey(e, mac)).toBe("send");
    expect(formatKitty(macCompat(describeKey(e, mac), e, mac))).toBe("\x1b[117;5u");
    expect(classifyKey(e, { isMac: true, arcade: true })).toBe("browser");
    // Option+Backspace stays Alt+Backspace (delete word).
    const opt = ev("Backspace", "Backspace", { alt: true });
    expect(classifyKey(opt, mac)).toBe("send");
    expect(formatKitty(macCompat(describeKey(opt, mac), opt, mac))).toBe("\x1b[127;3u");
  });
  test("dead keys are ignored", () => {
    expect(classifyKey(ev("Quote", "Dead"), pc)).toBe("ignore");
  });
});

describe("round 2 keys", () => {
  test("F2 (history) and Ctrl+K (code keys) reach the app", () => {
    expect(classifyKey(ev("F2", "F2"))).toBe("send");
    expect(encodeKey(ev("F2", "F2"))).toBe(`\x1b[${KEY.f1 + 1}u`);
    for (const isMac of [false, true]) {
      expect(classifyKey(ev("KeyK", "k", { ctrl: true }), { isMac })).toBe("send");
    }
    expect(encodeKey(ev("KeyK", "k", { ctrl: true }))).toBe("\x1b[107;5u");
  });

  test("Ctrl+V reaches vim editors (code with vim keys too), pastes elsewhere", () => {
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), { vim: true })).toBe("send");
    expect(classifyKey(ev("KeyV", "v", { ctrl: true }), { vim: false })).toBe("paste");
  });
});
