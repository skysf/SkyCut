#!/usr/bin/env bash
# 制作状态 MainActor/队列/metadata-only 的生产接线；纯值守卫另在 check-film-production。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path

snapshot = Path('Sources/SrtFlow/FilmProduction/AIFilmProductionSnapshot.swift').read_text()
audio = Path('Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift').read_text()
authority = Path('Sources/SrtFlow/FilmProduction/AIFilmProduction.swift').read_text()
tool = Path('Sources/SrtFlow/FilmProduction/AIFilmProductionTool.swift').read_text()
router = Path('Sources/SrtFlow/AIToolRouter.swift').read_text()
checks = {
    'sound metadata disables scene DSP explicitly': 'AudioEngineConfig.make(from: state, measuringSceneCompensation: false)' in snapshot,
    'metadata snapshot cannot directly invoke scene measurement': 'SceneLoudness' not in snapshot and 'compensation:' not in snapshot,
    'normal engine callers still measure scene compensation by default': 'measuringSceneCompensation: Bool = true' in audio,
    'measurement branch is guarded before calling DSP': 'compensation: measuringSceneCompensation ? (clip.soundScene.map(SceneLoudness.compensation(for:)) ?? 1) : 1' in audio,
    'native geometry reuse covers borrowed picture ranges': 'return result.expandingTransitionHandles()' in snapshot and 'result.sortMainClipsByStart()' in snapshot,
    'effective canvas reuses the native render size': 'TimelineRenderSize.size(for: rendered(state))' in snapshot,
    'production argument/CAS gate precedes ordinary save': 'guard let input = try AIFilmProductionReader.input(args) else { return try AIProjectTools.saveProject(args, project) }' in tool,
    'save router enters production authoring': 'case .saveProject: return try await AIFilmProductionTool.save(args, project)' in router,
    'read router enters current production summary': 'case .getTimeline: return try await AIFilmProductionTool.timeline(project)' in router,
}
permissions = authority.split('static func allowedImages(', 1)[1].split('private static func identity(', 1)[0]
checks['permission candidates come from typed anchors only'] = ('AIFilmProductionJSON.anchorImageURLs(production)' in permissions
    and 'AIFilmProductionGraph.decode' not in permissions and 'AIFilmProductionJSON.plan' not in permissions)
for label, passed in checks.items():
    print(('PASS ' if passed else 'FAIL ') + label)
if not all(checks.values()):
    raise SystemExit(1)
print('All production wiring checks passed.')
PY
