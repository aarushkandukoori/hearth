//! Hearth's inferlet: one character reply, or one photo caption, run by Pie.
//!
//! The same source runs on the iPhone (Pie's Metal engine, in-process through
//! the Swift package) and in the browser (Pie's WebGPU engine in a tab).
//!
//! **Reply.** The app sends the whole conversation every turn, as plain chat
//! turns. This program renders them with the model's own chat template,
//! writes them into a fresh working set and samples the reply. It keeps no
//! state of its own between launches. Qwen3.5 is a hybrid model (recurrent
//! layers beside attention), and Pie keeps such a model's pages after a launch
//! only through a recurrent-state checkpoint, so the prefill runs as two
//! passes: the first ends at the last whole page before the reply and leaves
//! a checkpoint there, the second reads the rest and samples. The next turn's
//! prompt starts with the same tokens, so when Pie still holds that checkpoint
//! it maps them back in and the turn computes only the previous reply and the
//! new message. (Pie drops a kept checkpoint when a live write needs its state
//! slot, so this reuse is not guaranteed; `reused_tokens` reports it.)
//!
//! **Caption.** A photo the person sends is described in one or two plain
//! sentences by the same model's vision tower, where the model has one.

use inferlet::chat;
use inferlet::eta::prelude::*;
use inferlet::session;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct Turn {
    role: String,
    content: String,
}

#[derive(Deserialize)]
struct Input {
    /// "reply" (default) or "caption".
    #[serde(default)]
    mode: Option<String>,
    /// The conversation, oldest first: system, user and assistant turns.
    #[serde(default)]
    turns: Vec<Turn>,
    /// Text forced right after the assistant header and not returned, e.g.
    /// "Theo:" in a group scene.
    #[serde(default)]
    prefix: Option<String>,
    /// The fixed start of the reply that the person does see (the caring
    /// opener for a crisis message). Forced after `prefix` and not returned:
    /// the app shows `opener + " " + text`.
    #[serde(default)]
    opener: Option<String>,
    #[serde(default = "default_max_tokens")]
    max_tokens: usize,
    /// Stop strings: the reply ends before the first one, which is not shown.
    #[serde(default)]
    stop: Vec<String>,
    #[serde(default = "default_temperature")]
    temperature: f32,
    #[serde(default = "default_top_p")]
    top_p: f32,
    /// Keep only the k most likely tokens (0 = off).
    #[serde(default = "default_top_k")]
    top_k: u32,
    /// Drop tokens less likely than min_p times the most likely one (0 = off).
    #[serde(default = "default_min_p")]
    min_p: f32,
    /// Divides the logit of every token the reply already used (>1 = less
    /// repetition). 1 turns it off.
    #[serde(default = "default_repeat_penalty")]
    repeat_penalty: f32,
    #[serde(default)]
    seed: Option<u32>,
    /// Stream each piece of the reply to the client as a message.
    #[serde(default = "default_true")]
    stream: bool,
    /// Caption mode: the photo, as base64 PNG or JPEG.
    #[serde(default)]
    image_b64: Option<String>,
    /// Caption mode: what to ask about the photo.
    #[serde(default)]
    question: Option<String>,
    /// Return the rendered prompt as text too (for checking the template).
    #[serde(default)]
    debug_prompt: bool,
}

fn default_max_tokens() -> usize {
    220
}
fn default_temperature() -> f32 {
    0.85
}
fn default_top_p() -> f32 {
    0.95
}
fn default_top_k() -> u32 {
    40
}
fn default_min_p() -> f32 {
    0.05
}
fn default_repeat_penalty() -> f32 {
    1.1
}
fn default_true() -> bool {
    true
}

#[derive(Serialize, Default)]
struct Output {
    text: String,
    /// Tokens in the prompt (including the forced prefix and opener).
    prompt_tokens: u32,
    /// Prompt tokens Pie mapped in from state it already held.
    reused_tokens: u32,
    /// Prompt tokens this turn computed.
    prefilled_tokens: u32,
    generated_tokens: u32,
    /// "eos", "stop" (a stop string) or "max_tokens".
    stopped_by: String,
    /// From the start of the program to the first sampled token.
    ttft_ms: f64,
    prefill_ms: f64,
    decode_ms: f64,
    decode_tokens_per_second: f64,
    page_size: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_text: Option<String>,
}

fn now_ms() -> f64 {
    inferlet::monotonic_now_ns() as f64 / 1e6
}

/// What the template writes after an assistant message (for ChatML,
/// `<|im_end|>` and a newline): the common tail of two one-letter messages.
fn assistant_closing() -> Vec<u32> {
    let a = chat::assistant("a");
    let b = chat::assistant("b");
    let head = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let tail = a
        .iter()
        .rev()
        .zip(b.iter().rev())
        .take_while(|(x, y)| x == y)
        .count()
        .min(a.len() - head);
    a[a.len() - tail..].to_vec()
}

