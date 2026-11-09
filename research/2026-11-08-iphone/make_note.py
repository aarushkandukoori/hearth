#!/usr/bin/env python3
"""Writes and compiles the one-page measurement note from summary.json and the four figure PDFs.

Every measured number in the note comes from summary.json (written by analyze_sweep.py from the raw logs). The
only typed values are configuration facts the logs do not print: Pie's version (main 6168f02), what the two iOS
patches fix, and the forward-pass size (512 tokens, from PieEngine.swift).
Usage: python3 make_note.py DIR [--no-repo]   (DIR holds summary.json and fig*.pdf; writes note.tex, note.pdf)
"""
import json
import subprocess
import sys
from pathlib import Path

D = Path(sys.argv[1])
REPO = "--no-repo" not in sys.argv
S = json.loads((D / "summary.json").read_text())
L, T, R, P, M, H, C = S["length"], S["turns"], S["retention"], S["lowpower"], S["memory"], S["heat"], S["pie"]
E, U, ST = S.get("earlier"), S["reuse_all"], S["stall_notes"]
LR = L["long_reads"]
GIB = 1024
REPO_URL = "github.com/aarushkandukoori/hearth/tree/main/research/2026-11-08-iphone"
K = r"\emph{K}"
words = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
         10: "ten"}


def n0(x):
    return f"{x:,.0f}"


def about(x):
    """A token count rounded to the nearest 10, for sentences that quote a median."""
    return f"about {round(x, -1):,.0f}"


def sec(ms, digits=1):
    return f"{ms / 1000:.{digits}f}"


def q(word):
    return f"``{word}''"


def join(items, last="and"):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + f" {last} " + items[-1]


def w(n):
    return words.get(n, str(n))


# ---- facts used below
minutes = S["duration_s"] / 60
thermal_text = ", ".join(f"{v} {k}" for k, v in S["thermal_at_finish"].items() if v)
os_name = S["os"].replace("Version ", "iOS ").split(" (")[0]
unplugged = S["unplugged_seqs"]
short, long_, reuse = L["shortest"], L["longest"], L["reuse_ttft_ms"]
cool, warm = LR.get("cool"), LR["warm"]
h2k = H["reads_2000_plus"]
by_k = {int(k): v for k, v in R["by_k"].items()}
kept_parts = [f"{v['hits']} of {v['n']} trials with {K} = {k}" if i == 0 else f"{v['hits']} of {v['n']} with {K} = {k}"
              for i, (k, v) in enumerate((k, v) for k, v in by_k.items() if v["hits"] > 0)]
none_ks = [k for k, v in by_k.items() if v["hits"] == 0]
if none_ks:
    kept_parts.append(f"none with {K} = {join((str(k) for k in none_ks), 'or')}")
kept_lo, kept_hi = (round(x * 100) for x in R["kept_fraction_range"])
kept_pct = f"{kept_lo}\\%" if kept_lo == kept_hi else f"{kept_lo} to {kept_hi}\\%"
lp = {int(k): v for k, v in R["lowpower"].items()}
lp_lost = [str(k) for k, v in lp.items() if v["hits"] == 0]
lp_kept = [str(k) for k, v in lp.items() if v["hits"] > 0]
lp_lo, lp_hi = P["per_length_median_tok_s"]
fs = H["fair_550_750_in_slow_stretch"]
reuse_meds = [v["median_ms"] for v in H["reuse_by_state"].values()]
limit_lo = M["limit_mib"][0]
gap = (limit_lo - M["highest_footprint_mib"]) / GIB
slow_seqs = [x["seq"] for x in S["slowest_full_reads"]]
window = (unplugged[0], unplugged[-1] + 10) if unplugged else None
in_window = [s for s in slow_seqs if window and window[0] <= s <= window[1]]

cool_clause = (f"; the only read of {n0(cool['tokens'] // 100 * 100)} or more tokens at {q('nominal')}, a first read "
               f"(hollow gray marker), took {sec(cool['ttft_ms'])}\\,s" if cool else "")
