// Hearth's service worker, for GitHub Pages. js/engine/pie.js registers it before Pie starts. Its scope is
// this folder (app/), which covers Pie's worker (app/vendor/pie/worker.mjs): the part that reads the model.
//
// 1. The model, from pieces. GitHub Pages allows 100 MB per file, so the 648 MB model lives in the
//    hearth-model repo as 48 MiB pieces next to a manifest (tools/split-model.mjs). A request for X.wgpu.zt
//    that has an X.wgpu.zt.json manifest is answered here from the pieces, HEAD and Range included, as if X
//    were one file. Without a manifest (tools/serve.mjs serves the whole file) the request goes through.
// 2. Headers Pages can't send. Same-origin responses get COOP/COEP, as in pie-decoder's worker. (Pie's
//    browser runtime, server-web 0.6.4, also runs without cross-origin isolation: the app page itself sits
//    outside this scope.) Pie's worker script also gets a Content-Security-Policy, so the worker that runs
//    the model may only fetch from this site, like the page.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

const WORKER_CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; object-src 'none'; base-uri 'none'";

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.cache === "only-if-cached" && request.mode !== "same-origin") return;
  if (url.pathname.endsWith(".wgpu.zt")) event.respondWith(model(event, url.origin + url.pathname));
  else event.respondWith(withHeaders(request));
});

async function withHeaders(request) {
  const response = await fetch(request);
  if (response.status === 0) return response; // a redirect or opaque response: pass it on as is
  const headers = new Headers(response.headers);
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("Cross-Origin-Embedder-Policy", "require-corp");
  if (request.destination === "worker") headers.set("Content-Security-Policy", WORKER_CSP);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

// ---- The model, from pieces ---------------------------------------------------------------------------

const manifests = new Map(); // model URL -> its manifest, or null when it has none (a whole file)

async function manifestFor(url) {
  if (manifests.has(url)) return manifests.get(url);
  const response = await fetch(`${url}.json`); // a network error throws, and the next request asks again
  const manifest = response.ok ? await response.json() : null;
  manifests.set(url, manifest);
  return manifest;
}

async function model(event, url) {
  const m = await manifestFor(url);
  if (!m) return withHeaders(event.request);

  let start = 0;
  let end = m.size - 1;
  const headers = { "accept-ranges": "bytes", "content-type": "application/octet-stream", etag: `"${m.sha256}"` };
  const asked = event.request.headers.get("range");
  const range = asked?.match(/^bytes=(\d+)-(\d*)$/);
  if (asked && !range) return new Response(null, { status: 416, headers: { ...headers, "content-range": `bytes */${m.size}` } });
  if (range) {
    start = Number(range[1]);
    if (range[2]) end = Math.min(Number(range[2]), m.size - 1);
    if (start > end) return new Response(null, { status: 416, headers: { ...headers, "content-range": `bytes */${m.size}` } });
    headers["content-range"] = `bytes ${start}-${end}/${m.size}`;
  }
  headers["content-length"] = String(end - start + 1);
  const status = range ? 206 : 200;
  if (event.request.method === "HEAD") return new Response(null, { status, headers });

  // Which bytes of which pieces make up start..end.
  const parts = [];
  for (let i = Math.floor(start / m.piece); i * m.piece <= end; i++) {
    const from = Math.max(start, i * m.piece) - i * m.piece;
    const to = Math.min(end, (i + 1) * m.piece - 1) - i * m.piece;
    parts.push({ url: `${url}.${String(i).padStart(2, "0")}`, from, to });
  }
  const body = joined(parts);
  event.waitUntil(body.done); // keep this worker alive until the last byte is out
  return new Response(body.stream, { status, headers });
}

/** One stream that reads the parts one after another. */
function joined(parts) {
  let reader = null;
  let left = 0; // bytes still owed from the current part
  let finish;
  const done = new Promise((resolve) => (finish = resolve));
  const stream = new ReadableStream({
    async pull(controller) {
      try {
        for (;;) {
          if (!reader) {
            const part = parts.shift();
            if (!part) {
              controller.close();
              return finish();
            }
            const response = await fetch(part.url, { headers: { range: `bytes=${part.from}-${part.to}` } });
            // 206 is the answer to a range; a 200 (the whole piece) only works when the range starts at 0.
            if (response.status !== 206 && !(response.status === 200 && part.from === 0)) {
              throw new Error(`${part.url}: ${response.status} to a range request`);
            }
            reader = response.body.getReader();
            left = part.to - part.from + 1;
          }
          const { done: ended, value } = await reader.read();
          if (ended) {
            if (left > 0) throw new Error("a piece of the model ended early");
            reader = null;
            continue;
          }
          const chunk = value.length > left ? value.subarray(0, left) : value;
          left -= chunk.length;
          if (left === 0) {
            reader.cancel().catch(() => {});
            reader = null;
          }
          if (chunk.length) return controller.enqueue(chunk);
        }
      } catch (e) {
        controller.error(e);
        finish();
      }
    },
    cancel() {
      reader?.cancel().catch(() => {});
      finish();
    },
  });
  return { stream, done };
}
