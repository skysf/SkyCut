#!/usr/bin/env bash
# Sourced by timeline-drag-wiring.sh: the live factory chain and the web-template preview/commit use existing shared rules.
python3 - <<'PYTHON'
from pathlib import Path
import re

def code(path):
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f"FAIL: timeline router source is missing: {path}")
    return "\n".join(line for line in p.read_text().splitlines() if not line.lstrip().startswith("//"))

def require(text, snippet, why):
    if snippet not in text:
        raise SystemExit(f"FAIL: {why}: expected {snippet}")

view = code("Sources/SrtFlow/VideoEditTimelineView.swift")
factory = code("Sources/SrtFlow/TimelineDropRouterFactory.swift")
router = code("Sources/SrtFlow/VideoEditTimelineDropRouter.swift")
motion = code("Sources/SrtFlow/WebMotion/WebMotionPresetDrag.swift")
card = code("Sources/SrtFlow/WebMotion/WebMotionPresetCard.swift")
model = code("Sources/SrtFlow/WebMotion/WebMotionPresetModel.swift")
require(view, ".onDrop(of: TimelineDropRouter.types, delegate: timelineDropRouter)", "the sole destination uses its live router")
require(view, "TimelineDropRouterFactory.make(", "the timeline constructs the factored delegates")
require(factory, "$0.spec.slot == .main && !$0.spec.isHidden", "transitions only accept the visible main row")
for label, delegate in [("files", "MediaFileDropDelegate"), ("filter", "FilterDropDelegate"),
                        ("audio", "AudioLibraryDropDelegate"), ("transition", "TransitionDropDelegate"),
                        ("motion", "WebMotionPresetDropDelegate")]:
    require(factory, f"{label}: {delegate}(", "the factory retains every payload delegate")
require(factory, "mainRow: main.map", "the router receives the visible main-row geometry")
require(factory, "VideoEditTimelineView.layouts(of: rows, open: openSeam.wrappedValue)", "delegates share current seam geometry")
for text, snippet, expected in [(view, "dwell: seamDwell", 1), (view, "openSeam: $openSeam", 1),
                                (factory, "dwell: dwell", 2), (factory, "openSeam: openSeam", 2)]:
    if text.count(snippet) != expected:
        raise SystemExit(f"FAIL: the live factory must pass {snippet} exactly {expected} times")
require(router, "if info.hasItemsConforming(to: [WebMotionPresetDrag.type]) { return .motion }", "motion payloads are routed")
for method in ["dropEntered", "dropUpdated", "dropExited", "performDrop"]:
    require(router, f"motion.{method}(info: info)", f"motion forwards {method}")
require(router, "case .motion: WebMotionPresetDrag.pending != nil", "post-perform updates cannot revive a motion drag")
require(card, ".onDrag {", "the template card remains a drag source")
require(card, "WebMotionPresetDrag.itemProvider(", "the card uses the declared motion payload")
require(motion, "project.isCurrentGeneration(pending.generation)", "a drag cannot cross documents")
require(motion, "WebMotionPresetRequest(", "drop time and generation are captured before the Task")
require(model, "project.isCurrentGeneration(request.generation)", "queued adds reject another document")
require(model, "WebMotionActions.place(", "UI add/drop uses the shared checked commit")
# These are separate consumers, each pinned positively; a new consumer cannot replace the file or AI call counts.
for call in ["mediaImportLandings(", "importFirstStart(", "TimelineDropPlaceholder.newLaneY("]:
    count = motion.count(call)
    if count != 1:
        raise SystemExit(f"FAIL: web-template preview must use {call} exactly once; found {count}")
print("PASS: live timeline factory, web-template routing and shared preview geometry")
PYTHON