cool_speed = f" and {cool['speedup']:.0f}x faster than the cool first read" if cool else ""
fair_note = (f" Most short {q('fair')} reads ({fs['n']} of {fs['of']}) come from the slow stretch of requests "
             f"{fs['from']} to {fs['to']}, so {q('fair')} and {q('serious')} are not compared."
             if fs["of"] and fs["n"] * 2 > fs["of"] else "")
lp_text = (f" A Low Power Mode run (one trial per {K}) kept it at {K} = {join(lp_kept)} and lost it at "
           f"{K} = {join(lp_lost)}." if lp_kept and lp_lost else "")
earlier_text = ""
if E:
    earlier_text = (f" An earlier build that left pool sizes to Pie's working-set hint ({n0(E['kv_pages'])} KV pages, "
                    f"{E['lanes']} lanes) and lacked the state-slot fix ended with signal 9 after {E['replies_before_kill']} replies"
                    + (f", shortly after that commit failed once ({E['commit_wanted_mib']:.0f}\\,MiB asked of a "
                       f"{E['commit_reserved_mib']:.1f}\\,MiB reservation)." if E.get("commit_wanted_mib") else "."))
slow_text = (f", and {w(len(in_window))} of the {w(len(slow_seqs))} slowest full reads came from requests "
             f"{min(in_window)} to {max(in_window)}" if len(in_window) >= 3 else "")
stall_text = (f" Pie printed {q('engine 0 stalled')} in the {w(ST['n'])} longest reads, which still ran at normal speed "
              f"({ST['tok_s'][0]:.0f} to {ST['tok_s'][1]:.0f} tokens/s)." if ST["n"] else "")
repo_text = (rf" Data, analysis and the sweep are at "
             rf"\href{{https://{REPO_URL}}}{{\nolinkurl{{{REPO_URL}}}}}." if REPO else "")


def figure(name, caption):
    return (rf"\par\vspace{{2pt}}\noindent\begin{{minipage}}{{\linewidth}}\centering"
            rf"\includegraphics[width=\linewidth]{{{name}.pdf}}" "\n"
            rf"\captionof{{figure}}{{{caption}}}" "\n"
            r"\end{minipage}")


fig1 = figure("fig1_ttft_vs_length", rf"""TTFT against prompt length (a) and the speedup from reuse (b). A full re-read took
a median of {sec(short["control_ms"])}\,s at {about(short["tokens"])} tokens and {sec(long_["control_ms"])}\,s at
{about(long_["tokens"])}, all three at {join(q(s) for s in warm["states"])}{cool_clause}. With reuse the inferlet computed
only the last {L["reuse_new_tokens"]["min"]} to {L["reuse_new_tokens"]["max"]} tokens and TTFT stayed at
{sec(reuse["min"], 2)} to {sec(reuse["max"], 2)}\,s (median {sec(reuse["median"], 2)}\,s): {long_["speedup"]:.0f}x faster
than the re-read at {about(long_["tokens"])} tokens{cool_speed}. Dots are trials; lines join medians.""")

fig2 = figure("fig2_multiturn", rf"""One chat carried on for {T["steps"] - 1} more turns (turn 0, gray, is its first read;
the prompt grows from {n0(T["prompt_tokens_first"])} to {n0(T["prompt_tokens_last"])} tokens). (a) Every reuse turn
started in {sec(T["chain_ttft_ms_reuse_turns"]["min"], 2)} to {sec(T["chain_ttft_ms_reuse_turns"]["max"], 2)}\,s while a
full re-read grew from {sec(T["control_ttft_ms_first"])} to {sec(T["control_ttft_ms_last"])}\,s. (b) Each turn computed
only its last {T["computed_tokens_reuse_turns"]["min"]} to {T["computed_tokens_reuse_turns"]["max"]} tokens
({T["reuse_hits"]} of {T["reuse_turns"]} reused the previous checkpoint), {n0(T["computed_tokens_total"])} of the chat's
{n0(T["prompt_tokens_total"])} prompt tokens in all.""")

