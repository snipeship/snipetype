import { extname, resolve } from "node:path";

const WEB_ROOT = resolve(import.meta.dir);

const contentTypesByExt = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".woff2", "font/woff2"],
]);

function withNoStore(headers) {
  const next = new Headers(headers);
  next.set("Cache-Control", "no-store");
  return next;
}

function safeResolvePathname(pathname) {
  const relative = pathname.replace(/^\/+/, "");
  const resolved = resolve(WEB_ROOT, relative);
  if (resolved === WEB_ROOT || resolved.startsWith(WEB_ROOT + "/"))
    return resolved;
  return null;
}

async function fileResponse(filePath) {
  const file = Bun.file(filePath);
  if (!(await file.exists())) return null;

  const headers = withNoStore();
  const contentType = contentTypesByExt.get(extname(filePath));
  if (contentType) headers.set("Content-Type", contentType);
  return new Response(file, { headers });
}

function startServer(port) {
  return Bun.serve({
    port,
    async fetch(req) {
      const url = new URL(req.url);
      let pathname = decodeURIComponent(url.pathname);
      if (pathname === "/") pathname = "/index.html";

      const resolvedPath = safeResolvePathname(pathname);
      if (!resolvedPath)
        return new Response("Not found", {
          status: 404,
          headers: withNoStore(),
        });

      return (
        (await fileResponse(resolvedPath)) ||
        new Response("Not found", { status: 404, headers: withNoStore() })
      );
    },
  });
}

const requestedPort = Number(process.env.PORT) || 8080;
let server = null;

for (const port of [requestedPort, requestedPort + 1, requestedPort + 2]) {
  try {
    server = startServer(port);
    break;
  } catch (err) {
    if (
      err &&
      typeof err === "object" &&
      "code" in err &&
      err.code === "EADDRINUSE"
    )
      continue;
    throw err;
  }
}

if (!server)
  throw new Error(
    `Failed to start dev server on ports ${requestedPort}-${requestedPort + 2}`,
  );

console.log(`ONE web dev server running on http://localhost:${server.port}`);
