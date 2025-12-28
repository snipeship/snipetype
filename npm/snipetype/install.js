const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const https = require("https");

const PLATFORMS = {
  "darwin-arm64": "@snipetype/darwin-arm64",
  "darwin-x64": "@snipetype/darwin-x64",
  "linux-arm64": "@snipetype/linux-arm64",
  "linux-x64": "@snipetype/linux-x64",
};

const VERSION = require("./package.json").version;
const platform = `${process.platform}-${process.arch}`;
const pkg = PLATFORMS[platform];

if (!pkg) {
  console.warn(`snipetype: Unsupported platform ${platform}, skipping binary download`);
  process.exit(0);
}

const bin = "snipetype";

// Check if already installed via optionalDependencies
try {
  require.resolve(`${pkg}/bin/${bin}`);
  process.exit(0); // Already installed
} catch {
  // Not installed, need to download
}

console.log(`snipetype: Downloading binary for ${platform}...`);

function fetch(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return fetch(res.headers.location).then(resolve, reject);
        }
        if (res.statusCode !== 200) {
          return reject(new Error(`HTTP ${res.statusCode}`));
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

function extractFromTarball(tarball, filepath) {
  let offset = 0;
  while (offset < tarball.length) {
    const name = tarball.toString("utf8", offset, offset + 100).replace(/\0.*/, "");
    const size = parseInt(
      tarball.toString("utf8", offset + 124, offset + 136).replace(/\0.*/, ""),
      8
    );
    offset += 512;
    if (name === filepath) {
      return tarball.subarray(offset, offset + size);
    }
    offset += Math.ceil(size / 512) * 512;
  }
  throw new Error(`${filepath} not found in tarball`);
}

(async () => {
  const pkgName = pkg.split("/")[1]; // e.g., "darwin-arm64"
  const tgz = await fetch(
    `https://registry.npmjs.org/${pkg}/-/${pkgName}-${VERSION}.tgz`
  );
  const tar = zlib.gunzipSync(tgz);
  const binary = extractFromTarball(tar, `package/bin/${bin}`);
  const dest = path.join(__dirname, bin);
  fs.writeFileSync(dest, binary, { mode: 0o755 });
  console.log(`snipetype: Binary installed successfully`);
})().catch((e) => {
  console.error(`snipetype: Failed to download binary: ${e.message}`);
  console.error("You may need to install the platform-specific package manually:");
  console.error(`  npm install ${pkg}`);
  process.exit(1);
});
