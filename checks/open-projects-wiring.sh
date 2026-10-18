#!/usr/bin/env bash
# 扫描守卫：剪辑工程不再是单例（2026-10-17，docs/architecture/open-projects.md）。
#
# 由来（docs/plans/2026-10-17-multi-project-ai-editing.md 第 ① 刀）：AI 一个会话要同时剪几个工程，先得能开几个。
# 以前工程是 `VideoEditProject.shared`，菜单、拷贝粘贴、退出、录屏入轨、试听让路都直接找它；撤销没有窗口交过来时退到
# 「键窗口的撤销管理器」—— 几个工程开着时那是别的工程的窗口，改动会登记进别人的撤销栈；工程代号每个实例各从 0 数，
# 被当成身份跨对象比较（AI 会话记的工程、撤销这一轮、录屏请求……）时两个工程会撞号。
# 这里钉住拆完之后的样子，免得哪条新代码又摸回单例。
#
# 用法：checks/open-projects-wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAILED=0

fail() {
  echo "✗ open-projects-wiring：$1" >&2
  FAILED=1
}

PROJECT=Sources/SrtFlow/VideoEditProject.swift
REGISTRY=Sources/SrtFlow/OpenProjects.swift
APP=Sources/SrtFlow/SrtFlowApp.swift
RECORDING=Sources/SrtFlow/ScreenRecordingCoordinator.swift
for f in "$PROJECT" "$REGISTRY" "$APP" "$RECORDING"; do
  [ -f "$f" ] || fail "找不到 ${f}：文件挪走了，这条守卫会扫个空 —— 同步改这里"
done

# 只看真代码（行尾注释、整行注释里提到不算）。
code_hits() {
  grep -rn --include='*.swift' "$1" "${@:2}" | sed 's,//.*,,' | grep "$1" || true
}

# 1. 全仓不许再有单例：工程由 OpenProjects 持有，谁要工程就从它（或调用方传进来的那一个）拿。
SINGLETON="$(code_hits 'VideoEditProject\.shared' Sources)"
if [ -n "${SINGLETON}" ]; then
  fail "又出现了 VideoEditProject.shared（工程不再是单例：主窗口那个是 OpenProjects.shared.primary，菜单作用在 focused 上）："
  printf '%s\n' "${SINGLETON}" >&2
fi
# 工程只许注册表建：它发短 id、管同时开几个；别处自己 new 一个出来，注册表就不知道它开着。
BUILDERS="$(code_hits 'VideoEditProject(' Sources | grep -v "^${REGISTRY}:" || true)"
if [ -n "${BUILDERS}" ]; then
  fail "注册表以外的地方建了 VideoEditProject（只许 OpenProjects 建）："
  printf '%s\n' "${BUILDERS}" >&2
fi

# 2. 撤销：没有窗口交过来时用工程自己的，不许退到键窗口的（那可能是别的工程的窗口）。
UNDO_BODY="$(awk '/var effectiveUndoManager: UndoManager\? \{/,/^    \}/' "$PROJECT" | sed 's,//.*,,')"
if [ -z "${UNDO_BODY}" ]; then
  fail "${PROJECT} 里找不到 effectiveUndoManager（改名了就同步改这里）"
elif grep -q 'keyWindow' <<<"${UNDO_BODY}" || ! grep -q 'ownUndoManager' <<<"${UNDO_BODY}"; then
  fail "effectiveUndoManager 退到了键窗口的撤销管理器、或没退到工程自己的 ownUndoManager：几个工程开着时改动会登记进别的工程的撤销栈"
fi

# 3. 工程代号全 App 一个计数：建工程、换工程都从 DocumentGenerations 拿新号，不许各自 +1。
if [ "$(grep -c 'documentGeneration = DocumentGenerations.next()' "$PROJECT" || true)" -ne 2 ]; then
  fail "${PROJECT} 的工程代号没有在建工程和换工程两处都从 DocumentGenerations.next() 拿（几个工程会撞号、被当成同一个）"
fi
if [ -n "$(sed 's,//.*,,' "$PROJECT" | grep -E 'documentGeneration[[:space:]]*(&?\+=|=[[:space:]]*0)' || true)" ]; then
  fail "${PROJECT} 里工程代号又在自己数（+= / = 0）：要从 DocumentGenerations.next() 拿"
fi

