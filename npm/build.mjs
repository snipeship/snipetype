#!/usr/bin/env node
import { execSync } from "child_process";
import { cpSync, mkdirSync, chmodSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

const TARGETS = [
  { zig: "aarch64-macos", npm: "darwin-arm64", ext: "" },
  { zig: "x86_64-macos", npm: "darwin-x64", ext: "" },
  { zig: "aarch64-linux", npm: "linux-arm64", ext: "" },
  { zig: "x86_64-linux", npm: "linux-x64", ext: "" },
  // Windows not supported yet (requires Windows Console API instead of POSIX termios)
];

console.log("Building snipetype for all platforms...\n");

for (const { zig, npm, ext } of TARGETS) {
  console.log(`Building for ${zig}...`);

  try {
    execSync(`zig build -Doptimize=safe -Dtarget=${zig}`, {
      cwd: root,
      stdio: "inherit",
    });

    const src = join(root, "zig-out", "bin", `snipetype${ext}`);
    const destDir = join(__dirname, npm, "bin");
    const dest = join(destDir, `snipetype${ext}`);

    if (!existsSync(src)) {
      console.error(`  Error: Binary not found at ${src}`);
      process.exit(1);
    }

    mkdirSync(destDir, { recursive: true });
    cpSync(src, dest);
    if (!ext) chmodSync(dest, 0o755);

    console.log(`  ✓ ${dest}\n`);
  } catch (e) {
    console.error(`  Failed to build for ${zig}: ${e.message}`);
    process.exit(1);
  }
}

console.log("Build complete!");
