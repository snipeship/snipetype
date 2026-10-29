// Run: cd web && bun test
import { describe, expect, test } from "bun:test";
import {
  FONT_MAX,
  FONT_MIN,
  appendHistory,
  FULLSCREEN_LOCK_KEYS,
  caretRect,
  fontSizeFor,
  lockFullscreenKeys,
  smoothCaretWanted,
  storeGet,
  storeSet,
} from "./host.js";

describe("fontSizeFor", () => {
  test("about 100 columns, clamped to 14-22 px", () => {
    expect(fontSizeFor(300)).toBe(FONT_MIN);
    expect(fontSizeFor(1080)).toBe(18);
    expect(fontSizeFor(4000)).toBe(FONT_MAX);
    expect(fontSizeFor(0)).toBe(FONT_MIN);
  });
});

describe("history", () => {
  test("appends and keeps the newest lines", () => {
    expect(appendHistory(null, '{"a":1}')).toBe('{"a":1}\n');
    let h = "";
    for (let i = 0; i < 5; i++) h = appendHistory(h, `{"i":${i}}`, 3);
    expect(h).toBe('{"i":2}\n{"i":3}\n{"i":4}\n');
  });

  test("trimming keeps personal bests from the provider", () => {
    let calls = 0;
    const pbs = () => {
      calls++;
      return '{"v":1,"pb":true,"key":"a"}\n{"v":1,"pb":true,"key":"b"}\n';
    };
    let h = "";
    for (let i = 0; i < 3; i++) h = appendHistory(h, `{"i":${i}}`, 3, pbs);
    // Nothing dropped yet: the provider is not asked.
    expect(calls).toBe(0);
    h = appendHistory(h, '{"i":3}', 3, pbs);
    expect(calls).toBe(1);
    expect(h).toBe('{"v":1,"pb":true,"key":"a"}\n{"v":1,"pb":true,"key":"b"}\n{"i":1}\n{"i":2}\n{"i":3}\n');
    // Old PB lines are replaced, not accumulated.
    h = appendHistory(h, '{"i":4}', 3, pbs);
    expect(h.split("\n").filter((l) => l.includes('"pb":true')).length).toBe(2);
    expect(h.endsWith('{"i":2}\n{"i":3}\n{"i":4}\n')).toBe(true);
  });
});

describe("smooth caret", () => {
  test("on by default, off by URL or reduced motion", () => {
    expect(smoothCaretWanted(new URLSearchParams(""), false)).toBe(true);
    expect(smoothCaretWanted(new URLSearchParams("caret=0"), false)).toBe(false);
    expect(smoothCaretWanted(new URLSearchParams(""), true)).toBe(false);
    expect(smoothCaretWanted(new URLSearchParams("caret=1"), true)).toBe(true);
  });

  test("caret rect follows the cell grid", () => {
    expect(caretRect(3, 2, 10, 20, { left: 5, top: 7 })).toEqual({ left: 35, top: 47, width: 2, height: 20 });
  });
});

describe("storage", () => {
  test("throwing storage is survived", () => {
    const bad = {
      getItem() {
        throw new Error("blocked");
      },
      setItem() {
        throw new Error("quota");
      },
    };
    expect(storeGet("k", bad)).toBe(null);
    expect(storeSet("k", "v", bad)).toBe(false);
    const map = new Map();
    const ok = { getItem: (k) => map.get(k) ?? null, setItem: (k, v) => map.set(k, v) };
    expect(storeSet("k", "v", ok)).toBe(true);
    expect(storeGet("k", ok)).toBe("v");
    expect(storeGet("missing", ok)).toBe(null);
  });
});

describe("lockFullscreenKeys", () => {
  test("locks Ctrl+W/T/N and Escape (a vim Esc must not leave fullscreen)", async () => {
    let asked = null;
    const kb = { lock: async (codes) => void (asked = codes) };
    expect(await lockFullscreenKeys(kb)).toBe(true);
    expect(asked).toEqual(FULLSCREEN_LOCK_KEYS);
    for (const c of ["KeyW", "KeyT", "KeyN", "Escape"]) expect(asked).toContain(c);
  });

  test("falls back without the API or when refused", async () => {
    expect(await lockFullscreenKeys(undefined)).toBe(false);
    expect(await lockFullscreenKeys({})).toBe(false);
    expect(await lockFullscreenKeys({ lock: async () => Promise.reject(new Error("denied")) })).toBe(false);
  });
});