# 4. 退出：每个开着的工程都要落定（App 的退出和录屏收尾之后的退出两条路）。
for f in "$APP" "$RECORDING"; do
  grep -q 'OpenProjects.shared.all.allSatisfy { $0.prepareToCloseDocument() }' "$f" \
    || fail "${f} 退出时没有让每个开着的工程都落定（只问一个的话，别的工程的改动和「存不存」都被跳过）"
done

# 5. 录屏落回开录的那个工程，不是「此刻主窗口里的那个」。
grep -q 'targetProject = project' "$RECORDING" \
  || fail "${RECORDING} 开录时没记下要落进哪个工程（targetProject）"
grep -q 'let project = targetProject ?? OpenProjects.shared.primary' "$RECORDING" \
  || fail "${RECORDING} 录完入轨没落回开录的那个工程"

# ── 工程窗口（第 ①b 刀）────────────────────────────────────────────────────────────
WINDOW=Sources/SrtFlow/ProjectWindowController.swift
VIEW=Sources/SrtFlow/VideoEditView.swift
DOCUMENT=Sources/SrtFlow/VideoEditProjectDocument.swift
for f in "$WINDOW" "$VIEW" "$DOCUMENT"; do
  [ -f "$f" ] || fail "找不到 ${f}：文件挪走了 —— 同步改这里"
done

# 6. 工程窗口的撤销管理器是工程自己的：delegate 交出 ownUndoManager，而且**先挂 delegate 再放内容**
#    （窗口头一回被问时才问 delegate、之后记住；SwiftUI 的内容一放进来就会问 —— 2026-10-17 冒烟撞上的）。
grep -q 'func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { project.ownUndoManager }' "$WINDOW" \
  || fail "${WINDOW} 的 delegate 没交出工程自己的撤销管理器（⌘Z 会撤到窗口自己建的那一个）"
DELEGATE_AT="$(grep -n 'window.delegate = self' "$WINDOW" | head -1 | cut -d: -f1 || true)"
CONTENT_AT="$(grep -n 'window.contentView = host' "$WINDOW" | head -1 | cut -d: -f1 || true)"
if [ -z "${DELEGATE_AT}" ] || [ -z "${CONTENT_AT}" ] || [ "${DELEGATE_AT}" -gt "${CONTENT_AT}" ]; then
  fail "${WINDOW} 不是先挂 delegate（第 ${DELEGATE_AT:-?} 行）再放内容（第 ${CONTENT_AT:-?} 行）：SwiftUI 先问到窗口自己的撤销管理器就记住了"
fi
# 主窗口的撤销管理器只交给主窗口里的那个工程；工程窗口里的工程不许被它盖掉。
grep -q 'if host == .mainWindow { project.undoManager = undoManager }' "$VIEW" \
  || fail "${VIEW} 不分主窗口 / 工程窗口就把环境里的撤销管理器交给工程"

# 7. 按键只认自己窗口里的：几个工程窗口各挂一个本地按键监听，不分的话按一次空格每个工程都开播。
grep -q 'guard event.window === TimelineScrollGeometry.live(for: project)?.window else { return event }' "$VIEW" \
  || fail "${VIEW} 的按键监听没先认「是不是我这个窗口的按键」"

# 8. 录屏的框弹在开录的那个工程的窗口里、崩溃恢复只在主窗口（不然每个窗口各弹一个）。
grep -q '.modifier(ScreenRecordingSheets(project: project, host: host))' "$VIEW" \
  || fail "${VIEW} 的录屏框没走 ScreenRecordingSheets（按工程 / 主窗口分）"

# 9. 关 / 换一个工程只停它自己的活：转写、翻译按代号认，upscale 按代号认；关工程要停引擎（喂样线程自己留着自己）。
grep -q 'TranslationJobCoordinator.shared.cancel(ifOwnedBy: previous)' "$PROJECT" \
  || fail "${PROJECT} 换工程时取消的不是「这个工程那一次打开」的翻译"
grep -q 'UpscaleActivity.shared.cancelAll(projectGeneration: closing)' "$DOCUMENT" \
  || fail "${DOCUMENT} 换工程时把所有工程的 upscale 都作废了（只许作废这一个工程的）"
TEARDOWN="$(awk '/enum ProjectTeardown/,/^}/' "$REGISTRY")"
for call in 'project.audioEngineHost.stop()' 'project.invalidateDocumentGeneration()' 'UpscaleActivity.shared.cancelAll(projectGeneration: closing)'; do
  grep -qF "$call" <<<"${TEARDOWN}" || fail "关工程（ProjectTeardown）没做：${call}"