fig3 = figure("fig3_retention", rf"""Coming back to a chat after reading {K} other new chats (three trials per {K}).
(a) The checkpoint was still there in {join(kept_parts)}. A surviving checkpoint covered {kept_pct} of the returning
prompt. (b) Returns without it took a median of {sec(R["miss_return_ttft_ms_median"])}\,s, about the same as the first
reads of those {w(R["misses"])} chats ({sec(R["miss_first_ttft_ms_median"])}\,s).{lp_text}""")

fig4 = figure("fig4_power_heat_memory", rf"""(a) A separate, earlier run with Low Power Mode on, the phone at
{join(q(s) for s in P["thermal"])}: full re-reads ran at about {P["all_reads_tok_s_median"]:.0f} tokens/s against about {P["nominal_off_2000_plus_tok_s"]:.0f} at {q("nominal")} with it off,
and reuse medians stayed at {sec(P["reuse_median_ms_range"][0], 2)} to {sec(P["reuse_median_ms_range"][1], 2)}\,s. The
Low Power off lines are the main run, mostly at {q("fair")}. (b) Full-read speed by length and thermal state. Reads of
2,000 or more tokens ran at a median of {h2k["nominal"]["median_tok_s"]:.0f} tokens/s at {q("nominal")}
(n~=~{h2k["nominal"]["n"]}) and {h2k["fair"]["median_tok_s"]:.0f} at {q("fair")} (n~=~{h2k["fair"]["n"]}).{fair_note}
Reuse barely changed with heat (medians {sec(min(reuse_meds), 2)} to {sec(max(reuse_meds), 2)}\,s). (c) The app's memory
footprint (\texttt{{phys\_footprint}}) rose from {M["start_footprint_mib"] / GIB:.2f}\,GiB before the first request to
{M["highest_footprint_mib"] / GIB:.2f}\,GiB, flat from minute {M["within_1pct_of_highest_from_min"]:.1f} on, {gap:.2f}\,GiB
under the iOS limit for the app ({limit_lo / GIB:.2f}\,GiB).""")

summary_text = (rf"""With Hearth's inferlet leaving a checkpoint after every reply, Pie started the next reply in
{sec(U["ttft_ms_min"], 2)} to {sec(U["ttft_ms_max"], 2)}\,s (median {sec(U["ttft_ms_median"], 2)}\,s) for chats of
{n0(U["prompt_min"])} to {n0(U["prompt_max"])} tokens, while reading a {n0(round(warm["tokens"][0], -2))} to
{n0(round(warm["tokens"][1], -2))}-token chat from scratch took """
                + (f"{sec(cool['ttft_ms'])}\\,s on a cool phone and " if cool else "")
                + rf"""{sec(warm["ttft_ms"][0])} to {sec(warm["ttft_ms"][1])}\,s on a warm one. The checkpoint rarely
survived reading another chat in between.""")