/// The prompt as tokens.
///
/// A past reply is written the way this program generates one: the
/// no-thinking cue, then the text, then the template's own closing. So next
/// turn's prompt repeats this turn's prompt token for token, which is what
/// lets Pie resume from the checkpoint this turn leaves.
fn render(turns: &[Turn]) -> Vec<u32> {
    let closing = assistant_closing();
    let mut tokens = Vec::new();
    let mut rest = turns;
    match turns.first() {
        Some(first) if first.role == "system" => {
            tokens.extend(chat::open(Some(&first.content), &[], None));
            rest = &turns[1..];
        }
        _ => tokens.extend(chat::prefix()),
    }
    for turn in rest {
        match turn.role.as_str() {
            "system" => tokens.extend(chat::system(&turn.content)),
            "assistant" => {
                tokens.extend(chat::cue_without_thinking());
                tokens.extend(model::encode(&turn.content));
                tokens.extend_from_slice(&closing);
            }
            _ => tokens.extend(chat::user(&turn.content)),
        }
    }
    tokens
}

/// Holds back text that might be the start of a stop string, so a stop
/// string is never shown, even split across tokens.
struct StopFilter {
    stops: Vec<String>,
    pending: String,
    stopped: bool,
}

impl StopFilter {
    fn new(stops: &[String]) -> Self {
        StopFilter {
            stops: stops.iter().filter(|s| !s.is_empty()).cloned().collect(),
            pending: String::new(),
            stopped: false,
        }
    }

    /// Adds `piece` and returns the text that is now safe to show.
    fn feed(&mut self, piece: &str) -> String {
        if self.stopped {
            return String::new();
        }
        self.pending.push_str(piece);
        if let Some(at) = self
            .stops
            .iter()
            .filter_map(|s| self.pending.find(s.as_str()))
            .min()
        {
            self.stopped = true;
            let shown = self.pending[..at].to_string();
            self.pending.clear();
            return shown;
        }
        // Keep the longest tail that is a prefix of some stop string.
        let mut keep = 0;
        for stop in &self.stops {
            let max = stop.len().min(self.pending.len());
            for n in (1..=max).rev() {
                if n <= keep {
                    break;
                }
                let start = self.pending.len() - n;
                if self.pending.is_char_boundary(start) && stop.starts_with(&self.pending[start..]) {
                    keep = n;
                    break;
                }
            }
        }
        let cut = self.pending.len() - keep;
        let shown = self.pending[..cut].to_string();
        self.pending.drain(..cut);
        shown
    }