done

# 10. 存盘前只让**这个工程的剪辑页**里的输入框辞职：后台工程自动存盘时去踢键窗口，会打断用户在别处正打的字。
grep -q 'guard OpenProjects.shared.editorIsKey(self) else { return }' "$DOCUMENT" \
  || fail "${DOCUMENT} 的 endPendingTextEditing 不分是不是这个工程的窗口就让键窗口的输入框辞职"

# 11. 后台工程（没有窗口，方案板 8）：不建预览（播放条目、合成、音频引擎），挂上窗口时重建一次；摘窗口只停预览、工程留着；
#     用户关掉 AI 还在剪的工程的窗口 = 转到后台（先问这一句，再走落盘关工程那条路）。
REBUILD="$(awk '/    func scheduleRebuild\(\) \{/,/^    \}/' "$PROJECT")"
[ "$(sed -n 2,3p <<<"${REBUILD}" | grep -c 'guard OpenProjects.shared.showsEditor(self) else { return }')" -eq 1 ] \
  || fail "${PROJECT} 的 scheduleRebuild 开头没挡后台工程（没有窗口也建播放条目、合成、音频引擎）"
grep -q 'guard !Task.isCancelled, generation == self.rebuildGeneration, OpenProjects.shared.showsEditor(self) else { return }' <<<"${REBUILD}" \
  || fail "${PROJECT} 的 scheduleRebuild 防抖之后没再问一次有没有窗口（摘窗口之前排上的那次重建会把条目挂回去）"
for body in 'private func place(' 'func showWindow(for project'; do
  BLOCK="$(awk -v start="$body" 'index($0, start) { on = 1 } on { print } on && /^    \}/ { exit }' "$REGISTRY")"
  ATTACH_AT="$(grep -n 'attachWindow(to: project, inFront: inFront)' <<<"${BLOCK}" | head -1 | cut -d: -f1)"
  REBUILT_AT="$(grep -n 'project.scheduleRebuild()' <<<"${BLOCK}" | head -1 | cut -d: -f1)"
  if [ -z "${ATTACH_AT}" ] || [ -z "${REBUILT_AT}" ] || [ "${ATTACH_AT}" -gt "${REBUILT_AT}" ]; then
    fail "${REGISTRY} 的 ${body}… 挂上窗口之后没重建预览（开的时候它还没窗口，重建被跳过了）"
  fi
done
CLOSED="$(awk '/    private func windowClosed\(/,/^    \}/' "$REGISTRY")"
STOP_AT="$(grep -n 'ProjectTeardown.stopPreview(project)' <<<"${CLOSED}" | cut -d: -f1)"
FINISH_AT="$(grep -n 'finishClosing(project)' <<<"${CLOSED}" | cut -d: -f1)"
if [ -z "${STOP_AT}" ] || [ -z "${FINISH_AT}" ] || [ "${STOP_AT}" -gt "${FINISH_AT}" ] || ! grep -q 'return' <<<"${CLOSED}"; then
  fail "${REGISTRY} 的 windowClosed：工程转到后台时要只停预览、不收拾工程（keepsProject 那一支先 return）"
fi
CONTROLLER=Sources/SrtFlow/ProjectWindowController.swift
SHOULD="$(awk '/    func windowShouldClose\(/,/^    \}/' "$CONTROLLER")"
KEEP_AT="$(grep -n 'OpenProjects.shared.aiIsEditing(project)' <<<"${SHOULD}" | cut -d: -f1)"
PREPARE_AT="$(grep -n 'project.prepareToCloseDocument()' <<<"${SHOULD}" | cut -d: -f1)"
if [ -z "${KEEP_AT}" ] || [ -z "${PREPARE_AT}" ] || [ "${KEEP_AT}" -gt "${PREPARE_AT}" ]; then
  fail "${CONTROLLER} 关窗时没先问「AI 还在剪吗」：AI 在剪的工程会被关掉（应转到后台）"
fi

# 12. 用户新建 / 打开工程都经 userNew / userOpen：这个窗口里的工程 AI 正在剪，就开到新的工程窗口里、不换掉 AI 的工程（方案 A.5 的做法）。
#     直接调 `.newProject()` / `.openProject(at:` 的只许是注册表、AI 的开 / 建工具、开发 / 冒烟钩子。
DIRECT="$(code_hits '\.newProject()\|\.openProject(at:' Sources/SrtFlow \
  | grep -v '^Sources/SrtFlow/OpenProjects.swift:\|^Sources/SrtFlow/AIProjectOpenTools.swift:\|^Sources/SrtFlow/DevHooks.swift:\|^Sources/SrtFlow/SmokeDriver.swift:' || true)"
