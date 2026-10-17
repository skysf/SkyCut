#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：AI 的调用在 App 里怎么走 —— 路由的撤销分组、
# 窗口什么时候摆到前面、几个会话共用一个 App 时的工程核对、App 卡住时的「探一下」和放弃。都是扫描，秒级。
# 2026-10-14 从 check-mcp.sh 拆出来（那个文件超过了 600 行的上限，docs/architecture/coding-standards.md）。
# 约束见 docs/architecture/ai-control-mcp.md 第三节、第四节第 1、4、46 条。

echo "==> 路由：改工程的工具各是一步撤销"
# 不显式分组的话 AI 的每一步都堆进同一组，⌘Z 一按全部退光；手动关自动开的那一组又会让下一次登记
# 抛异常、App 闪退（docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md）。
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
for tool in setKeyframes setTrack splitClip deleteItems duplicateItems setTransition setText setShape setFilter setCanvas; do
  if [ "$(grep -cE "case \\.${tool}: return try AIUndoGrouping\\.step\\(undo\\)" "${ROUTER}" || true)" -ne 1 ]; then
    echo "✗ ${ROUTER} 里 ${tool} 没包在 AIUndoGrouping.step 里：它的改动会和别的步并成一步撤销" >&2
    exit 1
  fi
done
# edit_clip 先 await 看画面（去黑边、对准主体），再把同步的提交包起来：包的那一段不许有 await。
if [ "$(grep -cE 'return try AIUndoGrouping\.step\(undo\) \{ try AIClipTools\.apply\(plan, project\) \}' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 里 edit_clip 的提交没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
# edit_subtitles 给了字体要先等字体表（await），同样只把同步的提交包起来。
if [ "$(grep -cE 'return try AIUndoGrouping\.step\(undo\) \{ try AISubtitleTools\.edit\(args, style: style, project\) \}' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 里 edit_subtitles 的提交没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
for tool in AISpeechCutTool AIBeatCutTool AIVoiceoverTool; do
  # 先赋给变量再比较：直接写在 [ "$(…)" ] 里，CI 的 /bin/bash 3.2 会把 "…{ … , … }…" 当花括号展开、拆成两个词，
  # [ 报 too many arguments、if 走 else —— 这条到 2026-10-03 为止从来没生效过
  # （docs/bugfixes/2026-10-03-check-mcp-undo-scan-split-by-brace-expansion.md，checks/shell-brace-in-nested-quotes.sh 钉着）。
  wrapped="$(grep -cE "return try AIUndoGrouping\\.step\\(undo\\) \\{ try ${tool}\\.apply\\(plan, project\\) \\}" "${ROUTER}" || true)"
  if [ "${wrapped}" -ne 1 ]; then
    echo "✗ ${ROUTER} 里 ${tool} 的提交没包在 AIUndoGrouping.step 里" >&2
    exit 1
  fi
done
if [ "$(grep -cE 'AIUndoGrouping\.step\(project\.effectiveUndoManager\)' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  echo "✗ add_clips 那一次 perform 没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
# freeze_frame 抽帧转码要 await：把「提交那一下」包进 AIUndoGrouping.step 交给定格去做。
if [ "$(grep -c 'AIUndoGrouping.step(undo, body)' Sources/SrtFlow/AIClipTools.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'commit {' Sources/SrtFlow/VideoEditFreezeFrame.swift || true)" -ne 1 ]; then
  echo "✗ freeze_frame 的提交没包进 AIUndoGrouping.step（或定格没把 perform 交给 commit）" >&2
  exit 1
fi
MANUAL="$(grep -lE 'endUndoGrouping\(\)' Sources/SrtFlow/AI*.swift | grep -v 'AIUndoGrouping.swift' || true)"
if [ -n "${MANUAL}" ]; then
  echo "✗ 这些文件自己在关撤销组：${MANUAL}（手动关掉按事件自动开的那一组，下一次登记就抛异常、App 闪退）" >&2
  exit 1
fi
# 一处登记落在 step 外面就够把后面全并成一步：App 在后台收不到事件，按事件自动开的那一组关不上，之后每个 step
# 看见「开着一组」都嵌进去（2026-09-27 冒烟：add_clips 先挂字幕再进 step，撤一步整条时间线空了，
# docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md）。add_clips 挂字幕必须在放素材的那个 step 里：
ADD_STEP="$(awk '/try AIUndoGrouping\.step\(project\.effectiveUndoManager\) \{/,/^        \}$/' Sources/SrtFlow/AITimelineTools.swift)"
if [ "$(grep -c 'project.attachSubtitle(' <<<"${ADD_STEP}" || true)" -ne 1 ] \
   || [ "$(grep -c 'project.attachSubtitle(' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  echo "✗ add_clips 挂字幕不在放素材的那个 AIUndoGrouping.step 里：在后台的 App 里之后 AI 的每一步都会并进同一组" >&2
  exit 1
fi
# 不是用户事件引起的异步落账（AI 起的生成字幕 / 翻译结束时、静帧转换失败删占位块）也各包一层：落账那一行的上一行是 step。
for pair in "Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift|project.replaceSubtitleForGeneration(" \
            "Sources/SrtFlow/SubtitleGen/SubtitleTranslationService.swift|project.applyTranslations(" \
            "Sources/SrtFlow/AIUpscaleTool.swift|project.applyUpscale("; do
  file="${pair%%|*}"
  call="${pair#*|}"
  if [ "$(grep -cF "${call}" "${file}" || true)" -ne 1 ] \
     || ! grep -q 'AIUndoGrouping.step(project.effectiveUndoManager) {' <<<"$(grep -B1 -F "${call}" "${file}" | head -1)"; then
    echo "✗ ${file} 的异步落账（${call}）没包在 AIUndoGrouping.step 里：AI 起的任务一结束，之后的改动撤一步全退" >&2
    exit 1
  fi
done
if grep -nE '^ +perform\(rebuildsPreview: false\) \{ \$0\.remove\(clipID\) \}' Sources/SrtFlow/VideoEditProject.swift; then
  echo "✗ 静帧转换失败删占位块的 perform 没包在 AIUndoGrouping.step 里（异步落账）" >&2
  exit 1
fi
echo "   ✓ 10 个同步的改动工具 + edit_clip / edit_subtitles / cut_speech / cut_to_beat / add_voiceover / freeze_frame 的提交 + add_clips（连同挂字幕）都各是一步；生成字幕、翻译写回、"
echo "     删占位块这些异步落账也各是一步；没人手动关撤销组"

echo "==> 看得见：窗口只在开工程时摆一次"
# 每一步都 orderFrontRegardless 的话，用户在别的 App 里干活时 SrtFlow 一步一跳、盖住他的窗口（docs/plans/2026-09-27-mcp.md 第 32 条）；
# 2026-10-17 起几个工程同时剪，「每一轮开始摆一次」也会乱成一团 —— 只在开工程时摆一次（方案板 3）：开 / 建进主窗口、会话第一次在主窗口
# 那个（这一次打开）上做要摆剪辑页的事（真摆了才记）、set_view visible。路由不再看「这一轮是不是刚开始」。
PRESENTER="Sources/SrtFlow/AIEditorPresenter.swift"
if [ "$(grep -c 'startsNewRound' "${ROUTER}" || true)" -ne 0 ] \
   || [ "$(grep -c 'let visible = AISession.shared.viewMode(for: project) == .visible' "${ROUTER}" || true)" -ne 1 ] \
   || [ "$(grep -cF 'let firstShow = visible && !recordingScreen && AISession.shared.claimFirstShow(of: project, session: call.session)' "${ROUTER}" || true)" -ne 1 ] \
   || [ "$(grep -c 'prepareEditor(project: project, bringForward: firstShow)' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 摆主窗口不是只在「这个会话第一次在它上面做要摆剪辑页的事」时（又按一轮一轮摆，或者不看这个工程的看法）" >&2
  exit 1
fi
RAISE_BLOCK="$(awk '/if bringForward \{/,/^            \}/' "${PRESENTER}")"
# 第三处是「窗口被关了、开回来」那一下（placeReopenedWindow）：看得见时摆前面，后台 / 录屏时放最后面。
REOPEN_BLOCK="$(awk '/private static func placeReopenedWindow\(/,/^    \}/' "${PRESENTER}")"
# 只数代码行（注释里提到它不算）：正好两处，if bringForward 里一处、开回来那一下一处。
if [ "$(grep -v '^[[:space:]]*//' "${PRESENTER}" | grep -c 'orderFrontRegardless' || true)" -ne 2 ] \
   || [ "$(grep -c 'window.orderFrontRegardless()' <<<"${RAISE_BLOCK}" || true)" -ne 1 ] \
   || [ "$(grep -c 'window.orderFrontRegardless()' <<<"${REOPEN_BLOCK}" || true)" -ne 1 ]; then
  echo "✗ ${PRESENTER} 在 if bringForward 和开回来的那一下之外也把窗口摆到前面（一轮中途又会一步一跳）" >&2
  exit 1
fi
# 后台模式（方案第 7 条）：一次都不摆窗口、不跟着选中 / 挪播放头（seek 除外，它就是要给用户看那一刻）。
if [ "$(grep -c 'guard always || AISession.shared.viewMode(for: project) == .visible else { return }' "${PRESENTER}" || true)" -ne 1 ]; then
  echo "✗ ${PRESENTER} 的 reveal 在后台模式下照样选中、挪播放头" >&2
  exit 1
fi
echo "   ✓ 主窗口只在会话第一次在它上面做要摆剪辑页的事时摆；摆窗口只在 if bringForward 和开回来的那一下里；按工程的看法，后台不摆窗口、不跟着选中"

echo "==> 几个 AI 会话、几个工程：改动只落在会话自己的那个工程上"
# 2026-10-06 盲测：桌面版的会话把 App 切到了用户的工程，这边的会话接着改（docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md）；
# 2026-10-17 起一个会话一组工程（docs/plans/2026-10-17-multi-project-ai-editing.md）：路由排到这个调用之后、摆窗口 / 开一轮之前
# 定下落在哪个工程（AIProjectSessions.target），不能落就一样都不做；用到的工程回给小程序；碰工程的按工程排队；工具在 AICallContext 里跑。
CHECK_AT="$(grep -n 'switch sessions.target(' "${ROUTER}" | cut -d: -f1 || true)"
PRESENT_AT="$(grep -n 'try await AIEditorPresenter.prepareEditor(' "${ROUTER}" | cut -d: -f1 || true)"
ROUND_AT="$(grep -n 'if call.policy.startsRound { AISession.shared.round(for: project).beginIfNeeded(project: project) }' "${ROUTER}" | cut -d: -f1 || true)"
if [ -z "${CHECK_AT}" ] || [ -z "${PRESENT_AT}" ] || [ -z "${ROUND_AT}" ] \
   || [ "${CHECK_AT}" -gt "${PRESENT_AT}" ] || [ "${CHECK_AT}" -gt "${ROUND_AT}" ]; then
  echo "✗ ${ROUTER} 没在摆窗口、开一轮之前定「落在这个会话的哪个工程」（定在第 ${CHECK_AT:-?} 行、摆窗口第 ${PRESENT_AT:-?} 行）" >&2
  exit 1
fi
if [ "$(grep -cF 'let stamp = outcome.failed ? nil : outcome.stamp ?? target.map(sessions.stamp)' "${ROUTER}" || true)" -ne 1 ] \
   || [ "$(grep -c 'project: answer.project)' Sources/SrtFlow/AIBridgeServer.swift || true)" -ne 1 ]; then
  echo "✗ 路由没把这次用到 / 开关的工程回给小程序（AIBridgeServer）：小程序记不住会话的一组工程" >&2
  exit 1
fi
if [ "$(grep -cF 'return ["project:" + id]' "${ROUTER}" || true)" -lt 1 ] \
   || [ "$(grep -cF 'await tails["switch:" + call.session]?.value' "${ROUTER}" || true)" -ne 1 ] \
   || [ "$(grep -cF 'AICallContext.$current.withValue(context)' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 没按工程排队、不带 project 的没先等这个会话的开 / 建 / 关，或工具没在 AICallContext 里跑（几个子代理会串文件夹）" >&2
  exit 1
fi
if [ "$(grep -c 'sessionProject.stamp(MCPBridge.Request(' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'sessionProject.note(tool: tool, response: response)' Sources/SrtFlowMCP/AppConnection.swift || true)" -ne 1 ]; then
  echo "✗ 小程序发请求没带会话的工程，或收到回答没记下来（Sources/SrtFlowMCP/AppConnection.swift）" >&2
  exit 1
fi
echo "   ✓ 路由第 ${CHECK_AT} 行定工程（摆窗口在第 ${PRESENT_AT} 行之后）；用到的工程回给小程序；按工程排队、在调用上下文里跑；小程序带着、记着"

echo "==> 停止按工程：用户在一个工程上按停止，只拒绝落在它上面的调用、只取消跟着它停的任务"
# 2026-10-17 用户定（docs/plans/2026-10-17-multi-project-ai-editing.md 板 4、E 节）：剪 5 条时停一条，别的照剪。
STOP_AT="$(grep -n 'if let refusal = round.refusalAfterStop() {' "${ROUTER}" | cut -d: -f1 || true)"
if [ -z "${STOP_AT}" ] || [ "${STOP_AT}" -lt "${CHECK_AT}" ] || [ "${STOP_AT}" -gt "${PRESENT_AT}" ]; then
  echo "✗ ${ROUTER} 没在定了工程之后、摆窗口之前查这个工程停没停（停一个工程会挡住别的、或者停了还摆窗口）" >&2
  exit 1
fi
if grep -n 'func cancelAll' Sources/SrtFlow/AIJobs.swift || grep -rn 'AISession\.shared\.refusalAfterStop\|AISession\.shared\.phase' Sources/SrtFlow; then
  echo "✗ 又有了全 App 一份的停止（AIJobs.cancelAll / AISession 的 phase）：停一个工程会停掉所有工程" >&2
  exit 1
fi
if [ "$(grep -c 'stopsWith: project.shortID' "${ROUTER}" || true)" -ne 1 ]; then
  echo "✗ ${ROUTER} 起任务时没记「停哪个工程时跟着停」（不碰工程的任务停不掉）" >&2
  exit 1
fi
if [ "$(grep -cF 'if let owner = job.session, owner != (AICallContext.current?.session ?? AIProjectSessions.anonymous) {' Sources/SrtFlow/AIExportTools.swift || true)" -ne 1 ]; then
  echo "✗ cancel_job 能取消别的会话起的任务（几个会话共用一个 App 时会停掉别人的导出，方案 B.5）" >&2
  exit 1
fi
echo "   ✓ 第 ${STOP_AT} 行按工程查停止；没有全 App 一份的停止；任务记着跟哪个工程停；cancel_job 只取消自己会话的"

echo "==> App 卡住的时候：探一下不经主线程、放弃了的不做、主窗口开得回来"
# 2026-10-06 盲测：App 卡死时 AI 每个调用干等 120 秒、只拿到「read: Resource temporarily unavailable」；拉起来之后
# open_project 报「主窗口关着」（docs/bugfixes/2026-10-14-ai-calls-time-out-silently-when-app-hangs.md）。
BRIDGE="Sources/SrtFlow/AIBridgeServer.swift"
PROBE_BODY="$(awk '/private func probe\(_ request: MCPBridge.Request\)/,/^    \}/' "${BRIDGE}")"
PROBE_ON_MAIN="$(grep -cE 'waitForMainActor|MainActor' <<<"${PROBE_BODY}" || true)"
if [ "$(grep -cF 'case MCPBridge.probeTool: response = probe(request)' "${BRIDGE}" || true)" -ne 1 ] \
   || [ -z "${PROBE_BODY}" ] || [ "${PROBE_ON_MAIN}" -ne 0 ]; then
  echo "✗ ${BRIDGE} 的「探一下」没在收发线程上当场答（经了主线程，主线程卡死时就答不上来）" >&2
  exit 1
fi
# 小程序要 App 的工具清单（App 升级过、会话还是升级前开的）：同样在收发线程上当场答、不经主线程
#（docs/bugfixes/2026-10-14-stale-helper-tool-list.md）。
if [ "$(grep -cF 'case MCPBridge.catalogTool: response = MCPBridge.Response(id: request.id, result: MCPCatalogSync.catalogResult())' "${BRIDGE}" || true)" -ne 1 ]; then
  echo "✗ ${BRIDGE} 不在收发线程上答小程序要的工具清单（catalogTool）：App 升级后旧小程序换不上新清单" >&2
  exit 1
fi
if [ "$(grep -cF 'if MCPUnixSocket.peerClosed(fd) { calls.abandon(id) }' "${BRIDGE}" || true)" -ne 1 ] \
   || [ "$(grep -cF 'await AIToolRouter.shared.handle(request, begin: { calls.begin(id) })' "${BRIDGE}" || true)" -ne 1 ]; then
  echo "✗ ${BRIDGE} 没在小程序断开时放弃还没开始的调用，或没把「还做不做」交给路由：App 缓过来后会照做 AI 已经当作失败的调用" >&2
  exit 1
fi
BEGIN_AT="$(grep -n 'guard begin() else {' "${ROUTER}" | cut -d: -f1 || true)"
PROJECT_AT="$(grep -n 'switch sessions.target(' "${ROUTER}" | head -1 | cut -d: -f1 || true)"
if [ -z "${BEGIN_AT}" ] || [ -z "${PROJECT_AT}" ] || [ "${BEGIN_AT}" -gt "${PROJECT_AT}" ]; then
  echo "✗ ${ROUTER} 的 execute 没在一开始问「还做不做」（第 ${BEGIN_AT:-?} 行）" >&2
  exit 1
fi
if [ "$(grep -cF 'while mainWindow() == nil, openMainWindow == nil, Date() < deadline {' "${PRESENTER}" || true)" -ne 1 ] \
   || ! grep -q 'window.orderBack(nil)' <<<"${REOPEN_BLOCK}" \
   || [ "$(grep -cF 'let _ = AIEditorPresenter.noteMenuOpenWindow(openWindow)' Sources/SrtFlow/SrtFlowApp.swift || true)" -ne 1 ]; then
  echo "✗ 主窗口开不回来：没等刚启动的窗口、开回来的窗口后台时没放到最后面、或菜单里没把「打开主窗口」交出来" >&2
  exit 1
fi
# 报错里叫用户按的快捷键要和菜单里「Edit Video」那一项一致（以前写着 Command-3，那是烧录字幕）。
EDIT_KEY="$(grep -A1 'SectionButton(title: "Edit Video", section: .videoEdit)' Sources/SrtFlow/SrtFlowApp.swift | grep -oE 'keyboardShortcut\("[0-9]"' | grep -oE '[0-9]' || true)"
if [ -z "${EDIT_KEY}" ] || [ "$(grep -cF "static let editVideoShortcut = \"Command-${EDIT_KEY}\"" "${PRESENTER}" || true)" -ne 1 ]; then
  echo "✗ ${PRESENTER} 的 editVideoShortcut 和菜单里 Edit Video 的快捷键（Command-${EDIT_KEY:-?}）对不上" >&2
  exit 1
fi
echo "   ✓ 探一下当场答、断开即放弃、路由先问还做不做；刚启动等窗口、开回来按看法放、菜单交出打开动作；快捷键 Command-${EDIT_KEY} 对得上"
