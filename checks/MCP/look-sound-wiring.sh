#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, not run alone): the sound under look's sheet (MCP-66) stays the export's
# measurement. look's strip is MixMeasurement on MediaReadQueue.export with the export's configuration (never the preview's engine);
# track rows parse only through listen's layers; the frame rate comes from the project; look reads the request before it lets its
# line go and renders it after; inspect_video draws the frames its report measured (no second render). The behavior runs in
# scripts/check-look-jobs.sh (LookSoundChecks) and scripts/check-video-inspection.sh; the contract is
# docs/architecture/ai-control-mcp.md section 4 item 12.

echo "==> look sound: the export's measurement on the export queue, rows parsed as listen's layers, inspect_video reuses its frames"
python3 - <<'PY'
import pathlib
def code(path):
    return "\n".join(line.split("//", 1)[0] for line in pathlib.Path(path).read_text().splitlines())
measure, request = code("Sources/SrtFlow/AISoundStripMeasure.swift"), code("Sources/SrtFlow/AISoundStripRequest.swift")
look, inspect = code("Sources/SrtFlow/AILookTool.swift"), code("Sources/SrtFlow/AIInspectionTool.swift")
assert measure.count("MediaReadQueue.run(on: MediaReadQueue.export)") == 1, "✗ look's strip must render on MediaReadQueue.export"
assert measure.count("AudioEngineConfig.make(from: state)") == 1 and measure.count("MixMeasurement.measure(") == 1, \
    "✗ look's strip must be MixMeasurement of the export's configuration (AudioEngineConfig.make(from:))"
for banned in ["suspend(", "wake(", "recoverIfNeeded(", "AudioEngineIdleKeeper", "audioEngineHost", ".realtime", "AudioStemRender"]:
    assert banned not in measure, f"✗ AISoundStripMeasure must not touch the preview engine or render on its own ({banned})"
assert request.count("AIListenMixPlan.layers(") == 1, "✗ sound's track rows must parse through listen's layers (AIListenMixPlan.layers)"
assert "MixFrameGrid(fps: state.frameRate.fps)" in request, "✗ the strip's frame rate must come from the project"
body = look[look.index("private static func lookAtTimeline("):]
parse, go = body.find("AISoundStripRequest.parse("), body.find("AICallLines.letGo()")
render, finish = body.find("AISoundStripMeasure.strip("), body.find("sound: try await strip")
assert 0 <= parse < go < render < finish, "✗ look must read sound before letting its line go, then render it and hand it to finish"
assert "AISoundStripMeasure.strip(" not in inspect and inspect.count("AISoundStripMeasure.inspection(measurement.frames") == 1 \
    and inspect.count("sound: sound)") == 1, "✗ inspect_video must draw the frames its report measured (no second render)"
PY
echo "   ✓ look's strip renders the export's configuration on MediaReadQueue.export; rows parse as layers; inspect_video reuses its frames"
