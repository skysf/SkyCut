#!/usr/bin/env bash
# macOS's sound classifier as listen describe=true uses it (SoundLabelScores; docs/architecture/listening-engine.md section 2
# item 4a): on 9 s of synthetic sound (a low drone, white noise, a major chord) it gives one window per 3 s, every label with
# its own score in 0…1, strongest first, and more than one label scoring in a window — each label's own score, not one verdict.
# No ffmpeg, no App, no network; only SoundAnalysis (built into macOS).
#
# Why a script of its own, with a fixed binary path: CoreML compiles the classifier for the Neural Engine the first time each
# new binary uses it (measured on an M1: 25–90 s, minutes under load). A small binary that rarely changes, at the same path,
# keeps that cost out of every other check (it used to sit in check-mix-layers) and lets an unchanged rerun skip it.
#
# Usage: scripts/check-sound-labels.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TRIPLE="arm64-apple-macosx15.0"
OUT=".build/checks/soundlabels"
mkdir -p "$(dirname "$OUT")"

echo "==> Compile the native sound-label check"
xcrun swiftc \
  -target "$TRIPLE" \
  -O \
  -wmo \
  -o "$OUT" \
  Sources/SrtFlow/SoundLabelScores.swift \
  checks/SoundLabels/main.swift

echo "==> Run checks (the first classifier use compiles its model and can take a few minutes)"
"$OUT"
