# Hearth

**A little town of friends that lives on your phone, and stays there.**

Hearth is a private, offline companion app for iPhone in the spirit of Character.AI. A whole seaside town of
characters, Lantern Bay, runs on the phone itself: the language model, the voices, the pictures and every
word you type. There is no account, no server and no analytics. After a one-time model download it works in
Airplane Mode.

- **Web version** (runs the model in your browser with WebGPU): https://aarushkandukoori.github.io/hearth/
- **iPhone app**: build it from this repo (see below). It is not on the App Store yet.

## What makes it different

- **A whole town.** Sixteen residents with homes, daily schedules and friendships. Walk into the café or
  the night market and whoever is there talks to you and to each other. They remember what happened in town
  while you were away.
- **Voice notes and pictures.** Characters sometimes answer with a voice note (on-device voices) or a picture.
  Pictures are drawn on the iPhone with Apple Image Playground when it can; otherwise the friend sends a postcard
  or a picture from the town's own art. Photos you send are described on the phone, never uploaded.
- **Switch friends instantly.** Each conversation's model memory (its KV cache) is parked on the phone's
  storage when you leave and restored when you come back, so a long chat does not have to be re-read.
- **Private by design.** Face ID lock, hidden in the app switcher, chats excluded from iCloud backup by
  default, encrypted export, delete everything.
- **Kind by design.** No streaks, no guilt trips, characters never discourage your real friendships, and
  crisis resources appear on the phone if someone is in danger. For adults (18+).

## Measured on an iPhone 16 Pro

Llama 3.2 3B (Q4_K_M) through llama.cpp b12180 with Metal, five residents with about 1,200 tokens of chat each
(`-HearthBenchmark 1`; raw results in `ios/EngineLab/device-results/`):

| | |
|---|---|
| Reading a chat from scratch (prefill about 220 tokens/s) | about 6 s to the first word (5.5 to 8.3 s) |
| Restoring the parked KV cache from storage | about 50 ms (46 to 57 ms), about 72 MB per conversation |
| First word after switching back | about 0.37 s, roughly 18x faster |
| Parking a conversation | about 85 ms |
| Generation speed | about 21 tokens/s |
| App memory footprint with the model loaded | about 420 MB (weights are memory-mapped), about 3 GB still free |

## How it works

| Piece | What it uses |
|---|---|
| Language model | [llama.cpp](https://github.com/ggml-org/llama.cpp) (b12180, Metal) running Llama 3.2 3B Instruct (Q4_K_M, 2.0 GB). Lite: Llama 3.2 1B. Plus: Qwen3 4B Instruct 2507. Apple's on-device Foundation Model works as a no-download fallback. |
| Instant resume | `llama_state_seq_save_file` / `load_file` per conversation, LRU on flash, prefix reuse within a chat |
| Group scenes | One shared prompt prefix per scene (cast + transcript) with the speaker forced at the end, so every turn reuses the KV cache |
| Voices | `AVSpeechSynthesizer`, a distinct on-device voice per character; push-to-talk with on-device `SFSpeechRecognizer` |
| Pictures | Apple Image Playground (`ImageCreator`), with postcards and the town's own art as a fallback |
| Photos you send | Vision (labels, text, animals) turned into a short caption |
| Storage | JSON files with complete file protection, AES-GCM encrypted export |

```
ios/        SwiftUI app (XcodeGen), engine harness (ios/EngineLab), unit tests
content/    Lantern Bay world and cast (shared by the app and the website)
docs/       the website (GitHub Pages): web app at the root, iPhone page, privacy, safety
```

## Build the iPhone app

You need a Mac with Xcode 26 and an iPhone on iOS 26 (iPhone 15 Pro or newer recommended for the 3B model).

```bash
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

On first launch Hearth asks which model to download (Wi-Fi recommended).

## License

MIT (see `LICENSE`). Model weights are downloaded from Hugging Face under their own licenses (Llama 3.2
Community License, Apache 2.0 for Qwen3).

Built with Llama. Llama 3.2 is licensed under the
[Llama 3.2 Community License](https://www.llama.com/llama3_2/license/), and its use must follow the
[Llama 3.2 Acceptable Use Policy](https://www.llama.com/llama3_2/use-policy/).

Third-party code in this repo keeps its own license:

- [llama.cpp](https://github.com/ggml-org/llama.cpp) b12180 with ggml (MIT), prebuilt in
  `ios/Vendor/llama.xcframework` and embedded in the iPhone app.
- [WebLLM](https://github.com/mlc-ai/web-llm) 0.2.87 (Apache 2.0), in `docs/app/vendor/web-llm` with its `LICENSE`.
