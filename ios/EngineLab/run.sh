#!/bin/bash
# EngineLab: builds the Mac test harness for Hearth's engines and runs it against real GGUF models.
# Usage: ios/EngineLab/run.sh [--apple] [model.gguf ...] [--bench model.gguf]
#   With no models it uses Llama 3.2 1B + 3B from ~/random/hearth-models and Qwen3 0.6B (no-think path)
#   from ~/random/pie-models, then runs the app's HearthBenchmark through EngineHost on the 3B.
#   --apple also exercises Apple's on-device model when this Mac has it.
#   Writes ios/EngineLab/RESULTS.md and exits non-zero if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$PWD/Vendor/llama.xcframework/macos-arm64_x86_64"
SCRATCH="${ENGINELAB_SCRATCH:-${TMPDIR:-/tmp}/hearth-enginelab}"
mkdir -p "$SCRATCH/home/Documents"

xcrun swiftc -O -target arm64-apple-macos26.0 -swift-version 5 \
  -F "$FW" -framework llama -Xlinker -rpath -Xlinker "$FW" \
  Hearth/Core/*.swift Hearth/Engine/*.swift Hearth/Dev/Benchmark.swift \
  EngineLab/main.swift -o "$SCRATCH/enginelab"

MODELS_DIR="$(cd ../.. && pwd)"
if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--apple" ]; }; then
  set -- "$@" \
    "$MODELS_DIR/hearth-models/Llama-3.2-1B-Instruct-Q4_K_M.gguf" \
    "$MODELS_DIR/hearth-models/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
    "$MODELS_DIR/pie-models/Qwen3-0.6B-Q4_K_M.gguf" \
    --bench "$MODELS_DIR/hearth-models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
fi

# CFFIXED_USER_HOME keeps Hearth's own writes (console log, parked KV files) inside the scratch folder.
status=0
CFFIXED_USER_HOME="$SCRATCH/home" "$SCRATCH/enginelab" --results "$PWD/EngineLab/RESULTS.md" "$@" || status=$?
# EngineHost keeps a tiny load marker in UserDefaults; remove the harness's (now empty) defaults file.
defaults delete enginelab >/dev/null 2>&1 || true
rm -f "${HOME:?}/Library/Preferences/enginelab.plist"
exit "$status"
