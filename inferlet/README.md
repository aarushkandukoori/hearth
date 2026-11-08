# Hearth's inferlet

Hearth's one program for [Pie](https://github.com/pie-project/pie). Every reply the model writes, and every
photo description, is one launch of it. It's written in Rust and compiled to WebAssembly (`wasm32-wasip3`), and
the same source runs on the iPhone (Pie's Metal engine, in-process) and in the browser (Pie's WebGPU engine).

- `src/lib.rs` - reply mode, with the prompt, the two-pass prefill, sampling, stop strings and streaming
- `src/caption.rs` - caption mode, one or two plain sentences about a photo
- `build.sh` - builds the iPhone and web flavors from this one source

The app installs it as `hearth@0.1.0` and launches it with one JSON input. The callers are
`ios/Hearth/Engine/PieEngine.swift` (`InferletInput`, `CaptionInput`) and `docs/app/js/engine/pie.js`.

## Input

| Field | Default | What it does |
|---|---|---|
| `mode` | `"reply"` | `"reply"` or `"caption"` |
| `turns` | `[]` | The conversation, oldest first, as `{ "role", "content" }` with `system`, `user` and `assistant` roles |
| `prefix` | none | Text forced right after the assistant header and not returned, like `"Theo:"` in a group scene |
| `opener` | none | The fixed start of a reply the person does see, like the caring opener for a crisis message. Forced after `prefix` and not returned, so the app shows `opener + " " + text` |
| `max_tokens` | 220 | Most tokens the reply may have |
| `stop` | `[]` | Stop strings. The reply ends before the first one, which is never shown |
| `temperature` | 0.85 | 0 or less means greedy |
| `top_k` | 40 | Keep only the k most likely tokens (0 turns it off) |
| `min_p` | 0.05 | Drop tokens less likely than `min_p` times the most likely one (0 turns it off) |
| `top_p` | 0.95 | Nucleus sampling (1 samples from everything left) |
| `repeat_penalty` | 1.1 | For tokens the reply has already used (1 turns it off) |
| `seed` | from the clock | For repeatable sampling |
| `stream` | `true` | Send each piece of the reply as a message while it's written |
| `image_b64` | none | Caption mode: the photo, as base64 PNG or JPEG |
| `question` | none | Caption mode: what to ask about the photo, instead of the built-in question |
| `debug_prompt` | `false` | Also return the rendered prompt as text, for checking the template |

## Output

With `stream` on, each piece of shown text arrives as a message as soon as it's safe to show. When the launch
ends it returns one JSON object:

| Field | What it is |
|---|---|
| `text` | The whole shown reply (without `prefix` and `opener`) |
| `prompt_tokens` | Tokens in the prompt, including the forced `prefix` and `opener` |
| `reused_tokens` | Prompt tokens Pie mapped back in from state it already held |
| `prefilled_tokens` | Prompt tokens this launch computed |
| `generated_tokens` | Tokens sampled |
| `stopped_by` | `"eos"`, `"stop"` (a stop string) or `"max_tokens"` |
| `ttft_ms`, `prefill_ms` | From the start of the program to the first sampled token |
| `decode_ms`, `decode_tokens_per_second` | The rest of the reply |
| `page_size` | Pie's KV page size, in tokens |
| `prompt_text` | Only with `debug_prompt` |

## Reply mode

**The prompt.** The turns are rendered with the model's own chat template (`inferlet::chat`), then the
template's cue for a reply without thinking, then any `prefix` and `opener`. A past reply is written the way
this program generates one: the no-thinking cue, the text, then the template's own closing (found by comparing
two one-letter messages). So the next turn's prompt repeats this turn's prompt token for token, which is what
makes reuse possible.

The app uses `prefix` to force the speaker's name in group scenes, and `opener` for the caring opener with the
988 line when a message sounds like a crisis, so a small model can't answer it with a canned refusal.

**Two passes, and why.** Qwen3.5 is a hybrid model, with recurrent layers beside attention. Pie keeps such a
model's KV pages after a launch only through a recurrent-state checkpoint, and it keeps a checkpoint only at
the end of a pass that has finished. A checkpoint inside a long prefill, which Pie cuts into 512-row fires, is
dropped. So the prefill runs as two passes:

1. Pass 1 reads the prompt up to the last whole KV page before the reply and leaves one checkpoint at its end.
   The program waits for it to finish, so the checkpoint and its pages stay.
2. Pass 2 reads the rest (at least the last cue token, plus any forced text) and samples the first token.

The next turn's prompt starts with the same tokens, so its pass 1 resumes from that checkpoint when Pie still
holds it, and computes only the previous reply and the new message. Pie drops a kept checkpoint when a live
write needs its state slot, so reuse isn't guaranteed. `reused_tokens` reports what happened.

**Decoding.** One token per pass, sampled on the device in the pass's epilogue. The tokens the reply has used
so far stay on the device too, for the repetition penalty. The host reads each token to stream it and to stop.

**The sampling chain**, all on the device, in this order:

1. Repetition penalty - the logit of every token the reply already used is divided by `repeat_penalty` when
   it's positive, and multiplied by it when it's negative.
2. Temperature - logits divided by `temperature`. At 0 or less, the most likely token is taken and the steps
   below are skipped.
3. Top-k - everything below the k-th largest logit is dropped.
4. Min-p - tokens less likely than `min_p` times the most likely one are dropped.
5. Top-p - nucleus sampling over what's left, or Gumbel-max sampling when `top_p` is 1.

**The stop filter.** Text that might be the start of a stop string is held back until it's clearly not one, so
a stop string is never shown, even when it's split across tokens. The reply ends at the first stop string, at
an end-of-turn token from the template, or at `max_tokens`. Whatever was held back and never became a stop
string is shown at the end.

## Caption mode

The photo goes inside a user turn, before the question, the way the model was trained to see it, with a short
system line asking for a concrete, kind description for a friend who can't see the photo. Decoding is greedy
with a stronger repetition penalty (1.3), since short greedy captions are where loops show most, and stops at
120 tokens at most. Empty thinking tags are stripped. It needs a model with a vision tower: Hearth Lite on the
iPhone, and the web model. Hearth Standard has none, so the app doesn't ask it for captions.

## Building

`build.sh` builds both flavors from this source, each against a local Pie checkout, so Pie isn't cloned during
the build:

| Flavor | Pie checkout | Output |
|---|---|---|
| `iphone` | Pie main `6168f025d`, what the iPhone app links | `ios/Hearth/Resources/Pie/hearth.wasm` |
| `web` | `@pie-project/server-web` 0.6.4 (`75eb46bd7`), what the site loads | `docs/app/pie/hearth.wasm` |

```bash
rustup toolchain install nightly-2026-10-18 --target wasm32-wasip3   # the pin in rust-toolchain.toml
PIE_IPHONE=~/src/pie PIE_WEB=~/src/pie-0.6.4 ./build.sh              # or: ./build.sh iphone | web | both
```

`Cargo.toml` pins the `inferlet` crate to Pie at `6168f025d`, and `build.sh` points it at `crates/inferlet` in
each checkout instead. Each flavor builds in its own folder (`target/iphone`, `target/web`), as a size-optimized
release with link-time optimization.
