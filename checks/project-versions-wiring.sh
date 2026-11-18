#!/usr/bin/env bash
# Saved project versions around AI rounds (docs/architecture/project-versions.md): the production wiring the full-App check
# (scripts/check-project-versions.sh) drives by hand — the router's hook and undo, the round's three save points, the restore path,
# get_status, the project menu, forgetting a closed project's store, and that only the store writes version files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PY'
import re
from pathlib import Path

def read(path):
    return Path(path).read_text()

def body(source, signature):
    """The body of the first function whose declaration contains `signature` (up to the next line indented as deep as it)."""
    start = source.find(signature)
    if start < 0:
        return ''
    line_start = source.rfind('\n', 0, start) + 1
    indent = len(source[line_start:start]) - len(source[line_start:start].lstrip())
    end = re.compile(r'\n' + ' ' * indent + r'\}').search(source, start)
    return source[start:end.end()] if end else source[start:]

failures = []
def require(condition, why):
    if not condition:
        failures.append(why)

router = read('Sources/SrtFlow/AIToolRouter.swift')
save_at = router.find('let saved = await AIProjectTools.saveIfNeverSaved(project, after: result)')
report_at = router.find('AIRoundVersions.reporting(project, in: saved)')
require(router.count('AIRoundVersions.reporting(') == 1 and 0 <= save_at < report_at,
        'the router reports the round\'s starting version once, after a never-saved project got its file (else it is never named)')
require('case .undo: return try await AIProjectTools.undo(args, project)' in router, 'undo is dispatched as the async tool (version= loads a file)')

tools = body(read('Sources/SrtFlow/AIProjectTools.swift'), 'static func undo(')
version_at = tools.find('AIRoundVersions.goBack(args, project)')
round_at = tools.find('args.bool("round")')
require(0 <= version_at < round_at, 'undo hands version= to AIRoundVersions.goBack before the round / steps branches')
require('AIRoundVersions.statusJSON(project)' in read('Sources/SrtFlow/AIProjectTools.swift'), 'get_status lists the saved versions')

round_file = read('Sources/SrtFlow/AIRound.swift')
require('settleBeforeVersion()' in body(round_file, 'func noteChange('), 'the round\'s first change saves its starting point (noteChange)')
require('saveEndVersion()' in body(round_file, 'func finishRound('), 'the end of a round saves what it made (finishRound)')
require('saveEndVersion()' in body(round_file, 'func stop('), 'Stop saves what the round made')
require('self.finishRound()' in body(round_file, 'private func scheduleRoundEnd('), 'the idle timer ends the round through finishRound')
undo_round = body(round_file, 'func undoRound(')
keep_at = undo_round.find('save(project.state, kind: .beforeGoingBack)')
restore_at = undo_round.find('project.restoreTimeline(snapshot)')
require(0 <= keep_at < restore_at, '"Undo This Round" keeps the state it leaves as a version before restoring')

store = read('Sources/SrtFlow/ProjectVersionStore.swift')
go_back = body(store, 'func goBack(to requested: String)')
require('AIUndoGrouping.step(project.effectiveUndoManager) { project.restoreTimeline(loaded.timeline) }' in go_back,
        'going back is one undo step restored as is (restoreTimeline, its own group after the await)')
require('.perform(' not in go_back and '.perform {' not in go_back, 'going back never goes through perform (magnet and linkage would change the version)')
require(0 <= go_back.find('save(leaving, kind: .beforeGoingBack)') < go_back.find('project.restoreTimeline('), 'going back saves the state it leaves first')
require('VideoEditProjectIO.load(from: url)' in go_back, 'going back reads the version with the project loader (format gate, migrations, relinking)')
require('ProjectVersionStore.forget(project)' in body(read('Sources/SrtFlow/AISession.swift'), 'func forgetRound('),
        'closing a project forgets its version store')

writers = sorted(str(p) for p in Path('Sources').rglob('*.swift') if 'VideoEditProjectIO.save(' in p.read_text())
require(writers == ['Sources/SrtFlow/ProjectFileWriter.swift', 'Sources/SrtFlow/ProjectVersionStore.swift'],
        'only ProjectFileWriter (a project\'s own file, off the main thread) and ProjectVersionStore write project files: ' + ', '.join(writers))

menu = body(read('Sources/SrtFlow/VideoEditProjectBar.swift'), 'struct VideoEditProjectMenu')
require('Button("Versions…") { showsVersions = true }' in menu, 'the project menu has Versions…')
require('.sheet(isPresented: $showsVersions) { ProjectVersionsSheet(project: project).appLanguage() }' in menu,
        'Versions… opens the sheet in the in-app language')
require('scripts/check-project-versions.sh' in read('scripts/check-all.sh'), 'the full-App check runs in check-all')

if failures:
    for failure in failures:
        print('✗ ' + failure)
    raise SystemExit(1)
print('   ✓ saved versions: router hook after the save, undo version=, three save points, one-step restore, get_status, menu, one writer')
PY
