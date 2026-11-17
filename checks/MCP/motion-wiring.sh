#!/usr/bin/env bash
# Native presets and web motion share the project/undo contracts. Sourced before check-mcp compiles.
# 动效预设（docs/architecture/motion-presets.md 第二节第 5、9 条）：界面上改字的两个入口都经 MotionPresetGroups.update（标题挪了、
# 改了字，同一套跟着走）；粘贴给预设换新组号（粘出来的一套不和原来那套连在一起）。
if [ "$(grep -c 'MotionPresetGroups.update(id, in: &\$0, change)' Sources/SrtFlow/VideoEditProject+Text.swift || true)" -ne 2 ] \
   || [ "$(grep -c 'MotionPresetTag.renew(' Sources/SrtFlow/VideoEditClipboardPaste.swift || true)" -ne 2 ]; then
  echo "✗ 动效预设：VideoEditProject.updateTextOverlay / liveUpdateTextOverlay 要经 MotionPresetGroups.update，粘贴要给文字和形状都换新组号"
  exit 1
fi
echo "   ✓ 动效预设：界面上改字经 MotionPresetGroups.update、粘贴换新组号"

python3 - <<'PYTHON'
from pathlib import Path

def require(path, snippet):
    if snippet not in Path(path).read_text():
        raise SystemExit(f"FAIL: web motion wiring: {path} must contain {snippet}")

require("Sources/SrtFlow/AIToolRouter.swift", "case .setMotion: return try await AIMotionTool.set(args, project)")
require("Sources/SrtFlow/AIToolRouter.swift", ".setTransition, .setText, .setMotion, .setShape")
require("Sources/SrtFlow/WebMotion/AIMotionApproval.swift", "request.needsPageApproval, access.mode == .ask")
require("Sources/SrtFlow/WebMotion/AIMotionApproval.swift", "AIConfirmations.shared.redeem(token, for: action)")
require("Sources/SrtFlow/WebMotion/AIMotionApproval.swift", 'values["document_generation"]')
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "AIJobs.shared.start(.motion")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "AIJobs.shared.finish(job, .done")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "AIRoundVersions.reporting(project, in: answer)")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "request.expectedSourceLane != WebMotionSourceLane.capture(placed.clip.id, in: project.state)")
require("Sources/SrtFlow/WebMotion/WebMotionActions.swift", "project.isCurrentGeneration(generation)")
require("Sources/SrtFlow/WebMotion/WebMotionActions.swift", "project.state.clip(with: id!) == before")
require("Sources/SrtFlow/WebMotion/WebMotionActions.swift", "let sourceLane = WebMotionSourceLane.capture(id, in: project.state)")
require("Sources/SrtFlow/WebMotion/WebMotionActions.swift", "WebMotionSourceLane.capture(id, in: project.state) == sourceLane")
require("Sources/SrtFlow/WebMotion/AIMotionRequest.swift", "self.expectedSourceLane = WebMotionSourceLane.capture(replacing, in: state)")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "project.state.clip(with: request.replacing!) == request.expectedClip")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "WebMotionSourceLane.capture(request.replacing, in: project.state) == request.expectedSourceLane")
require("Sources/SrtFlow/WebMotion/AIMotionRequest.swift", "self.expectedTargetLaneID = targetLaneID")
require("Sources/SrtFlow/WebMotion/AIMotionRequest.swift", "state.overlayTracks.firstIndex { $0.id == id && !$0.isHidden }")
require("Sources/SrtFlow/WebMotion/AIMotionTool.swift", "preferring: request.resolvedTarget(in: project.state)")
require("Sources/SrtFlow/WebMotion/WebMotionActions.swift", "AIUndoGrouping.step(project.effectiveUndoManager)")
require("Sources/SrtFlow/WebMotion/WebMotionCache.swift", "WebMotionRenderer.render(")
require("Sources/SrtFlow/VideoEditProjectDocument.swift", "WebMotionRecovery.start(for: self)")
require("Sources/SrtFlow/VideoEditExportGraph.swift", "try requireMotionCaches(state)")
require("Sources/SrtFlow/AITimelineSummary.swift", 'result["motion_library"] = AIMotionSummary.library(state)')
print("PASS: web motion uses the locked renderer, approval modes, jobs, document guards, one undo, cache recovery and discovery")
PYTHON

