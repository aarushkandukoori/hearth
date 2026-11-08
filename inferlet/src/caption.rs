//! Caption mode: one or two plain sentences about a photo the person sent,
//! from the model's own vision tower. Only models with a vision part can do
//! it (on the web: Qwen3.5 0.8B with vision); the app asks for it only there.

use super::{Input, Output};
use inferlet::chat;
use inferlet::eta::prelude::*;
use inferlet::media;

/// Stronger than replies' 1.1: captions are short and greedy, where loops show most.
const CAPTION_REPEAT_PENALTY: f32 = 1.3;

const SYSTEM: &str = "You describe photos for a friend who cannot see them. Be concrete and kind.";
const QUESTION: &str = "Describe this photo in one or two short sentences: who or what is in it, where, \
and anything notable. No preamble.";

pub async fn caption(input: Input) -> Result<Output> {
    let started = super::now_ms();
    let b64 = input.image_b64.as_deref().ok_or("caption needs image_b64")?;
    let bytes = base64_decode(b64)?;
    let image = media::Image::from_bytes(&bytes)?;

    // The picture goes inside the user turn, before the question, as the model was trained to see it:
    // the template's own user header and closing come from rendering two one-letter turns.
    let (user_head, user_tail) = user_frame();
    let mut prompt = chat::system(SYSTEM);
    prompt.extend(user_head);
    prompt.extend(image.tokens());
    prompt.extend(model::encode(input.question.as_deref().unwrap_or(QUESTION)));
    prompt.extend(user_tail);
    prompt.extend(chat::cue_without_thinking());
    let n = prompt.len() as u32;
    let stop = chat::stop_tokens();
    let max_tokens = input.max_tokens.clamp(1, 120);

    let ws = WorkingSet::new();
    let pipe = Pipeline::new();
    let prompt_i32: Vec<i32> = prompt.iter().map(|&t| t as i32).collect();
    let toks = Channel::from(&prompt_i32[..]);
    let indptr = Channel::from([0u32, n]);
    let first = Channel::new([1], dtype::i32);
    let fwd = ForwardPass::new();
    fwd.embed(&toks, &indptr)?;
    fwd.media(0, &[media::Span::Image(&image)])?;
    fwd.state(&[&ws], StateGeometry::folding())?;
    let sampled = first.clone();
    fwd.epilogue(move || {
        sampled.put(reduce_argmax(intrinsics::output(0, "logits")));
    });
    fwd.submit(&pipe).context("caption prefill")?;
    let g0 = first.take_host::<i32>().await?;
    let first_at = super::now_ms();

    let decoder = chat::Decoder::new();
    let mut text = String::new();
    let mut generated = 0u32;
    let mut done = stop.contains(&(g0 as u32));
    if !done {
        generated += 1;
        match decoder.feed(&[g0 as u32])? {
            chat::Event::Delta(s) => text.push_str(&s),
            chat::Event::Done(s) => {
                text = s;
                done = true;
            }
            _ => {}
        }
    }
    if !done && max_tokens > 1 {
        // Greedy, but every word already used is penalised, so a small model's caption doesn't loop.
        let vocab = model::output_vocab_size();
        let greedy = super::Sampling { temperature: 0.0, top_p: 1.0, top_k: 0, min_p: 0.0, repeat_penalty: CAPTION_REPEAT_PENALTY };
        let mut history = vec![-1i32; max_tokens];
        history[0] = g0;
        let tok_in = Channel::from([g0]);
        let hist = Channel::from(history);
        let hlen = Channel::from([1u32]);
        let rng = Channel::from([0x5eed_u32, 0]);
        let out = Channel::new([1], dtype::i32).capacity(channel_capacity() as u32);
        let lane = Channel::from([0u32, 1u32]);
        let step = ForwardPass::new();
        step.embed(&tok_in, &lane)?;
        step.state(&[&ws], StateGeometry::folding())?;
        let out_put = out.clone();
        step.epilogue(move || {
            let r = rng.take();
            let h = hist.take();
            let len = hlen.take();
            let counts = scatter_add(broadcast(0.0f32, [vocab]), &h, 1.0f32);
            let token = super::sample(greedy, vocab, &counts, &r);
            let h_next = scatter_set(&h, &len, &token);
            tok_in.put(&token);
            out_put.put(&token);
            hist.put(&h_next);
            hlen.put(&len + 1u32);
            rng.put(&r);
        });
        run_ahead(&pipe, &step, max_tokens - 1, async || {
            let t = out.take_host::<Vec<i32>>().await?;
            let token = *t.first().unwrap_or(&0) as u32;
            if stop.contains(&token) {
                return Ok(ControlFlow::Break(()));
            }
            generated += 1;
            match decoder.feed(&[token])? {
                chat::Event::Delta(s) => text.push_str(&s),
                chat::Event::Done(s) => {
                    text = s;
                    return Ok(ControlFlow::Break(()));
                }
                _ => {}
            }
            Ok(ControlFlow::Continue(()))
        })
        .await?;
    }
    pipe.close();

    let finished = super::now_ms();
    // The model sometimes writes its (empty) thinking tags out as text: they are never part of a caption.
    let text = text.replace("<think>", "").replace("</think>", "");
    Ok(Output {
        text: text.trim().to_string(),
        prompt_tokens: n,
        reused_tokens: ws.cached_tokens().min(n),
        prefilled_tokens: n.saturating_sub(ws.cached_tokens()),
        generated_tokens: generated,
        stopped_by: "eos".into(),
        ttft_ms: first_at - started,
        prefill_ms: first_at - started,
        decode_ms: finished - first_at,
        decode_tokens_per_second: 0.0,
        page_size: kv_page_size(),
        prompt_text: None,
    })
}

/// What the template writes before and after a user message: the common head and tail of two one-letter
/// messages.
fn user_frame() -> (Vec<u32>, Vec<u32>) {
    let a = chat::user("a");
    let b = chat::user("b");
    let head = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let tail = a
        .iter()
        .rev()
        .zip(b.iter().rev())
        .take_while(|(x, y)| x == y)
        .count()
        .min(a.len() - head);
    (a[..head].to_vec(), a[a.len() - tail..].to_vec())
}

/// Standard or URL-safe base64; padding and whitespace are skipped.
fn base64_decode(text: &str) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return Err(format!("image_b64 has a byte that is not base64: {c:#04x}")),
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Ok(out)
}
