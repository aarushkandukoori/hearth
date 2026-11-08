// Splits Hearth's model file into 48 MiB pieces plus a manifest, for GitHub Pages (100 MB per file at most).
// docs/app/sw.js joins the pieces back into one file for Pie, HEAD and Range requests included, and the app
// downloads them one after another into the browser's own storage (see docs/app/js/engine/pie.js).
//
//   node tools/split-model.mjs <model.wgpu.zt> <out-dir> [name]
//   -> <out-dir>/<name>.json, <name>.00, <name>.01, ... and an empty .nojekyll
//
// name defaults to qwen3.5-0.8b-vision.wgpu.zt, the file name the web app asks for. Put the output at the root
// of the hearth-model repo, so the model is served at https://aarushkandukoori.github.io/hearth-model/<name>.
import { createHash } from "node:crypto";
import { createReadStream, createWriteStream, mkdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { once } from "node:events";

const [src, outDir, name = "qwen3.5-0.8b-vision.wgpu.zt"] = process.argv.slice(2);
if (!src || !outDir) {
  console.error("usage: node tools/split-model.mjs <model.wgpu.zt> <out-dir> [name]");
  process.exit(2);
}
const PIECE = 48 * 1048576;
const size = statSync(src).size;
const pieces = Math.ceil(size / PIECE);
if (pieces > 100) throw new Error("more than 100 pieces: the two-digit piece names would run out");
mkdirSync(outDir, { recursive: true });

const hash = createHash("sha256");
for (let i = 0; i < pieces; i++) {
  const file = join(outDir, `${name}.${String(i).padStart(2, "0")}`);
  const out = createWriteStream(file);
  for await (const chunk of createReadStream(src, { start: i * PIECE, end: Math.min(size, (i + 1) * PIECE) - 1 })) {
    hash.update(chunk);
    if (!out.write(chunk)) await once(out, "drain");
  }
  out.end();
  await once(out, "finish");
  console.log(`${file}  ${statSync(file).size} bytes`);
}
const manifest = { size, piece: PIECE, pieces, sha256: hash.digest("hex") };
writeFileSync(join(outDir, `${name}.json`), JSON.stringify(manifest, null, 2) + "\n");
writeFileSync(join(outDir, ".nojekyll"), ""); // GitHub Pages serves the files as they are
console.log(manifest);