[ -z "${DIRECT}" ] || fail "这些地方绕过了 userNew / userOpen 直接换工程（AI 正在剪的工程会被换掉）：${DIRECT}"
grep -q 'Task { await OpenProjects.shared.userOpen(url, from: self) }' "$DOCUMENT" \
  || fail "${DOCUMENT} 的「打开工程…」面板没经 userOpen"
# 13. 主窗口侧边栏有「AI 在剪的工程」（后台工程唯一的停止 / 打开窗口 / 关掉），而且**不套 `.equatable()`**：
#     List 把 EquatableView 当一行，这一节只画出标题、工程那几行全丢（docs/bugfixes/2026-10-18-ai-projects-sidebar-rows-never-shown.md；
#     这里原来按字面钉着带 `.equatable()` 的写法，把错的钉成了对的）。通用的那条在 checks/list-section-not-equatable.sh。
SIDEBAR_LINE="$(grep -n 'AIProjectsSidebarSection(isCompact: isSidebarCompact)' Sources/SrtFlow/MainWindowView.swift || true)"
if [ -z "${SIDEBAR_LINE}" ]; then
  fail "主窗口侧边栏没挂 AIProjectsSidebarSection：后台工程没有地方停、没有地方关"
elif grep -c 'equatable' <<<"${SIDEBAR_LINE}" >/dev/null; then
  fail "主窗口侧边栏的 AIProjectsSidebarSection 套了 .equatable()：List 里整节只剩标题，工程那几行不出来"
fi
# 14. 导出器全 App 一个：编辑窗口和导出面板里的进度、停止、成片只给发起导出的那个工程（`exporter.belongs(to: project)`），
#     开始导出的两条路（面板、AI）都带上是哪个工程（`export(for: project`）。不然 p1 的窗口里显示、还能停掉 p3 的 AI 导出
#     （docs/bugfixes/2026-10-18-export-progress-shown-in-every-project-window.md）。
#     状态视图（VideoEditExportStatus）整个包在 `if exporter.belongs(to: project) {` 里，单独查。
for file in Sources/SrtFlow/VideoEditView.swift Sources/SrtFlow/VideoEditExportSheet.swift; do
  [ -f "${file}" ] || { fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"; continue; }
  BARE="$(grep -nE 'if exporter\.isExporting[[:space:]]*\{' "${file}" || true)"
  [ -z "${BARE}" ] || fail "${file} 只看「导出器在导」就显示进度 / 停止，没问是不是这个工程的（别的窗口会显示、能停掉它）：${BARE}"
done
[ "$(grep -c 'if exporter.belongs(to: project) {' Sources/SrtFlow/VideoEditExportStatus.swift || true)" -eq 1 ] \
  || fail "导出面板的进度 / 报错 / 成片没按工程分（VideoEditExportStatus 里应先问 exporter.belongs(to: project)）"
UNOWNED="$(awk '
  /exporter\.export\(/ { if ($0 ~ /export\(for: project,/) next; at = FILENAME ":" FNR; pending = 1; next }
  pending { if ($0 !~ /^[[:space:]]*for: project,/) print at; pending = 0 }
' Sources/SrtFlow/*.swift)"
[ -z "${UNOWNED}" ] || fail "这些地方开始导出时没说是哪个工程（exporter.export(for: project, …)）：${UNOWNED}"

if [ "${FAILED}" = "0" ]; then
  echo "✓ open-projects-wiring：没有单例、工程只由注册表建、撤销不退到键窗口、代号全 App 不重号、退出问每个工程、录屏落回开录的工程；"
  echo "  工程窗口：撤销管理器是工程自己的且先挂 delegate、按键只认自己的窗口、录屏的框按工程分、关 / 换工程只停自己的活且停引擎、存盘不踢别处的输入框；"
  echo "  后台工程：不建预览、挂窗口才重建、摘窗口只停预览、AI 在剪的工程关窗转到后台；用户新建 / 打开经 userNew / userOpen；侧边栏有 AI 在剪的工程"
  echo "  导出器全 App 一个：进度 / 停止 / 成片只给发起导出的那个工程的窗口和面板"
fi
exit "${FAILED}"
