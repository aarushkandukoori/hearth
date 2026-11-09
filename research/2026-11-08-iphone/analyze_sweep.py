#!/usr/bin/env python3
"""Hearth on Pie: analysis and figures for the iPhone measurement note.

Reads the HEARTHSWEEP lines that hearth/ios/Hearth/Dev/PieSweep.swift writes (the device console log or
Documents/sweep.jsonl) and writes four figures (PDF + PNG), a CSV of every request, and summary.json with every
number the note quotes. The Pie configuration comes from the main run's console log (its "[pie] booted" line)
and the earlier, killed run from its own log, so make_note.py types no measured number by hand.

Usage:
  python3 analyze_sweep.py --main sweep-main.jsonl --lowpower sweep-lowpower.jsonl \
      --console console-main.log --earlier console-earlier.log --out DIR
"""
import argparse
import csv
import json
import re
import statistics as st
from collections import defaultdict
from pathlib import Path

import matplotlib as mpl

mpl.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

# ---------------------------------------------------------------- style (dataviz reference palette, light)
BLUE, ORANGE = "#2a78d6", "#eb6834"  # Pie reuse, full re-read: validated categorical pair on white
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, LIGHT = "#e1e0d9", "#c3c2b7", "#d9d8d2"
# Thermal states are ordered, so they get an ordinal ramp of one hue (validated with --ordinal on white). Violet is
# used nowhere else, so orange keeps meaning "full read" and blue "reuse" in every figure.
HEAT = {"nominal": "#a197ec", "fair": "#6a5ad8", "serious": "#3b2d94"}

for name in ("Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf"):
    path = Path("/System/Library/Fonts/Supplemental") / name
    if path.exists():
        font_manager.fontManager.addfont(str(path))

mpl.rcParams.update({
    "font.family": "Arial", "font.size": 7.5,
    "axes.titlesize": 8, "axes.labelsize": 7.5, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.edgecolor": AXIS, "axes.linewidth": 0.8, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "axes.grid.axis": "y", "axes.axisbelow": True,
    "grid.color": GRID, "grid.linewidth": 0.6, "grid.linestyle": "-",
    "xtick.color": AXIS, "ytick.color": AXIS, "xtick.labelcolor": INK2, "ytick.labelcolor": INK2,
    "xtick.major.width": 0.8, "xtick.major.size": 3, "ytick.major.size": 0, "ytick.major.pad": 3,
    "xtick.labelsize": 7, "ytick.labelsize": 7,
    "legend.frameon": False, "legend.fontsize": 6.8, "legend.handlelength": 2.6, "legend.borderaxespad": 0.2,
    "lines.solid_capstyle": "round", "lines.solid_joinstyle": "round",
    "pdf.fonttype": 42, "ps.fonttype": 42, "savefig.dpi": 300, "figure.dpi": 150,
    "mathtext.fontset": "custom", "mathtext.rm": "Arial", "mathtext.bf": "Arial:bold",
})

FULL_W = 7.4  # inches: the note's text width (8.5 in page, 0.55 in margins); figures print at 100%


