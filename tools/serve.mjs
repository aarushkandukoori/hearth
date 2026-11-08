// Local server for the website in docs/, with the cross-origin isolation
// headers (COOP/COEP; Pie's browser runtime 0.6.4 also runs without them) and
// Range requests (Pie reads the model file in pieces). On GitHub Pages, which
// can't send headers, docs/app/sw.js serves the model from its pieces instead.
//
//   node tools/serve.mjs [port]
//   HEARTH_MODELS=/path/to/dir node tools/serve.mjs   # serve model files at /models/
import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";

const ROOT = resolve(import.meta.dirname, "..", "docs");
const MOUNTS = [["/models/", process.env.HEARTH_MODELS], ["/__lab/", process.env.HEARTH_LAB]]
  .filter(([, dir]) => dir)
  .map(([prefix, dir]) => [prefix, resolve(dir)]);
const PORT = Number(process.argv[2] ?? 8822);
// The policy docs/app/sw.js gives Pie's worker on GitHub Pages, so local runs check the same thing: the
// worker that runs the model may only fetch from this site.
const WORKER_CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; object-src 'none'; base-uri 'none'";
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".wasm": "application/wasm",
};

function locate(pathname) {
  for (const [prefix, dir] of MOUNTS) {
    if (pathname.startsWith(prefix)) return [dir, pathname.slice(prefix.length - 1)];
  }
  return [ROOT, pathname];
}

createServer(async (req, res) => {
  let path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (path.endsWith("/")) path += "index.html";
  const [base, rel] = locate(path);
  const file = join(base, rel);
  let info;
  try {
    if (!file.startsWith(base + sep)) throw new Error("outside root");
    info = await stat(file);
    if (!info.isFile()) throw new Error("not a file");
  } catch {
    res.writeHead(404, { "cross-origin-resource-policy": "same-origin" }).end("not found");
    return;
  }
  const headers = {
    "content-type": TYPES[extname(file)] ?? "application/octet-stream",
    "cache-control": "no-store",
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-embedder-policy": "require-corp",
    "cross-origin-resource-policy": "same-origin",
    "accept-ranges": "bytes",
  };
  if (req.headers["sec-fetch-dest"] === "worker") headers["content-security-policy"] = WORKER_CSP;
  const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
  if (range) {
    const start = Number(range[1]);
    const end = range[2] ? Math.min(Number(range[2]), info.size - 1) : info.size - 1;
    if (start >= info.size) {
      res.writeHead(416, { ...headers, "content-range": `bytes */${info.size}` }).end();
      return;
    }
    res.writeHead(206, { ...headers, "content-range": `bytes ${start}-${end}/${info.size}`, "content-length": end - start + 1 });
    if (req.method === "HEAD") return res.end();
    createReadStream(file, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, { ...headers, "content-length": info.size });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}).listen(PORT, "127.0.0.1", () => console.log(`http://127.0.0.1:${PORT}/`));
