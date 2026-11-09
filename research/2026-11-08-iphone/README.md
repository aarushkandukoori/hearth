# Hearth on Pie - iPhone measurements (November 8, 2026)

A one-page note with four figures on how Pie serves Hearth on an iPhone 16 Pro: time to first token against
chat length with and without Pie's reuse, a 13-turn chat, how long Pie keeps a chat's checkpoint, Low Power
Mode, phone heat and memory.

- `note.pdf` - the write-up (built by `make_note.py`; every measured number in it comes from `summary.json`)
- `fig1_ttft_vs_length`, `fig2_multiturn`, `fig3_retention`, `fig4_power_heat_memory` - figures (PDF and PNG)
- `requests.csv` - every request of the main run, one row each
- `summary.json` - every number the note quotes, plus checks (one run, requests 1..N, three trials everywhere)
- `sweep-main.jsonl`, `sweep-lowpower.jsonl` - the raw lines the app wrote (main run; Low Power Mode run)
- `console-main.log` - the main run's device console (Pie's boot line with the configuration)
- `console-earlier.log` - an earlier run with larger Pie pools that was killed (signal 9)
- `analyze_sweep.py`, `make_note.py` - analysis and note

## Reproduce

The experiment is a launch option in the app, `ios/Hearth/Dev/PieSweep.swift`:

```bash
# from the repository root, with the iPhone plugged in and unlocked
ios/scripts/device.sh build && ios/scripts/device.sh install
ios/scripts/device.sh run -HearthSweep 1 > sweep.log   # keep Hearth on screen; about 8 minutes
# then in this folder (needs matplotlib and numpy; the note needs tectonic)
python3 analyze_sweep.py --main ../../sweep.log --lowpower sweep-lowpower.jsonl \
    --console ../../sweep.log --earlier console-earlier.log --out .
python3 make_note.py .
```

iOS stops GPU work for apps that are not on screen, so the run pauses whenever another app is in front, and
it records Low Power Mode, battery and thermal state on every request.