# ---------------------------------------------------------------- loading and checks
def load(path):
    """Every JSON row of one run (deduplicated) and how many lines could not be read."""
    rows, seen, bad = [], set(), 0
    for line in Path(path).read_text(errors="replace").splitlines():
        i = line.find("{")
        if i < 0 or ("HEARTHSWEEP" not in line[:i] and not str(path).endswith(".jsonl")):
            continue
        try:
            r = json.loads(line[i:])
        except json.JSONDecodeError:
            bad += 1
            continue
        key = json.dumps(r, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        rows.append(r)
    runs = {r.get("run") for r in rows if r.get("run")}
    assert len(runs) == 1, f"{path} holds rows of {len(runs)} runs: {runs}"
    return rows, bad


def split(rows, low_power):
    """Requests with the wanted Low Power Mode state, errors, and the other events."""
    reqs = [r for r in rows if "seq" in r and "event" not in r and r.get("lowPower") is low_power]
    errors = [r for r in rows if r.get("event") == "error"]
    events = [r for r in rows if "event" in r and r.get("event") != "error"]
    return reqs, errors, events


def check_main(rows, reqs, errors):
    """The main run must be complete: numbered requests 1..N, three trials everywhere, 13 turn steps."""
    seqs = sorted([r["seq"] for r in reqs] + [e["seq"] for e in errors if "seq" in e])
    assert seqs == list(range(1, len(seqs) + 1)), "request numbers are not 1..N"
    assert not errors, f"errors in the main run: {errors}"
    assert all(r.get("lowPower") is False for r in rows if "lowPower" in r), "Low Power Mode was on in the main run"
    start = next(r for r in rows if r.get("event") == "start")
    for target in start["lengths"]:
        for kind in ("cold", "reuse", "control"):
            n = len([r for r in reqs if r.get("exp") == "length" and r["target"] == target and r["kind"] == kind])
            assert n == start["trials"], f"length {target} {kind}: {n} trials"
    for kind in ("control", "chain"):
        n = len([r for r in reqs if r.get("exp") == "turns" and (r["kind"] == "control") == (kind == "control")])
        assert n == 13, f"turns {kind}: {n} steps"
    for k in start["retentionK"]:
        for kind in ("first", "return"):
            n = len([r for r in reqs if r.get("exp") == "retention" and r["k"] == k and r["kind"] == kind])
            assert n == start["trials"], f"retention K={k} {kind}: {n} trials"
    cold = [r["seq"] for r in reqs if r.get("kind") in ("cold", "control", "first", "between") and r["reusedTokens"]]
    assert not cold, f"first reads or re-reads that reused tokens: {cold}"
    return start


def boot_config(path):
    """The Pie configuration and warnings from a console log (its "[pie] booted" line and engine notes)."""
    text = Path(path).read_text(errors="replace")
    m = re.search(r"\[pie\] booted (\S+) in (\d+) ms: weights (\d+) MiB, kv pages (\d+) x (\d+), lanes (\d+), "
                  r"program (\S+); config kv (\d+)MiB, slots (\d+), processes (\d+), sandbox (\d+) MB", text)
    assert m, f"no boot line in {path}"
    prof = re.search(r"running checked-in profile (\S+), none of whose numbers were measured on it", text)
    return {"deployment": m.group(1), "boot_ms": int(m.group(2)), "weights_mib": int(m.group(3)),
            "kv_pages": int(m.group(4)), "page_tokens": int(m.group(5)), "lanes": int(m.group(6)),
            "program": m.group(7), "kv_budget_mib": int(m.group(8)), "state_slots": int(m.group(9)),
            "processes": int(m.group(10)), "sandbox_mb": int(m.group(11)),
            "gpu_profile_untuned": prof.group(1) if prof else None,
            "neural_engine_failures": len(re.findall(r"did not compile \(Operation not permitted", text)),
            "engine_stall_notes": len(re.findall(r"stalled for", text))}


def earlier_run(path):
    """The earlier run with larger pools: its pools, memory after the cold reads, and when iOS killed it."""
    text = Path(path).read_text(errors="replace")
    boot = re.search(r"\[pie\] booted \S+ in \d+ ms: weights \d+ MiB, kv pages (\d+) x (\d+), lanes (\d+)", text)
    bench = [json.loads(line[line.find("{"):]) for line in text.splitlines() if "HEARTHBENCH {" in line]
    after = next(b for b in bench if b.get("event") == "after-cold")
    start = next(b for b in bench if b.get("event") == "start")
    replies = re.findall(r"\[pie\] reply: prompt", text)
    cold = [b for b in bench if b.get("phase") == "cold"]
    return {"kv_pages": int(boot.group(1)), "page_tokens": int(boot.group(2)), "lanes": int(boot.group(3)),
            "footprint_mib_start": start["footprintMB"],
            "first_read_tokens": [min(b["promptTokens"] for b in cold), max(b["promptTokens"] for b in cold)],
            "requests_before_sample": len(cold), "footprint_mib_after": after["footprintMB"],
            "available_mib_after": after["availableMB"], "replies_before_kill": len(replies),
            "killed_signal_9": "terminated due to signal 9" in text,
            "pool_commit_failed": "a pool commit failed" in text,
            "commit_wanted_mib": (int(m.group(1)) / 2**20) if (m := re.search(
                r"wants (\d+) bytes of an elastic buffer and the load reserved (\d+)", text)) else None,
            "commit_reserved_mib": (int(m.group(2)) / 2**20) if m else None}


def by(rows, **match):
    return [r for r in rows if all(r.get(k) == v for k, v in match.items())]


def mean(xs):
    return st.fmean(xs) if xs else float("nan")


def med(xs):
    return st.median(xs) if xs else float("nan")


# ---------------------------------------------------------------- analysis
def length_table(reqs):
    """E1: per target length, the cold, reuse and control requests of each trial."""
    table = defaultdict(lambda: defaultdict(dict))
    for r in by(reqs, exp="length"):
        table[r["target"]][r["kind"]][r["trial"]] = r
    out = []
    for target in sorted(table):
        row = table[target]
        trials = sorted(set(row["reuse"]) & set(row["control"]))
        pairs = [(row["control"][t], row["reuse"][t]) for t in trials]
        out.append({
            "target": target, "n": len(pairs),
            "cold_tokens": [r["promptTokens"] for r in row["cold"].values()],
            "cold_ttft_ms": [r["ttftMs"] for r in row["cold"].values()],
            "control_tokens": [c["promptTokens"] for c, _ in pairs],
            "control_ttft_ms": [c["ttftMs"] for c, _ in pairs],
            "control_thermal": [c["thermal"] for c, _ in pairs],
            "reuse_tokens": [u["promptTokens"] for _, u in pairs],
            "reuse_reused": [u["reusedTokens"] for _, u in pairs],
            "reuse_new": [u["prefilledTokens"] for _, u in pairs],
            "reuse_ttft_ms": [u["ttftMs"] for _, u in pairs],
            "speedup": [c["ttftMs"] / u["ttftMs"] for c, u in pairs if u["ttftMs"] > 0],
            "control_tok_s": [c["promptTokens"] / c["ttftMs"] * 1000 for c, _ in pairs if c["ttftMs"] > 0],
        })
    return out


def turns_table(reqs):
    """E2: per step, the control (full re-read) and the chain request."""
    steps = defaultdict(dict)
    for r in by(reqs, exp="turns"):
        steps[r["step"]]["control" if r["kind"] == "control" else "chain"] = r
    return [dict(step=s, **steps[s]) for s in sorted(steps) if "control" in steps[s] and "chain" in steps[s]]


def retention_table(reqs):
    """E3: per K and trial, the first read of X and the return to X."""
    cells = defaultdict(dict)
    for r in by(reqs, exp="retention"):
        if r["kind"] in ("first", "return"):
            cells[(r["k"], r["trial"])][r["kind"]] = r
    out = defaultdict(list)
    for (k, trial), c in sorted(cells.items()):
        if "first" in c and "return" in c:
            ret = c["return"]
            out[k].append({"trial": trial, "reused": ret["reusedTokens"], "prompt": ret["promptTokens"],
                           "first_prompt": c["first"]["promptTokens"],
                           "fraction": ret["reusedTokens"] / ret["promptTokens"],
                           "return_ttft_ms": ret["ttftMs"], "first_ttft_ms": c["first"]["ttftMs"]})
    return dict(sorted(out.items()))


# ---------------------------------------------------------------- drawing helpers
def panel_title(ax, letter, title):
    ax.set_title(rf"$\bf{{{letter}}}$   {title}", loc="left", pad=5, fontsize=8, color=INK)


def trial_dots(ax, xs, ys, color):
    ax.plot(xs, ys, "o", ms=3.0, color=color, alpha=0.35, mec="none", zorder=3)


def line(ax, xs, ys, color, lw=1.6, alpha=1.0, filled=True):
    ax.plot(xs, ys, "-", lw=lw, color=color, alpha=alpha, zorder=4)
    ax.plot(xs, ys, "o", ms=4.6, color=color if filled else "white", mec="white" if filled else color,
            mew=1.0 if filled else 1.1, zorder=5)


def end_label(ax, x, y, text, dy=0, dx=5):
    ax.annotate(text, xy=(x, y), xytext=(dx, dy), textcoords="offset points", va="center", ha="left",
                fontsize=7, color=INK2, annotation_clip=False)


def legend_key(ax, items, loc="upper left", **kw):
    handles = [Line2D([0], [0], color=c, lw=1.6, marker="o", ms=4.6, mec="white", mew=1.0, label=lab)
               for lab, c in items]
    ax.legend(handles=handles, loc=loc, **kw)


def thousands(ax, axis="x"):
    fmt = mpl.ticker.FuncFormatter(lambda v, _: f"{int(v):,}")
    (ax.xaxis if axis == "x" else ax.yaxis).set_major_formatter(fmt)


def figure(height, ncols, **gridspec):
    """A figure exactly the note's text width wide, so every figure prints at 100% with the same text size."""
    return plt.subplots(1, ncols, figsize=(FULL_W, height), layout="constrained", gridspec_kw=gridspec or None)


def save(fig, out, name):
    fig.savefig(out / f"{name}.pdf")
    fig.savefig(out / f"{name}.png", dpi=220)
    plt.close(fig)


# ---------------------------------------------------------------- figures
def fig_length(e1, cool, out, summary):
    """Figure 1. Lines join the medians of the three trials; the hollow marker is the one long first read on a
    cool phone, which the caption quotes."""
    xc = [med(r["control_tokens"]) for r in e1]
    yc = [med(r["control_ttft_ms"]) / 1000 for r in e1]
    xu = [med(r["reuse_tokens"]) for r in e1]
    yu = [med(r["reuse_ttft_ms"]) / 1000 for r in e1]
    sp = [med(r["speedup"]) for r in e1]
    fig, (a, b) = figure(1.38, 2, width_ratios=[1.35, 1])
    for r in e1:
        trial_dots(a, r["control_tokens"], [v / 1000 for v in r["control_ttft_ms"]], ORANGE)
        trial_dots(a, r["reuse_tokens"], [v / 1000 for v in r["reuse_ttft_ms"]], BLUE)
    line(a, xc, yc, ORANGE)
    line(a, xu, yu, BLUE)
    end_label(a, xc[-1], yc[-1], "Full re-read")
    end_label(a, xu[-1], yu[-1], "Pie reuse", dy=6)
    if cool:
        a.plot([cool["tokens"]], [cool["ttft_ms"] / 1000], "o", ms=5.2, mfc="white", mec=MUTED, mew=1.4, zorder=6)
        a.annotate(f"cool first read, {cool['ttft_ms'] / 1000:.1f} s", xy=(cool["tokens"], cool["ttft_ms"] / 1000),
                   xytext=(4, -12), textcoords="offset points", ha="right", va="top", fontsize=6.8, color=INK2)
    legend_key(a, [("Full re-read (same prompt, nothing reused)", ORANGE), ("Pie reuse (next message)", BLUE)])
    a.set_xlabel("Prompt length (tokens)")
    a.set_ylabel("Time to first token (s)")
    a.set_xlim(0, max(xc) * 1.02)
    a.set_ylim(0, max(v / 1000 for r in e1 for v in r["control_ttft_ms"]) * 1.12)
    thousands(a)
    panel_title(a, "a", "Time to first token")

    for r in e1:
        trial_dots(b, r["control_tokens"], r["speedup"], BLUE)
    line(b, xc, sp, BLUE)
    end_label(b, xc[-1], sp[-1], f"{sp[-1]:.0f}x", dx=6)
    b.set_xlabel("Prompt length (tokens)")
    b.set_ylabel("Speedup")
    b.set_xlim(0, max(xc) * 1.02)
    b.set_ylim(0, max(max(r["speedup"]) for r in e1) * 1.12)
    b.yaxis.set_major_formatter(mpl.ticker.FuncFormatter(lambda v, _: f"{v:.0f}x"))
    thousands(b)
    panel_title(b, "b", "Speedup from reuse")
    save(fig, out, "fig1_ttft_vs_length")

    reuse_all = [v for r in e1 for v in r["reuse_ttft_ms"]]
    summary["length"] = {
        "rows": [{k: r[k] for k in ("target", "n", "control_tokens", "control_ttft_ms", "control_thermal",
                                     "reuse_tokens", "reuse_reused", "reuse_new", "reuse_ttft_ms", "speedup",
                                     "cold_tokens", "cold_ttft_ms")} for r in e1],
        "trials": sorted({r["n"] for r in e1}),
        "reuse_ttft_ms": {"median": med(reuse_all), "min": min(reuse_all), "max": max(reuse_all), "n": len(reuse_all)},
        "reuse_new_tokens": {"min": min(v for r in e1 for v in r["reuse_new"]),
                             "max": max(v for r in e1 for v in r["reuse_new"])},
        "shortest": {"tokens": xc[0], "control_ms": yc[0] * 1000, "reuse_ms": yu[0] * 1000, "speedup": sp[0]},
        "longest": {"tokens": xc[-1], "control_ms": yc[-1] * 1000, "reuse_ms": yu[-1] * 1000, "speedup": sp[-1]},
        "reuse_min_tokens": min(v for r in e1 for v in r["reuse_tokens"]),
        "reuse_max_tokens": max(v for r in e1 for v in r["reuse_tokens"]),
        "order_within_length": "first read, then reuse, then full re-read",
        "longest_control_states": sorted(set(e1[-1]["control_thermal"])),
    }


def long_reads(reqs):
    """Full reads at the longest length: the one on a cool phone (if any) and the rest, for an honest headline."""
    top = max(r["target"] for r in reqs if r.get("exp") == "length")
    at_top = [r for r in reqs if r.get("exp") == "length" and r["target"] == top and r["kind"] in ("cold", "control")]
    reuse_top = [r["ttftMs"] for r in reqs if r.get("exp") == "length" and r["target"] == top and r["kind"] == "reuse"]
    cool = [r for r in at_top if r["thermal"] == "nominal"]
    warm = [r for r in at_top if r["thermal"] != "nominal"]
    out = {"target": top, "reuse_median_ms": med(reuse_top),
           "warm": {"n": len(warm), "states": sorted({r["thermal"] for r in warm}),
                    "ttft_ms": [min(r["ttftMs"] for r in warm), max(r["ttftMs"] for r in warm)],
                    "tokens": [min(r["promptTokens"] for r in warm), max(r["promptTokens"] for r in warm)]}}
    if cool:
        best = max(cool, key=lambda r: r["promptTokens"])
        out["cool"] = {"tokens": best["promptTokens"], "ttft_ms": best["ttftMs"], "kind": best["kind"],
                       "speedup": best["ttftMs"] / med(reuse_top)}
    return out


def fig_turns(e2, out, summary):
    steps = [r["step"] for r in e2]
    ctl = [r["control"]["ttftMs"] / 1000 for r in e2]
    chn = [r["chain"]["ttftMs"] / 1000 for r in e2]
    fig, (a, b) = figure(1.28, 2)
    line(a, steps, ctl, ORANGE)
    line(a, steps[1:], chn[1:], BLUE)
    a.plot([steps[0]], [chn[0]], "o", ms=4.6, color=MUTED, mec="white", mew=1.0, zorder=6)
    end_label(a, steps[-1], ctl[-1], "Full re-read")
    end_label(a, steps[-1], chn[-1], "Pie reuse", dy=6)
    legend_key(a, [("Full re-read (no reuse)", ORANGE), ("Pie reuse, turn after turn", BLUE)], loc="upper left")
    a.legend(handles=a.get_legend().legend_handles + [Line2D([0], [0], lw=0, marker="o", ms=4.6, color=MUTED,
                                                             mec="white", label="First read")],
             loc="upper left", ncol=3, fontsize=6.4, handlelength=1.6, columnspacing=0.9)
    a.set_xlabel("Turn (0 = first read)")
    a.set_ylabel("Time to first token (s)")
    a.set_xticks(steps[::2])
    a.set_xlim(-0.4, steps[-1] + 0.4)
    a.set_ylim(0, max(ctl + chn) * 1.55)
    panel_title(a, "a", "Each new message in one chat")

    reused = [r["chain"]["reusedTokens"] for r in e2]
    new = [r["chain"]["prefilledTokens"] for r in e2]
    b.bar(steps, reused, width=0.62, color=BLUE, zorder=3)
    b.bar(steps, new, width=0.62, bottom=reused, color=LIGHT, linewidth=0, zorder=3)
    b.set_xlabel("Turn (0 = first read)")
    b.set_ylabel("Prompt tokens")
    b.set_xticks(steps[::2])
    b.set_xlim(-0.6, steps[-1] + 0.6)
    b.set_ylim(0, max(u + n for u, n in zip(reused, new)) * 1.22)
    thousands(b, "y")
    b.legend(handles=[Patch(color=BLUE, label="Reused from Pie's checkpoint"),
                      Patch(color=LIGHT, label="Computed this turn")], loc="upper left")
    panel_title(b, "b", "What Pie computes each turn")
    save(fig, out, "fig2_multiturn")

    later = e2[1:]
    summary["turns"] = {
        "steps": len(e2),
        "prompt_tokens_first": e2[0]["chain"]["promptTokens"], "prompt_tokens_last": e2[-1]["chain"]["promptTokens"],
        "control_ttft_ms_first": e2[0]["control"]["ttftMs"], "control_ttft_ms_last": e2[-1]["control"]["ttftMs"],
        "chain_ttft_ms_first": e2[0]["chain"]["ttftMs"],
        "chain_ttft_ms_reuse_turns": {"median": med([r["chain"]["ttftMs"] for r in later]),
                                      "min": min(r["chain"]["ttftMs"] for r in later),
                                      "max": max(r["chain"]["ttftMs"] for r in later)},
        "computed_tokens_reuse_turns": {"min": min(r["chain"]["prefilledTokens"] for r in later),
                                        "max": max(r["chain"]["prefilledTokens"] for r in later)},
        "reuse_hits": sum(1 for r in later if r["chain"]["reusedTokens"] > 0), "reuse_turns": len(later),
        "prompt_tokens_total": sum(r["chain"]["promptTokens"] for r in e2),
        "computed_tokens_total": sum(r["chain"]["prefilledTokens"] for r in e2),
        "rows": [{"step": r["step"], "prompt": r["chain"]["promptTokens"], "reused": r["chain"]["reusedTokens"],
                  "computed": r["chain"]["prefilledTokens"], "chain_ttft_ms": r["chain"]["ttftMs"],
                  "control_ttft_ms": r["control"]["ttftMs"], "control_prompt": r["control"]["promptTokens"]}
                 for r in e2],
    }


def fig_retention(e3, out, summary, lp_e3):
    """Figure 3. Each return either found the whole checkpoint or nothing, so (a) counts trials instead of
    averaging them, and (b) colors every return by what happened."""
    ks = list(e3)
    fig, (a, b) = figure(1.28, 2)
    hits = [sum(1 for c in e3[k] if c["reused"] > 0) for k in ks]
    n = [len(e3[k]) for k in ks]
    pos = list(range(len(ks)))
    a.bar(pos, hits, width=0.5, color=BLUE, zorder=3)
    for x, h_, n_ in zip(pos, hits, n):
        a.annotate(f"{h_} of {n_}", xy=(x, h_), xytext=(0, 3), textcoords="offset points", ha="center",
                   va="bottom", fontsize=7.2, color=INK2)
    a.set_xticks(pos, [str(k) for k in ks])
    a.set_ylim(0, max(n) * 1.25)
    a.yaxis.set_major_locator(mpl.ticker.MultipleLocator(1))
    a.set_xlabel("Other chats read in between")
    a.set_ylabel("Trials kept (of 3)")
    a.tick_params(axis="x", length=0)
    panel_title(a, "a", "Coming back to a chat")

    for x, k in zip(pos, ks):
        for i, c in enumerate(sorted(e3[k], key=lambda c: c["trial"])):  # trials side by side, so none hides another
            b.plot([x - 0.1 - 0.08 * i], [c["first_ttft_ms"] / 1000], "o", ms=4.2, color=MUTED, mec="white", mew=0.8,
                   zorder=3)
            b.plot([x + 0.1 + 0.08 * i], [c["return_ttft_ms"] / 1000], "o", ms=4.6,
                   color=BLUE if c["reused"] > 0 else ORANGE, mec="white", mew=0.8, zorder=4)
    handles = [Line2D([0], [0], lw=0, marker="o", ms=4.6, color=MUTED, mec="white", label="First read of the chat"),
               Line2D([0], [0], lw=0, marker="o", ms=4.6, color=BLUE, mec="white", label="Return, checkpoint kept"),
               Line2D([0], [0], lw=0, marker="o", ms=4.6, color=ORANGE, mec="white", label="Return, read from scratch")]
    b.legend(handles=handles, loc="upper left", ncol=3, fontsize=6.4, handlelength=0.8, columnspacing=0.9)
    b.set_xticks(pos, [str(k) for k in ks])
    b.tick_params(axis="x", length=0)
    b.set_xlim(-0.5, len(ks) - 0.5)
    b.set_ylim(0, max(max(max(c["return_ttft_ms"], c["first_ttft_ms"]) for c in e3[k]) for k in ks) / 1000 * 1.5)
    b.set_xlabel("Other chats read in between")
    b.set_ylabel("Time to first token (s)")
    panel_title(b, "b", "Time to first token on return")
    save(fig, out, "fig3_retention")

    misses = [c["return_ttft_ms"] for k in ks for c in e3[k] if c["reused"] == 0]
    miss_firsts = [c["first_ttft_ms"] for k in ks for c in e3[k] if c["reused"] == 0]
    firsts_all = [c["first_ttft_ms"] for k in ks for c in e3[k]]
    summary["retention"] = {
        "by_k": {str(k): {"n": len(e3[k]), "hits": sum(1 for c in e3[k] if c["reused"] > 0),
                          "mean_fraction": mean([c["fraction"] for c in e3[k]]),
                          "kept_fraction": [c["fraction"] for c in e3[k] if c["reused"] > 0],
                          "reused": [c["reused"] for c in e3[k]], "prompt": [c["prompt"] for c in e3[k]],
                          "first_prompt": [c["first_prompt"] for c in e3[k]],
                          "return_ttft_ms": [c["return_ttft_ms"] for c in e3[k]]} for k in ks},
        "kept_fraction_range": [min(c["fraction"] for k in ks for c in e3[k] if c["reused"] > 0),
                                max(c["fraction"] for k in ks for c in e3[k] if c["reused"] > 0)],
        "first_ttft_ms_median": med(firsts_all), "first_reads": len(firsts_all),
        "miss_return_ttft_ms_median": med(misses), "misses": len(misses),
        "miss_first_ttft_ms_median": med(miss_firsts),
        "lowpower": {str(k): {"n": len(v), "hits": sum(1 for c in v if c["reused"] > 0)} for k, v in lp_e3.items()},
    }


def fig_power_heat_memory(e1, e1_lp, reqs, lp_reqs, out, summary, start):
    fig, (a, h, m) = figure(1.38, 3, width_ratios=[1.15, 1.05, 0.9])

    def medians(table, kt, km):
        return [med(r[kt]) for r in table], [med(r[km]) / 1000 for r in table]

    for table, filled in ((e1, True), (e1_lp, False)):
        for color, kt, km in ((ORANGE, "control_tokens", "control_ttft_ms"), (BLUE, "reuse_tokens", "reuse_ttft_ms")):
            x, y = medians(table, kt, km)
            line(a, x, y, color, lw=1.6 if filled else 1.1, alpha=1 if filled else 0.6, filled=filled)
    handles = [
        Line2D([0], [0], color=ORANGE, lw=1.1, alpha=0.6, marker="o", ms=4.6, mfc="white", mec=ORANGE,
               label="Re-read, Low Power on"),
        Line2D([0], [0], color=ORANGE, lw=1.6, marker="o", ms=4.6, mec="white", label="Re-read, Low Power off"),
        Line2D([0], [0], color=BLUE, lw=1.1, alpha=0.6, marker="o", ms=4.6, mfc="white", mec=BLUE,
               label="Reuse, Low Power on"),
        Line2D([0], [0], color=BLUE, lw=1.6, marker="o", ms=4.6, mec="white", label="Reuse, Low Power off"),
    ]
    a.legend(handles=handles, loc="upper left", fontsize=6.6, handlelength=1.8, labelspacing=0.25)
    xl, yl = medians(e1_lp, "control_tokens", "control_ttft_ms")
    a.set_xlabel("Prompt length (tokens)")
    a.set_ylabel("Time to first token (s)")
    a.set_xlim(0, max(xl) * 1.03)
    a.set_ylim(0, max(yl) * 1.15)
    a.xaxis.set_major_locator(mpl.ticker.MultipleLocator(1000))
    a.tick_params(axis="x", labelsize=6.8)
    thousands(a)
    panel_title(a, "a", "Low Power Mode (medians)")

    # Heat: each full read's speed against its length, shaded by the thermal state iOS reported as it finished.
    reads = [r for r in reqs if (r.get("kind") in ("cold", "control", "first", "between")
                                 or (r.get("kind") == "return" and r["reusedTokens"] == 0))
             and r["promptTokens"] >= 500 and r["prefillTokPerSec"] > 0]
    states = [x for x in ("nominal", "fair", "serious") if any(r["thermal"] == x for r in reads)]
    for state in states:
        pts = [r for r in reads if r["thermal"] == state]
        h.plot([r["promptTokens"] for r in pts], [r["prefillTokPerSec"] for r in pts], "o", ms=3.4,
               color=HEAT[state], alpha=0.9, mec="white", mew=0.5, zorder=3, label=f"{state} (n={len(pts)})")
    h.legend(loc="lower right", fontsize=6.4, handlelength=0.8, labelspacing=0.2)
    h.set_xlabel("Prompt length (tokens)")
    h.set_ylabel("Tokens/s")
    h.set_xlim(0, max(r["promptTokens"] for r in reads) * 1.05)
    h.set_ylim(0, max(r["prefillTokPerSec"] for r in reads) * 1.15)
    h.xaxis.set_major_locator(mpl.ticker.MultipleLocator(1000))
    h.tick_params(axis="x", labelsize=6.8)
    thousands(h)
    panel_title(h, "b", "Full-read speed by heat")

    rows = sorted(reqs, key=lambda r: r["seq"])
    t = [0.0] + [r["t"] / 60 for r in rows]  # the start sample: engine booted, before the first request
    fp = [start["footprintMB"] / 1024] + [r["footprintMB"] / 1024 for r in rows]
    lim = [(start["footprintMB"] + start["availableMB"]) / 1024] + [(r["footprintMB"] + r["availableMB"]) / 1024
                                                                     for r in rows]
    m.plot(t, lim, "-", lw=0.9, color=MUTED, zorder=3)
    m.plot(t, fp, "-", lw=1.6, color=INK, zorder=4)
    m.annotate("iOS limit for the app", xy=(t[-1], lim[-1]), xytext=(0, 4), textcoords="offset points",
               ha="right", va="bottom", fontsize=7, color=INK2)
    m.annotate(f"Hearth + Pie\nhighest {max(fp):.2f} GiB", xy=(t[-1], fp[-1]), xytext=(0, -26),
               textcoords="offset points", ha="right", va="top", fontsize=7, color=INK2,
               bbox=dict(fc="white", ec="none", pad=0.6))
    m.set_xlabel("Minutes into the run")
    m.set_ylabel("Footprint (GiB)")
    m.set_ylim(0, max(lim) * 1.18)
    m.set_xlim(0, t[-1] * 1.01)
    m.xaxis.set_major_locator(mpl.ticker.MultipleLocator(2))
    panel_title(m, "c", "Memory over the run")
    save(fig, out, "fig4_power_heat_memory")

    def band(lo, hi):
        res = {}
        for state in ("nominal", "fair", "serious"):
            v = [r["prefillTokPerSec"] for r in reads if lo <= r["promptTokens"] <= hi and r["thermal"] == state]
            if v:
                res[state] = {"n": len(v), "median_tok_s": med(v), "min": min(v), "max": max(v)}
        return res

    hit_rows = [r for r in reqs if r["reusedTokens"] > 0]
    unplugged = [r["seq"] for r in reqs if r.get("batteryState") == "unplugged"]
    fair_short = [r for r in reads if 550 <= r["promptTokens"] <= 750 and r["thermal"] == "fair"]
    stretch = (unplugged[-1], unplugged[-1] + 10) if unplugged else (0, -1)
    serious = [r for r in reads if r["thermal"] == "serious"]
    summary["heat"] = {
        "reads_2000_plus": band(2000, 10**6), "reads_550_750": band(550, 750),
        "fair_550_750_in_slow_stretch": {"n": sum(1 for r in fair_short if stretch[0] <= r["seq"] <= stretch[1]),
                                         "of": len(fair_short), "from": stretch[0], "to": stretch[1]},
        "serious_reads": {"n": len(serious), "exps": sorted({r["exp"] for r in serious}),
                          "min_tokens": min((r["promptTokens"] for r in serious), default=None),
                          "max_tokens": max((r["promptTokens"] for r in serious), default=None)},
        "reuse_by_state": {x: {"n": len(v), "median_ms": med(v)} for x in ("nominal", "fair", "serious")
                           for v in [[r["ttftMs"] for r in hit_rows if r["thermal"] == x]] if v},
    }
    lp_rates = [med(r["control_tok_s"]) for r in e1_lp]
    lp_reuse_medians = [med(r["reuse_ttft_ms"]) for r in e1_lp]
    lp_slow = sorted(v for r in e1_lp for v in r["control_ttft_ms"] if v > 1.25 * med(r["control_ttft_ms"]))
    nominal_off = summary["heat"]["reads_2000_plus"].get("nominal", {})
    summary["lowpower"] = {
        "requests": len(lp_reqs), "thermal": sorted({r["thermal"] for r in lp_reqs}),
        "trials": sorted({r["n"] for r in e1_lp}),
        "per_length_median_tok_s": [min(lp_rates), max(lp_rates)],
        "all_reads_tok_s_median": med([v for r in e1_lp for v in r["control_tok_s"]]),
        "shortest": {"tokens": med(e1_lp[0]["control_tokens"]), "control_ms": med(e1_lp[0]["control_ttft_ms"])},
        "longest": {"tokens": med(e1_lp[-1]["control_tokens"]), "control_ms": med(e1_lp[-1]["control_ttft_ms"])},
        "slow_reads_ms": lp_slow,
        "reuse_median_ms_range": [min(lp_reuse_medians), max(lp_reuse_medians)],
        "nominal_off_2000_plus_tok_s": nominal_off.get("median_tok_s"),
        "off_line_states": sorted({s for r in e1 for s in r["control_thermal"]}),
    }
    peak = max(r["footprintMB"] for r in rows)
    settle = next(r for r in rows if r["footprintMB"] >= 0.99 * peak)
    summary["memory"] = {
        "start_footprint_mib": start["footprintMB"],
        "growth_from_start_mib": peak - start["footprintMB"],
        "first_footprint_mib": rows[0]["footprintMB"], "highest_footprint_mib": peak,
        "growth_mib": peak - rows[0]["footprintMB"],
        "min_available_mib": min(r["availableMB"] for r in rows),
        "limit_mib": sorted({r["footprintMB"] + r["availableMB"] for r in rows}
                            | {start["footprintMB"] + start["availableMB"]}),
        "within_1pct_of_highest_from_min": settle["t"] / 60, "within_1pct_of_highest_from_seq": settle["seq"],
    }
    full = sorted(reads, key=lambda r: r["prefillTokPerSec"])
    summary["slowest_full_reads"] = [{"seq": r["seq"], "tok_s": r["prefillTokPerSec"], "battery": r.get("batteryState")}
                                     for r in full[:8]]


def all_reuse(reqs, summary):
    """Every request that found a checkpoint, across the three experiments."""
    hits = [r for r in reqs if r["reusedTokens"] > 0]
    summary["reuse_all"] = {"n": len(hits), "ttft_ms_min": min(r["ttftMs"] for r in hits),
                            "ttft_ms_max": max(r["ttftMs"] for r in hits),
                            "ttft_ms_median": med([r["ttftMs"] for r in hits]),
                            "prompt_min": min(r["promptTokens"] for r in hits),
                            "prompt_max": max(r["promptTokens"] for r in hits),
                            "computed_min": min(r["prefilledTokens"] for r in hits),
                            "computed_max": max(r["prefilledTokens"] for r in hits)}


def stall_reads(console, reqs, summary):
    """Requests during which Pie's scheduler printed "engine 0 stalled" (each note follows the last finished request)."""
    by_seq = {r["seq"]: r for r in reqs}
    last, during = None, []
    for ln in Path(console).read_text(errors="replace").splitlines():
        if "HEARTHSWEEP {" in ln:
            d = json.loads(ln[ln.find("{"):])
            if "seq" in d and "event" not in d:
                last = d["seq"]
        elif "stalled for" in ln and last is not None and last + 1 in by_seq:
            during.append(by_seq[last + 1])
    text = Path(console).read_text(errors="replace")
    blocks = text.split("stalled for ")[1:]
    batches = sorted({int(b.group(1)) for blk in blocks for b in [re.search(r"batch of (\d+)", blk)] if b})
    secs = [float(re.match(r"([\d.]+)s", blk).group(1)) for blk in blocks if re.match(r"([\d.]+)s", blk)]
    summary["stall_notes"] = {"n": len(during), "seqs": [r["seq"] for r in during], "batch_sizes": batches,
                              "after_s": [min(secs), max(secs)] if secs else None,
                              "tokens": [min((r["promptTokens"] for r in during), default=0),
                                         max((r["promptTokens"] for r in during), default=0)],
                              "tok_s": [min((r["prefillTokPerSec"] for r in during), default=0),
                                        max((r["prefillTokPerSec"] for r in during), default=0)]}


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--main", required=True)
    ap.add_argument("--lowpower", required=True)
    ap.add_argument("--console", required=True, help="console log of the main run (boot line)")
    ap.add_argument("--earlier", help="console log of the earlier run with larger pools")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    rows, bad = load(args.main)
    reqs, errors, events = split(rows, low_power=False)
    start = check_main(rows, reqs, errors)
    done = next(e for e in events if e["event"] == "done")
    cooldowns = [e for e in events if e["event"] == "cooldown"]
    lp_rows, lp_bad = load(args.lowpower)
    lp_reqs, lp_errors, _ = split(lp_rows, low_power=True)
    lp_off = [r for r in lp_rows if "seq" in r and "event" not in r and r.get("lowPower") is False]
    decode = [r["decodeTokPerSec"] for r in reqs if r.get("generatedTokens", 0) >= 16 and r["decodeTokPerSec"] > 0]

    summary = {
        "run": start["run"], "device": start["device"], "os": start["os"], "model": start["model"],
        "engine": start["engine"], "context_length": start["contextLength"], "trials": start["trials"],
        "lengths": start["lengths"], "retention_k": start["retentionK"],
        "requests": len(reqs), "errors": len(errors), "unreadable_lines": bad,
        "cooldowns": len(cooldowns), "start_thermal": start["thermal"],
        "duration_s": done["seconds"],
        "thermal_at_finish": {s: sum(1 for r in reqs if r["thermal"] == s)
                              for s in ("nominal", "fair", "serious", "critical")},
        "battery_state": {s: sum(1 for r in reqs if r.get("batteryState") == s)
                          for s in ("charging", "unplugged", "full")},
        "unplugged_seqs": [r["seq"] for r in reqs if r.get("batteryState") == "unplugged"],
        "wall_minus_inferlet_ttft_ms_median": med([r["wallFirstMs"] - r["ttftMs"] for r in reqs
                                                   if r.get("wallFirstMs") is not None]),
        "decode_tok_s": {"median": med(decode), "min": min(decode), "max": max(decode), "n": len(decode),
                         "min_generated_tokens": 16,
                         "max_generated_tokens": max(r["generatedTokens"] for r in reqs)},
        "lowpower_run": {"run": lp_rows[0].get("run"), "requests_low_power_on": len(lp_reqs),
                         "requests_low_power_off_excluded": len(lp_off), "errors": len(lp_errors),
                         "unreadable_lines": lp_bad},
        "pie": boot_config(args.console),
    }
    if args.earlier:
        summary["earlier"] = earlier_run(args.earlier)

    with open(out / "requests.csv", "w", newline="") as f:
        cols = ["run", "seq", "t", "exp", "kind", "trial", "target", "step", "k", "j", "attempt", "promptTokens",
                "reusedTokens", "prefilledTokens", "generatedTokens", "ttftMs", "wallFirstMs", "wallTotalMs",
                "prefillTokPerSec", "decodeTokPerSec", "footprintMB", "availableMB", "thermal", "lowPower",
                "battery", "batteryState"]
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in sorted(reqs, key=lambda r: r["seq"]):
            w.writerow(r)

    e1 = length_table(reqs)
    longs = long_reads(reqs)
    fig_length(e1, longs.get("cool"), out, summary)
    summary["length"]["long_reads"] = longs
    summary["length"]["trial1_order"] = [r["target"] for r in sorted(
        (r for r in reqs if r.get("exp") == "length" and r["trial"] == 1 and r["kind"] == "cold"), key=lambda r: r["order"])]
    all_reuse(reqs, summary)
    stall_reads(args.console, reqs, summary)
    fig_turns(turns_table(reqs), out, summary)
    fig_retention(retention_table(reqs), out, summary, retention_table(lp_reqs))
    fig_power_heat_memory(e1, length_table(lp_reqs), reqs, lp_reqs, out, summary, start)
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps({k: summary[k] for k in summary if k not in ("length", "turns", "retention")}, indent=1))


if __name__ == "__main__":
    main()