    /// Whatever was held back and never became a stop string.
    fn flush(&mut self) -> String {
        if self.stopped {
            return String::new();
        }
        std::mem::take(&mut self.pending)
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Sampling {
    pub(crate) temperature: f32,
    pub(crate) top_p: f32,
    pub(crate) top_k: u32,
    pub(crate) min_p: f32,
    pub(crate) repeat_penalty: f32,
}

/// One sampled token `[1]` i32 from the read-out row: the repetition penalty (dividing the logits of tokens
/// the reply already used, `counts > 0`), then temperature, then the top-k and min-p cutoffs, then top-p
/// (nucleus) sampling, the same chain the app used before. All of it runs on the device.
pub(crate) fn sample(s: Sampling, vocab: u32, counts: &Tensor, r: &Tensor) -> Tensor {
    let logits = intrinsics::output(0, "logits"); // [1, vocab]
    let logits = if s.repeat_penalty != 1.0 {
        let zero = broadcast(0.0f32, [vocab]);
        let seen = gt(counts, &zero);
        let positive = gt(&logits, &zero);
        let penalty = broadcast(s.repeat_penalty, [vocab]);
        let penalized = select(&positive, &logits / &penalty, &logits * &penalty);
        select(&seen, &penalized, &logits)
    } else {
        logits
    };
    if s.temperature <= 0.0 {
        return reduce_argmax(&logits);
    }
    let mut scaled = &logits / s.temperature.max(1e-4);
    let neg_inf = broadcast(f32::NEG_INFINITY, [vocab]);
    if s.top_k > 0 && s.top_k < vocab {
        // The k-th largest logit is the smallest of the top k.
        let (best, _) = top_k(&scaled, s.top_k);
        let kth = reduce_min(&best);
        let keep = ge(&scaled, broadcast(&kth, [vocab]));
        scaled = select(&keep, &scaled, &neg_inf);
    }
    if s.min_p > 0.0 {
        // As in Pie's top-a example: the most likely token's probability is 1 / sum(exp(l - max)).
        let max_l = reduce_max(&scaled);
        let exps = exp(&scaled - broadcast(&max_l, [vocab]));
        let sum_e = reduce_sum(&exps);
        let probs = &exps / broadcast(&sum_e, [vocab]);
        let threshold = s.min_p * recip(&sum_e);
        let keep = ge(&probs, broadcast(&threshold, [vocab]));
        scaled = select(&keep, &scaled, &neg_inf);
    }
    if s.top_p >= 1.0 {
        gumbel_max(scaled, r)
    } else {
        nucleus_sample(&scaled, s.top_p, r)
    }
}

async fn reply(input: Input) -> Result<Output> {
    let started = now_ms();
    let mut out = Output {
        stopped_by: "max_tokens".into(),
        page_size: kv_page_size(),
        ..Output::default()
    };
    if !(input.top_p > 0.0 && input.top_p <= 1.0) {
        return Err("top_p must be greater than 0 and at most 1".into());
    }
    if !input.temperature.is_finite() || !input.repeat_penalty.is_finite() || input.repeat_penalty <= 0.0 {
        return Err("temperature and repeat_penalty must be finite (repeat_penalty > 0)".into());
    }
    if !(0.0..1.0).contains(&input.min_p) {
        return Err("min_p must be at least 0 and below 1".into());
    }
    if input.max_tokens == 0 {
        out.stopped_by = "max_tokens".into();
        return Ok(out);
    }

    let mut prompt = render(&input.turns);
    prompt.extend(chat::cue_without_thinking());
    // Where this turn's prompt stops matching the next turn's: next turn writes this reply after the same cue.
    let base_end = prompt.len() as u32;
    let mut forced = input.prefix.clone().unwrap_or_default();
    if let Some(opener) = input.opener.as_deref().filter(|o| !o.is_empty()) {
        if !forced.is_empty() {
            forced.push(' ');
        }
        forced.push_str(opener);
    }
    if !forced.is_empty() {
        prompt.extend(model::encode(&forced));
    }
    if prompt.is_empty() {
        prompt.push(0);
    }
    let n = prompt.len() as u32;
    out.prompt_tokens = n;
    if input.debug_prompt {
        out.prompt_text = Some(model::decode(&prompt).unwrap_or_default());
    }

    let stop_tokens = chat::stop_tokens();
    let vocab = model::output_vocab_size();
    let sampling = Sampling {
        temperature: input.temperature,
        top_p: input.top_p,
        top_k: input.top_k,
        min_p: input.min_p,
        repeat_penalty: input.repeat_penalty,
    };
    let seed = input.seed.unwrap_or_else(|| (inferlet::monotonic_now_ns() & 0xffff_ffff) as u32);
    let max_tokens = input.max_tokens;
    let prompt_i32: Vec<i32> = prompt.iter().map(|&t| t as i32).collect();

    let ws = WorkingSet::new();
    let pipe = Pipeline::new();

    // 1. Pass 1: the prompt up to the last whole page before this reply, with one checkpoint at its end.
    //    Pie keeps a hybrid model's pages only through recurrent-state checkpoints, and keeps one only at the
    //    end of a pass that has finished (a checkpoint inside a long prefill, which Pie cuts into pieces, is
    //    dropped while later pieces still write the state). Awaiting this pass before pass 2 settles it, so
    //    the checkpoint and its pages stay. Next turn's prompt starts with this same run of tokens, so its
    //    pass 1 resumes here and computes only what is new.
    let page = kv_page_size().max(1);
    let cut = (base_end.saturating_sub(1) / page) * page;
    if cut > 0 {
        let toks = Channel::from(prompt_i32[..cut as usize].to_vec());
        let indptr = Channel::from([0u32, cut]);
        let done = Channel::new([1], dtype::i32);
        let fwd = ForwardPass::new();
        fwd.embed(&toks, &indptr)?;
        fwd.state(&[&ws], StateGeometry::folding())?;
        fwd.checkpoints(&[cut])?;
        let finished = done.clone();
        fwd.epilogue(move || {
            finished.put(reduce_argmax(intrinsics::output(0, "logits")));
        });
        fwd.submit(&pipe).context("prefill")?;
        done.take_host::<i32>().await.context("prefill")?;
    }
    out.reused_tokens = ws.cached_tokens().min(cut);

    // 2. Pass 2: the rest of the prompt (at least the last cue token, plus any forced text); samples the
    //    first token of the reply.
    let first = {
        let rest = n - cut;
        let toks = Channel::from(prompt_i32[cut as usize..].to_vec());
        let indptr = Channel::from([0u32, rest]);
        let rng = Channel::from([seed, 0]);
        let first = Channel::new([1], dtype::i32);
        let fwd = ForwardPass::new();
        fwd.embed(&toks, &indptr)?;
        fwd.state(&[&ws], StateGeometry::folding())?;
        let sampled = first.clone();
        fwd.epilogue(move || {
            let r = rng.take();
            let counts = broadcast(0.0f32, [vocab]);
            sampled.put(&sample(sampling, vocab, &counts, &r));
        });
        fwd.submit(&pipe).context("prefill")?;
        first.take_host::<i32>().await.context("first token")?
    };
    let first_at = now_ms();
    out.ttft_ms = first_at - started;
    out.prefill_ms = out.ttft_ms;
    out.prefilled_tokens = n - out.reused_tokens;

    let mut collector = Collector {
        decoder: chat::Decoder::new(),
        filter: StopFilter::new(&input.stop),
        stop_tokens,
        text: String::new(),
        stream: input.stream,
        max_tokens,
    };
    let done = collector.take(first as u32, &mut out)?;

    // 2. Decode: one token a pass, sampled on the device; the host reads each
    //    one to stream it and to stop.
    if !done {
        let mut history = vec![-1i32; max_tokens];
        history[0] = first;
        let tok_in = Channel::from([first]);
        let rng = Channel::from([seed ^ 0x9e37_79b9, 1]);
        let hist = Channel::from(history);
        let hlen = Channel::from([1u32]);
        let sampled = Channel::new([1], dtype::i32).capacity(channel_capacity() as u32);
        let lane = Channel::from([0u32, 1u32]);
        let fwd = ForwardPass::new();
        fwd.embed(&tok_in, &lane)?;
        fwd.state(&[&ws], StateGeometry::folding())?;
        let sampled_out = sampled.clone();
        fwd.epilogue(move || {
            let r = rng.take();
            let h = hist.take();
            let len = hlen.take();
            let counts = scatter_add(broadcast(0.0f32, [vocab]), &h, 1.0f32);
            let token = sample(sampling, vocab, &counts, &r);
            let h_next = scatter_set(&h, &len, &token);
            let r_next = &r + iota(2);
            tok_in.put(&token);
            sampled_out.put(&token);
            hist.put(&h_next);
            hlen.put(&len + 1u32);
            rng.put(&r_next);
        });
        let budget = max_tokens.saturating_sub(1);
        run_ahead(&pipe, &fwd, budget, async || {
            let t = sampled.take_host::<Vec<i32>>().await?;
            let token = *t.first().unwrap_or(&0) as u32;
            if collector.take(token, &mut out)? {
                return Ok(ControlFlow::Break(()));
            }
            Ok(ControlFlow::Continue(()))
        })
        .await?;
    }
    pipe.close();

    collector.finish();
    let finished = now_ms();
    out.decode_ms = finished - first_at;
    if out.generated_tokens > 1 && out.decode_ms > 0.0 {
        out.decode_tokens_per_second = f64::from(out.generated_tokens - 1) / (out.decode_ms / 1000.0);
    }
    out.text = collector.text;
    Ok(out)
}

/// Turns sampled tokens into shown text: decodes, holds back stop strings,
/// streams, and says when the reply is over.
struct Collector {
    decoder: chat::Decoder,
    filter: StopFilter,
    stop_tokens: Vec<u32>,
    text: String,
    stream: bool,
    max_tokens: usize,
}

impl Collector {
    /// Takes one sampled token; true when the reply is over.
    fn take(&mut self, token: u32, out: &mut Output) -> Result<bool> {
        if self.stop_tokens.contains(&token) {
            out.stopped_by = "eos".into();
            return Ok(true);
        }
        out.generated_tokens += 1;
        let piece = match self.decoder.feed(&[token])? {
            chat::Event::Delta(s) => s,
            chat::Event::Done(_) => {
                out.stopped_by = "eos".into();
                return Ok(true);
            }
            _ => String::new(),
        };
        let shown = self.filter.feed(&piece);
        self.show(&shown);
        if self.filter.stopped {
            out.stopped_by = "stop".into();
            return Ok(true);
        }
        Ok(out.generated_tokens as usize >= self.max_tokens)
    }

    fn show(&mut self, piece: &str) {
        if piece.is_empty() {
            return;
        }
        self.text.push_str(piece);
        if self.stream {
            session::send(piece);
        }
    }

    /// Shows what was held back and never became a stop string.
    fn finish(&mut self) {
        let tail = self.filter.flush();
        self.show(&tail);
    }
}

#[inferlet::main]
async fn main(input: Input) -> Result<Output> {
    match input.mode.as_deref() {
        None | Some("reply") => reply(input).await,
        Some("caption") => caption::caption(input).await,
        Some(other) => Err(format!("unknown mode `{other}`")),
    }
}

mod caption;
