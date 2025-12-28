#!/usr/bin/env node
import { readFileSync, writeFileSync } from "fs";
import { execSync } from "child_process";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const version = process.argv[2]?.replace(/^v/, "");
if (!version) {
  console.error("Usage: node release.mjs <version>");
  console.error("Example: node release.mjs 0.1.0");
  process.exit(1);
}

// Validate version format
if (!/^\d+\.\d+\.\d+(-[\w.]+)?$/.test(version)) {
  console.error(`Invalid version format: ${version}`);
  console.error("Expected format: X.Y.Z or X.Y.Z-tag");
  process.exit(1);
}

const PACKAGES = [
  // Platform packages first (main package depends on them)
  "darwin-arm64",
  "darwin-x64",
  "linux-arm64",
  "linux-x64",
  // Main package last
  "snipetype",
];

console.log(`\nUpdating all packages to version ${version}...\n`);

// Update all versions
for (const pkg of PACKAGES) {
  const pkgPath = join(__dirname, pkg, "package.json");
  const json = JSON.parse(readFileSync(pkgPath, "utf8"));
  json.version = version;

  // Update optionalDependencies versions in main package
  if (json.optionalDependencies) {
    for (const dep of Object.keys(json.optionalDependencies)) {
      json.optionalDependencies[dep] = version;
    }
  }

  writeFileSync(pkgPath, JSON.stringify(json, null, 2) + "\n");
  console.log(`  ✓ Updated ${pkg} to ${version}`);
}

console.log(`\nPublishing packages to npm...\n`);

// Publish all packages
for (const pkg of PACKAGES) {
  const pkgDir = join(__dirname, pkg);
  const pkgJson = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8"));
  console.log(`Publishing ${pkgJson.name}@${version}...`);

  try {
    execSync("npm publish --access public", {
      cwd: pkgDir,
      stdio: "inherit",
    });
    console.log(`  ✓ Published ${pkgJson.name}@${version}\n`);
  } catch (e) {
    console.error(`  ✗ Failed to publish ${pkgJson.name}`);
    process.exit(1);
  }
}

console.log(`\n✓ Successfully published snipetype@${version}`);
console.log(`\nUsers can now run:`);
console.log(`  bunx snipetype@${version}`);
console.log(`  npx snipetype@${version}`);