tex = rf"""\documentclass[10pt]{{article}}
\usepackage[letterpaper,top=0.34in,bottom=0.32in,left=0.55in,right=0.55in]{{geometry}}
\usepackage{{graphicx}}
\usepackage[hidelinks]{{hyperref}}
\usepackage{{caption}}
\usepackage{{fontspec}}
\setmainfont{{texgyreheros-regular.otf}}[BoldFont=texgyreheros-bold.otf,ItalicFont=texgyreheros-italic.otf,BoldItalicFont=texgyreheros-bolditalic.otf,Ligatures=NoCommon]
\setmonofont{{Menlo}}[Scale=0.85]
\urlstyle{{same}}
\hyphenation{{checkpoint checkpoints}}
\captionsetup{{font={{scriptsize}},labelfont=bf,labelsep=period,skip=1pt}}
\setlength{{\parindent}}{{0pt}}
\setlength{{\parskip}}{{2pt}}
\pagestyle{{empty}}
\begin{{document}}
\fontsize{{7.8pt}}{{9.1pt}}\selectfont

\noindent{{\normalsize\bfseries Hearth on Pie - measurements on an iPhone 16 Pro}}\hfill{{\scriptsize Aarush Kandukoori, Carnegie Mellon University \quad November 8, 2026}}

\textbf{{Summary.}} {summary_text}

\textbf{{Setup.}} Every reply comes from Hearth's own Pie inferlet (Rust compiled to \texttt{{wasm32-wasip3}}) on Pie 0.6
(main \texttt{{6168f02}}), in-process on the Metal engine of an iPhone 16 Pro (A18 Pro, {os_name}) running {S["model"]}
(4-bit, Gated DeltaNet plus attention). Two small iOS patches fix wasmtime's 2\,GiB growth reservation
and a state-slot commit that rounded past its reservation. Hearth gives Pie a {C["kv_budget_mib"]}\,MiB budget for its
KV pool and state slots together ({n0(C["kv_pages"])} KV pages of {C["page_tokens"]} tokens and {C["state_slots"]} state
slots), {C["lanes"]} lanes, forward passes of at most 512 tokens and a {n0(S["context_length"])}-token context. The
inferlet reads a chat in two passes and asks Pie for a checkpoint of the recurrent state at the last
{C["page_tokens"]}-token page boundary before the prompt's final token. Pie keeps it in a state slot, so the next request
computes only what follows it. TTFT is timed inside the inferlet, from its start to the first sampled token (the app's
clock adds a median of {S["wall_minus_inferlet_ttft_ms_median"]:.1f}\,ms). A
\emph{{full re-read}} is the same prompt with a unique tag at the start. Figures 1, 3 and 4a have
three trials per point, shuffled with a fixed seed. The main run's {S["requests"]} requests ran back to back in
{minutes:.0f} minutes with Low Power Mode off, and each records the thermal state iOS reported as it finished
({thermal_text}).

{fig1}
{fig2}
{fig3}
{fig4}

\par\vspace{{2pt}}\textbf{{What this suggests.}}
\textbf{{Keeping checkpoints across chats is the main gap I found.}} In this configuration ({C["state_slots"]} state slots,
{C["kv_budget_mib"]}\,MiB), reading one other chat usually discarded a chat's checkpoint and reading two or more always
did; this run did not log which path dropped them, which I want to trace next. Pie's Metal engine already has a disk
tier for parked KV and state, so keeping checkpoints there could carry reuse across chats.
\textbf{{Memory headroom on iOS is small.}} With
the {C["kv_budget_mib"]}\,MiB budget the footprint still grew {M["growth_from_start_mib"] / GIB:.2f}\,GiB, more than the
budget itself, and came within {gap:.2f}\,GiB of the limit; I have not broken that growth down yet.{earlier_text}
\textbf{{Pie's Neural Engine path did not run.}} Its programs failed to compile here
(\mbox{{``Operation not permitted''}}), so the GPU ran every layer; decode ran at a median of
{S["decode_tok_s"]["median"]:.0f} tokens/s ({S["decode_tok_s"]["n"]} replies of {S["decode_tok_s"]["min_generated_tokens"]}
to {S["decode_tok_s"]["max_generated_tokens"]} tokens).

\textbf{{Limitations.}} One phone and one model; the Low Power Mode run and the earlier build are separate runs. Each
re-read ran right after its reuse request, on a slightly warmer phone, and the first trial's shuffle came out nearly in
ascending order. The phone reported unplugged for requests {unplugged[0]} to {unplugged[-1]}{slow_text}. Pie ran its
checked-in GPU profile (\texttt{{{C["gpu_profile_untuned"]}}}), never measured on the A18 Pro.{repo_text}

\end{{document}}
"""
(D / "note.tex").write_text(tex)
subprocess.run(["tectonic", "--keep-logs", "note.tex"], cwd=D, check=True, capture_output=True)
print("wrote", D / "note.pdf")
