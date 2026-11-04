#!/usr/bin/env bash
# region 必须接进现有编辑 / 批量和原生渲染，真实图像验收不能退化成另一份几何公式。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PYTHON'
from pathlib import Path

def read(path):
    return Path(path).read_text()

def require(condition, message):
    if not condition:
        raise SystemExit("✗ region: " + message)

request = read("Sources/SrtFlow/AIFramingRequest.swift")
tools = read("Sources/SrtFlow/AIClipTools.swift")
region = read("Sources/SrtFlow/AIRegionFraming.swift")
crop = read("Sources/SrtFlow/VideoEditClipCrop.swift")
export = read("Sources/SrtFlow/VideoEditExportTransform.swift")
require('"region"' in request and "sourceRegion(args)" in request, "必须先解析、验证完整源矩形")
require(tools.index("AIFramingRequest(args)") < tools.index("await replacement("), "冲突要在异步换源前拒绝")
require("request.region == nil" in tools and "AIRegionFraming.make(" in tools, "显式区域不能落回主体识别")
require("AIFrameFit.fillWindow(" in region and "AIFrameFit.mapping(" in region, "铺满必须复用已有窗和映射")
require("ClipCrop(keeping: kept)" in region, "精确区域必须用原生裁切")
require(not any(name in region for name in ("ShapeAnnotation(", "perform(", "registerUndo", "FFmpegProcess", "CIFilter(")), "不得另造遮挡或渲染 / 提交机制")
require("self.leading = leading" in crop and "self.trailing = trailing" in crop, "解码要保留扩展裁切值")
require("exact=1" in export and 'steps.append("format=rgba")' in export, "奇数像素裁切必须精确，并在裁前处理色度采样")
require("static let latestFormatVersion = 34" in read("Sources/SrtFlow/VideoEditProjectFile.swift"), "工程 v34 保留 v33 扩展裁切保护")
require("requiresFormatVersion33" in read("Sources/SrtFlow/VideoEditFormatVersion.swift"), "格式语义需要登记")
fixture = read("checks/RegionFraming/Fixture.swift")
for call in ("AIClipTools.plan(", "AIClipTools.apply(", "AILookTool.look(", "VideoEditCompositionBuilder.build(", "VideoEditExportGraph.plan(", "FFmpegProcess().run("):
    require(call in fixture, "验收必须调用真实入口 " + call)
require("scripts/check-region-framing.sh" in read("scripts/check-all.sh"), "真实渲染验收必须接入总检查")
require("Sources/SrtFlow/AIRegionFraming.swift" in read("scripts/check-mcp.sh"), "纯值回归必须编到生产区域适配")
print("✓ region：现有单项 / 批量、共享几何、原生裁切与真实 look / 导出验收接通")
PYTHON
