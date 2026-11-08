# Hearth

**A little town of friends that lives on your phone, and stays there.**

Hearth is a private, offline companion app for iPhone, with a web version, in the spirit of Character.AI. A
whole seaside town of animal-folk characters, Lantern Bay, runs on your own device: the language model, the
voices, the pictures and every word you type. There is no account, no server and no analytics. After a
one-time model download it works in Airplane Mode.

The language model is Qwen3.5, run right on the device by [Pie](https://github.com/pie-project/pie), Yale's
programmable LLM serving system.

- **Web version** - https://aarushkandukoori.github.io/hearth/ (Pie runs the model in the tab; needs Chrome
  137 or newer)
- **iPhone app** - build it from this repo (see below). It is not on the App Store yet.

## Built on Pie

Every language-model call in Hearth goes through [Pie](https://github.com/pie-project/pie) (Apache 2.0), from
Prof. Lin Zhong's lab at Yale. In Pie, an app runs the model through a small program of its own, an
*inferlet*, which builds the prompt, runs the model's forward passes and picks each token. Hearth has one
inferlet, written in Rust and compiled to WebAssembly ([`inferlet/`](inferlet/)). For each reply it:

- renders the chat with the model's own chat template;
- forces the speaker's name in group scenes, and a fixed caring opener with the 988 line when a message sounds
  like a crisis, so a small model can't answer with a canned refusal;
- samples on the device, with a repetition penalty (1.1), temperature, top-k 40, min-p 0.05 and top-p 0.95;
- stops on stop strings without ever showing them, and streams each piece back as it's written;
- reads the prompt in two passes, so Pie keeps a recurrent-state checkpoint at the end of the first. The next
  turn's prompt starts with the same tokens, so when Pie still holds that checkpoint it maps the earlier turns
  back in and reads only what's new.

A caption mode describes a photo with the model's own vision tower. [`inferlet/README.md`](inferlet/README.md)
has the details.

The same source is built twice:

| | Pie | Runs on | Model |
|---|---|---|---|
| iPhone | Pie main `6168f025d` plus two small fixes, in-process | Metal | Hearth Standard (Qwen3.5 2B) or Hearth Lite (Qwen3.5 0.8B with vision) |
| Web | `@pie-project/server-web` 0.6.4, in a Web Worker | WebGPU | Qwen3.5 0.8B with vision |

**On the iPhone**, Pie's Metal engine runs inside the app through Pie's own Swift package (`PieServer` and
`PieClient`, vendored in `ios/Vendor/PieSwift`, unchanged apart from a trimmed `Package.swift`). It links Pie's
C library, which [`ios/scripts/build-pie.sh`](ios/scripts/build-pie.sh) builds from Pie main `6168f025d` plus
[`ios/scripts/pie-ios-fixes.patch`](ios/scripts/pie-ios-fixes.patch). The engine code is
[`ios/Hearth/Engine/PieEngine.swift`](ios/Hearth/Engine/PieEngine.swift). The models are Pie Metal artifacts made
with `pie model import`:

| Model | Pie deployment | Size | Photos you send |
|---|---|---|---|
| Hearth Standard, Qwen3.5 2B | `qwen35-d2b-u4g64-kv-bf16` | 1,074,698,212 bytes (about 1.1 GB) | described from Apple's Vision labels |
| Hearth Lite, Qwen3.5 0.8B with vision | `qwen35-d0.8b-vision-u4g64-kv-bf16` | 648,146,919 bytes (about 650 MB) | described by Pie's caption mode |

The app downloads one once from this repo's GitHub release
[`pie-models-1`](https://github.com/aarushkandukoori/hearth/releases/tag/pie-models-1) and checks its SHA-256, or
you can push one over USB. Pie boots once per app launch with one model, so a new model choice takes over the
next time Hearth opens.

**On the web**, Pie's browser runtime (`@pie-project/server-web` 0.6.4, vendored in `docs/app/vendor/pie`) runs
Pie's WebGPU engine in the tab. The model is Qwen3.5 0.8B with vision, a Pie wgpu artifact of 648,146,918 bytes
(about 650 MB), downloaded once into the browser's own storage. GitHub won't host one file that big, so it's
served from the [hearth-model](https://github.com/aarushkandukoori/hearth-model) repo as 13 pieces of 48 MiB at
https://aarushkandukoori.github.io/hearth-model/qwen3.5-0.8b-vision.wgpu.zt, and `docs/app/sw.js` joins them
back into one file for Pie. It needs Chrome 137 or newer (WebGPU and WebAssembly JSPI). Photos are described by
Pie's caption mode. A message that sounds like a crisis gets a fixed caring reply, without the model.

## What makes it different

- **A whole town** - Sixteen residents with homes, daily schedules and friendships. Walk into the café or the
  night market and whoever is there talks to you and to each other. They remember what happened in town while
  you were away.
- **Quick next replies** - Pie keeps what it has read. With Hearth Standard on an iPhone 16 Pro, the next reply
  in a chat starts in about 0.3 s, and in a group scene the next speaker starts in about 0.3 to 0.6 s.
  Switching to another friend and back usually means reading the chat again.
- **Voice notes** - Characters sometimes answer with a voice note, each in their own on-device voice. Any
  message can be read aloud, and you can hold the mic to talk back, in a chat or a call.
- **Pictures from town** - Characters send a picture from the town's own art that fits the moment, or a
  postcard drawn on the phone. Photos you send are described on the device, never uploaded.
- **Private by design** - Pie runs inside the app, with no server and no network port. Face ID lock, hidden in
  the app switcher, chats left out of iCloud backup by default, encrypted export, delete everything.
- **Kind by design** - No streaks, no guilt trips, characters written to cheer on your real friendships, and
  crisis resources appear on the phone if someone is in danger. For adults (18+).

## Measured on an iPhone 16 Pro

iPhone 16 Pro (8 GB), iOS 26, Release build, Pie main `6168f025d` plus `pie-ios-fixes.patch`, Hearth Standard
(Qwen3.5 2B). Pie config: KV budget 512 MiB, 8 state slots, 2 lanes, at most 4,096 tokens.

| | |
|---|---|
| Pie boots | 0.35 to 1.2 s on a warm launch (about 2 s on the first launch after install) |
| Reading a chat of about 1,300 tokens from scratch | first word in about 2.4 to 2.6 s (prefill about 500 to 540 tokens/s) |
| Reading a 2,185-token chat from scratch | first word in 5.0 s |
| Writing | about 20 to 40 tokens/s (benchmark averages 29 to 36, replies in the app tour 17 to 31) |
| The next reply in the same chat (app tour) | Pie reused 2,176 of 2,263 prompt tokens, first word in 0.31 s. The reply after that reused 2,256 of 2,371, first word in 0.30 s |
| Group scene, each next speaker | about 1,500 to 1,700 tokens reused, first word in 0.26 to 0.61 s |
| Switching to another character and back | usually reads the chat again, first word in about 3 to 4 s |
| Memory | about 1.6 to 1.7 GB after boot. Peak about 2.5 GB over 15 long prompts, with about 0.9 GB still free |
| Hearth Lite (Qwen3.5 0.8B with vision) | boots in about 0.35 s, describes a photo in about 1.6 s |

Coming back to a chat after other chats usually means reading it again, because Pie drops a kept checkpoint
whenever a live reply needs its state slot (finding 4 below). Before the KV budget was set, Pie's default pool
grew until iOS killed the app at about 2.8 GB (finding 3).

The benchmark is `ios/scripts/device.sh run -HearthBenchmark 1` and the app tour is `-HearthUITour 1`.
`device.sh` defaults to one particular iPhone and the project's own bundle ID, so on yours set
`DEVICE=<identifier>` (from `xcrun devicectl list devices`) and change `BUNDLE` at its top before
`device.sh install` or `run`. `device.sh build` runs `xcodegen`, which puts back the project's own team and
bundle ID, so set yours in `ios/project.yml` first. The 179 unit tests pass on the Simulator, which links a stub
in place of Pie: Pie runs on a real iPhone only.

**Web**, measured in a hidden browser pane, so rough: a one-time model download of about 650 MB, Pie boots in 2
to 10 s, a fresh read at about 490 to 550 tokens/s, 28 to 42 tokens/s writing, a photo description in about 1.5 to
2.5 s. Within a tab Pie keeps the checkpointed pages on the graphics chip between replies: the next reply reused
992 of 1,075 prompt tokens (first word in 0.44 s instead of 1.83 s), and coming back to a chat after two others
reused 1,584 of 1,660 (0.37 s). server-web 0.6.4 has no host or disk KV tier, so after a reload the first reply
reads the chat again.

## What isn't on Pie yet, and why

- **Voices** - Voice notes and calls use Apple's on-device speech on the iPhone (`AVSpeechSynthesizer` voices,
  `SFSpeechRecognizer` dictation) and the browser's speech APIs on the web. Pie runs Qwen3-TTS and Qwen3-ASR,
  but a Pie process holds one model, and on the phone that model is the characters' language model.
- **New pictures** - Pictures come from the town's own art or a postcard drawn on the phone. Pie can draw with
  FLUX.2 klein, and the same one-model limit applies. The bundled town art was drawn earlier with Apple's
  Image Playground and ships as static images.
- **Photos with Hearth Standard** - Qwen3.5 2B as deployed here has no vision tower, so photo descriptions come
  from Apple's Vision labels. Hearth Lite and the web use Pie's caption mode.

## What we found in Pie

Moving Hearth onto Pie turned up these. They have been reported to the Pie team. Paths starting with `crates/`
are in Pie at `6168f025d`.

1. **Wasm growth reservation on iOS** - wasmtime's default 2 GiB growth reservation for every inferlet instance
   often can't be found in an iPhone's address space once the engine's pools are mapped, so instantiation fails
   with `failed to allocate 0x80110000 bytes`. The fix, in `crates/runtime/src/bootstrap.rs` (the iOS
   `configure_execution`), sets `memory_reservation_for_growth` to the inferlet memory cap. It's one of the two
   fixes in `ios/scripts/pie-ios-fixes.patch`.
2. **The last state slot on Metal** - The recurrent-state slab is reserved at exactly slots x 3.56 MB, but commits
   round up to 2 MiB pages, so the commit that reaches the last slot always fails. With 16 or fewer slots no
   slot is ever usable and every reply fails. The fix clamps the commit to the buffer length
   (`crates/engine-metal/src/rs.rs:392`). It's the other fix in the patch.
3. **Memory limits on iOS** - Pie sizes its KV and state pools from Metal's working-set hint, about 6 GB here.
   iOS lets one app use about 3.4 GB, and Pie has no iOS memory-pressure reader, so iOS kills the app. Hearth's
   workaround is to state `device_kv_budget` (`phoneConfiguration` in `ios/Hearth/Engine/PieEngine.swift`).
4. **Keeping KV for hybrid models like Qwen3.5** - KV pages are kept from one inferlet process to the next only
   through recurrent-state checkpoints. A checkpoint inside a long prefill (which Pie cuts into 512-row fires) is silently refused, and
   kept checkpoints are dropped when a live write needs a state slot. Hearth's workaround is the two-pass
   prefill in `inferlet/src/lib.rs`. Reuse works within a conversation. Across chat switches it's unreliable.
5. **server-web 0.6.4 keeps nothing past the tab** - It has no host or disk KV tier and no client-owned
   working-set handles (both are on main). With the two-pass prefill the browser does reuse the chat within a tab,
   but a reload starts cold (`docs/app/js/engine/pie.js`).
6. **One model per process** - Qwen3-TTS, Qwen3-ASR and FLUX.2 can't run beside the chat model on the phone
   (`ios/Hearth/Media/PictureMaker.swift`).
7. **Durable snapshots on CUDA only** - They save recurrent state on CUDA only, so on Metal a chat's state can't be written to
   storage and picked up after a relaunch (`ios/Hearth/Engine/PieEngine.swift`).
8. **No way to drop one chat's cache** - There's no client call to drop one chat's cached KV, so a deleted message can
   stay in Pie's cache until it's evicted. It's never shown and never leaves the phone, and Delete everything
   empties Pie's KV disk tier (`deleteFiles` in `ios/Hearth/Store/PrivacyVault.swift`).

## Build the iPhone app

You need a Mac with Xcode 26, [Rust](https://rustup.rs) and XcodeGen, and an iPhone on iOS 26. Hearth Standard
is suggested on iPhones with 6 GB of memory or more, and Lite on the rest. From a clone of this repo:

```bash
# Pie's iPhone library: Pie main 6168f025d plus ios/scripts/pie-ios-fixes.patch.
# The first build takes a while. It writes ios/Vendor/PieSwift/build/PieServerCore.xcframework.
git clone https://github.com/pie-project/pie.git ~/src/pie
git -C ~/src/pie checkout 6168f025d
PIE_DIR=~/src/pie ios/scripts/build-pie.sh

# The Xcode project
brew install xcodegen
cd ios && xcodegen
open Hearth.xcodeproj
```

1. Add your Apple ID under Xcode > Settings > Accounts. A free Apple ID works; free apps expire after 7 days
   (press Run again to renew) and iOS allows three of them at a time.
2. Select the Hearth target, open Signing & Capabilities, pick your own team and change the Bundle Identifier
   to something of your own, like `com.yourname.hearth`. The project's own ID is already taken, so Xcode
   cannot register it for your team. Running `xcodegen` again resets both, so set them again after each run.
3. Connect your iPhone, choose it as the run destination and press Run. If the iPhone asks, turn on Developer
   Mode in Settings > Privacy & Security.
4. The first time, trust your developer certificate on the iPhone in Settings > General > VPN & Device
   Management, then open Hearth.

In the Simulator, the app builds with a stub in place of Pie and falls back to demo replies, so real replies
need an iPhone.

### Models

On first launch Hearth asks which model to download (Wi-Fi recommended). It comes from the GitHub release
`pie-models-1` and is checked against the SHA-256 in
[`ios/Hearth/Engine/ModelCatalog.swift`](ios/Hearth/Engine/ModelCatalog.swift).

You can also make a model with Pie's own tool and copy it over USB. `--out` writes the file under the name the
catalog uses (`qwen3.5-2b.metal.zt` for Standard, `qwen3.5-0.8b-vision.metal.zt` for Lite). Without it, Pie
keeps the file in its own model store under a longer name. Then push it:

```bash
pie model import Qwen/Qwen3.5-2B --deployment qwen35-d2b-u4g64-kv-bf16 --out qwen3.5-2b.metal.zt
pie model import Qwen/Qwen3.5-0.8B --deployment qwen35-d0.8b-vision-u4g64-kv-bf16 --out qwen3.5-0.8b-vision.metal.zt
xcrun devicectl list devices      # your iPhone's identifier
DEVICE=<identifier> ios/scripts/device.sh push-model qwen3.5-2b.metal.zt
```

Hearth uses a pushed file as Standard or Lite when its name and size match the catalog. Any other Pie artifact
loads with the launch argument `-HearthModel <file name>`. `device.sh` uses the project's own bundle ID, so
change `BUNDLE` at its top if you changed yours.

## Rebuild the inferlet

The built inferlet ships in the repo twice: `ios/Hearth/Resources/Pie/hearth.wasm` for the iPhone and
`docs/app/pie/hearth.wasm` for the web. After changing `inferlet/src`, rebuild both. `inferlet/build.sh` points
the `inferlet` crate at a local Pie checkout for each build, so it needs one at `6168f025d` (the one from the
iPhone build works) and one at server-web 0.6.4 (`75eb46bd7`):

```bash
rustup toolchain install nightly-2026-10-18 --target wasm32-wasip3   # the pin in inferlet/rust-toolchain.toml
git clone https://github.com/pie-project/pie.git ~/src/pie-0.6.4
git -C ~/src/pie-0.6.4 checkout 75eb46bd7
PIE_IPHONE=~/src/pie PIE_WEB=~/src/pie-0.6.4 inferlet/build.sh       # or: inferlet/build.sh iphone|web
```

## The web version

The website is `docs/`, served by GitHub Pages: the web app at the root, plus the iPhone, privacy and safety
pages. To run it locally:

```bash
HEARTH_MODELS=/path/to/model/folder node tools/serve.mjs    # http://127.0.0.1:8822/
```

`tools/serve.mjs` serves `docs/` with cross-origin isolation headers and Range requests, and the files in
`HEARTH_MODELS` under `/models/`. On localhost the app loads the model from there as
`qwen3.5-0.8b-vision.wgpu.zt` (`MODEL.url` in `docs/app/js/engine/pie.js`), so put it in that folder under
that name. It's the same file as the published `qwen3.5-0.8b-vision.wgpu.zt`, under another name.

To publish the model for GitHub Pages, split it into pieces:

```bash
node tools/split-model.mjs qwen3.5-0.8b-vision.wgpu.zt ../hearth-model
```

That writes 48 MiB pieces (13 for this model), a manifest with the size and SHA-256, and an empty `.nojekyll`.
Push them to the root of the `hearth-model` repo, and Pages serves them at
https://aarushkandukoori.github.io/hearth-model/. `docs/app/sw.js` answers Pie's requests for the model from
the pieces, HEAD and Range requests included.

## Repo layout

```
inferlet/   Hearth's Pie inferlet (Rust, compiled to WebAssembly), one source for the iPhone and the web
ios/        SwiftUI app (XcodeGen), Pie's Swift package (Vendor/PieSwift), Pie build scripts, unit tests
content/    Lantern Bay world and cast (shared by the app and the website)
docs/       the website (GitHub Pages): web app at the root with Pie's browser runtime, iPhone page, privacy, safety
art/        the town's art, compressed (art/opt)
tools/      local web server, model splitter, art and content helpers
```

## License

MIT (see `LICENSE`). Third-party code and models keep their own licenses:

- **Pie** - [pie-project/pie](https://github.com/pie-project/pie), Apache 2.0. Its Swift package is vendored in
  `ios/Vendor/PieSwift` with Pie's `LICENSE` and `NOTICE`. Its C library, `libpie`, is built by
  `ios/scripts/build-pie.sh` and linked into the iPhone app. Its browser runtime, `@pie-project/server-web`
  0.6.4, is in `docs/app/vendor/pie` with the same `LICENSE` and `NOTICE`. The app's About screen shows Pie's
  `NOTICE`, and a note on the Rust crates inside `libpie` and their licenses.
- **Qwen3.5** - Apache 2.0. The models behind Hearth Standard (2B), Hearth Lite (0.8B with vision) and the web
  version, converted for Pie.
