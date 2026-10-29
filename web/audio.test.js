// Run: cd web && bun test
import { expect, test } from "bun:test";
import { SFX, SFX_RECORD_BYTES, SfxEngine, readSfxRecords } from "./audio.js";

function records(list, ptr = 16) {
  const buf = new ArrayBuffer(ptr + list.length * SFX_RECORD_BYTES + 8);
  const dv = new DataView(buf);
  list.forEach(([kind, pan, intensity], i) => {
    const o = ptr + i * SFX_RECORD_BYTES;
    dv.setUint32(o, kind, true);
    dv.setFloat32(o + 4, pan, true);
    dv.setFloat32(o + 8, intensity, true);
  });
  return buf;
}

test("decodes 12-byte little-endian records", () => {
  const buf = records([
    [SFX.key_letter, -0.5, 0.25],
    [SFX.fx_tier3, 1, 1],
  ]);
  const out = readSfxRecords(buf, 16, 2);
  expect(out).toEqual([
    { kind: 0, pan: -0.5, intensity: 0.25 },
    { kind: 10, pan: 1, intensity: 1 },
  ]);
});

test("clamps pan/intensity and drops unknown kinds", () => {
  const buf = records([
    [99, 0, 0],
    [SFX.start, 3, -2],
    [SFX.wrong, NaN, NaN],
  ]);
  expect(readSfxRecords(buf, 16, 3)).toEqual([
    { kind: SFX.start, pan: 1, intensity: 0 },
    { kind: SFX.wrong, pan: 0, intensity: 0.5 },
  ]);
});

test("rejects null, misaligned or out-of-bounds pointers", () => {
  const buf = records([[0, 0, 0]]);
  expect(readSfxRecords(buf, 0, 1)).toEqual([]);
  expect(readSfxRecords(buf, 18, 1)).toEqual([]);
  expect(readSfxRecords(buf, 16, 100)).toEqual([]);
});

test("kind ids match the wasm SfxKind enum", () => {
  expect(Object.values(SFX)).toEqual([...Array(14).keys()]);
});

test("engine without an AudioContext is a silent no-op", () => {
  const e = new SfxEngine({ muted: false });
  expect(e.ready).toBe(false);
  e.play(SFX.level_up, 0, 1);
  e.setMuted(true);
  expect(e.muted).toBe(true);
});
