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

if [ "${FAILED}" = "0" ]; then
  echo "✓ open-projects-wiring：没有单例、工程只由注册表建、撤销不退到键窗口、代号全 App 不重号、退出问每个工程、录屏落回开录的工程"
fi
exit "${FAILED}"
