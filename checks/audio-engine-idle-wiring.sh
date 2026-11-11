#!/usr/bin/env bash
# 扫描守卫：预览的音频引擎不是一直开着的（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md，
# 长期约束 docs/architecture/audio-engine.md 第二节第 11 条）。
#
# 图开着就占着声卡：coreaudiod 替它拦着系统空闲睡眠，App Nap 也不生效。2026-10-01 到 11-11 图从第一次建预览起一直开到
# 退出。这几条钉住「什么时候停、怎么再起」的接线（规矩本身、停过再起播放头不跳在 scripts/check-audio-engine.sh 第 15 组真跑）：
#   1. 宿主把引擎交给管空闲的那一位（keep），换配置之后让它看一眼（reconcile），收引擎先让它放手（release）；
#   2. 没有东西可预览了（时间线空了、换工程）整个引擎收掉：unloadPreview = 卸片 + audioEngineHost.stop()；
#   3. 停着 2 分钟没人用才停（数字是用户定的），没有声音的时间线不开；
#   4. 用户回来了先把图起好（wake 只经后台那条队列，不占主线程）；时钟要出声时图还停着就当场起、等它起来再开播
#      （recoverIfNeeded 先等后台那一次、再认「故意停的」；没有声音不起）—— 不许让播放头先按 host 时间空走：那一截会被跳过；
#   5. 图刚起 / 停着时发的在播锚点是待钉的（不许写死「采样时间从 0 起」）；「时钟有没有数」那个标志先写数、再 release 发布，
#      读的那边 acquire（relaxed 不保证读到 true 时那几个数已经写好）；
#   6. 播到头由声音主时钟自己按总长收尾（停声音、停画面、播放头钉在总长上），在尽头再按播放不开播；
#      **不听播放器的「播到头」通知**（会晚到、会排到下一轮才处理，到了头的播放器也不会再发第二次）；
#   7. 用户回到 SkyCut 就算（变成活动的 App、窗口变成主 / 键窗口、发给 SkyCut 的鼠标和键盘事件），宿主听「用户回来了」；
#   8. 停图 / 起图的那句日志不在主线程上写；
#   9. 后台起图没起来：图还是故意停着的样子（喂样线程歇回去、不留计时器、不每看一眼就重试、只在真停下来时记「停图」）。
#  10. 一个判断只读一次图的状态（原子的，后台随时改）：「在跑或者正在起」在取出来的值上判。
#
# 用法：checks/audio-engine-idle-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="Sources/SrtFlow/VideoEditProjectAudioMix.swift"
ENGINE="Sources/SrtFlow/AudioEngine/TimelineAudioEngine.swift"
ANCHOR="Sources/SrtFlow/AudioEngine/PlaybackAnchor.swift"
POLICY="Sources/SrtFlow/AudioEngine/AudioEngineIdlePolicy.swift"
KEEPER="Sources/SrtFlow/AudioEngine/AudioEngineIdleKeeper.swift"
PRESENCE="Sources/SrtFlow/AppUserPresence.swift"
CLOCK="Sources/SrtFlow/VideoPreviewView.swift"
PROJECT="Sources/SrtFlow/VideoEditProject.swift"
DOCUMENT="Sources/SrtFlow/VideoEditProjectDocument.swift"
for file in "${HOST}" "${ENGINE}" "${ANCHOR}" "${POLICY}" "${KEEPER}" "${PRESENCE}" "${CLOCK}" "${PROJECT}" "${DOCUMENT}"; do
  [ -f "${file}" ] || { echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2; exit 1; }
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
# 去掉注释再比：写在注释里的不算接上了。整份先存进变量，后面一律 grep … <<<"$变量"
#（pipefail 下把管道接进 grep -q 会假红：checks/shell-pipe-grep-q.sh）。
code() { sed 's,//.*,,' "$1"; }
HOST_CODE="$(code "${HOST}")"
ENGINE_CODE="$(code "${ENGINE}")"
CLOCK_CODE="$(code "${CLOCK}")"

# 1. 宿主：新建的引擎交给 keep，复用的换完配置 reconcile，收引擎先 release。
APP="Sources/SrtFlow/SrtFlowApp.swift"
RENDER_CLOCK="Sources/SrtFlow/AudioEngine/AudioRenderClock.swift"
GRAPH_RUN="Sources/SrtFlow/AudioEngine/AudioGraphRun.swift"
SOURCE_PROTOCOL="Sources/SrtFlow/AudioEngine/PlaybackAudioSource.swift"
for file in "${APP}" "${RENDER_CLOCK}" "${GRAPH_RUN}" "${SOURCE_PROTOCOL}"; do
  [ -f "${file}" ] || { echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2; exit 1; }
done
KEEPER_CODE="$(code "${KEEPER}")"
APPLY="$(code "${HOST}" | awk '/    func apply\(_ config: AudioEngineConfig/,/^    \}/')"
REUSED="$(awk '/        if let engine \{/,/^        \}/' <<<"${APPLY}")"
grep -qF 'idle.reconcile()' <<<"${REUSED}" || fail "${HOST}：复用引擎换完配置没让管空闲的看一眼（idle.reconcile()）—— 新配置没有声音时图不会当场停"
grep -qF 'idle.keep(engine)' <<<"${APPLY}" || fail "${HOST}：新建的引擎没交给管空闲的（idle.keep(engine)）—— 图会一直开着"
grep -qF 'AppUserPresence.shared.start()' <<<"${APPLY}" || fail "${HOST}：建引擎时没开始看用户在不在（AppUserPresence.shared.start()）"
STOP="$(code "${HOST}" | awk '/    func stop\(\) \{/,/^    \}/')"
RELEASE_LINE="$({ grep -n 'idle.release()' <<<"${STOP}" || true; } | head -1 | cut -d: -f1)"
ENGINE_STOP_LINE="$({ grep -n 'engine?.stop()' <<<"${STOP}" || true; } | head -1 | cut -d: -f1)"
[ -n "${RELEASE_LINE}" ] && [ -n "${ENGINE_STOP_LINE}" ] && [ "${RELEASE_LINE}" -lt "${ENGINE_STOP_LINE}" ] \
  || fail "${HOST}：stop() 要先 idle.release() 再 engine?.stop()（不然计时器还拿着收掉的引擎）"
SUSPENDERS="$(grep -rlE '\.suspend\(\)' Sources/SrtFlow | grep -vxF -e "${KEEPER}" -e "${ENGINE}" || true)"
[ -z "${SUSPENDERS}" ] || fail "停图只许经 AudioEngineIdleKeeper（规矩只有一份）；这些文件也在调 suspend()：${SUSPENDERS}"

# 2. 没有东西可预览了：卸片 + 收引擎，时间线空了 / 换工程都走它。
UNLOAD="$(code "${HOST}" | awk '/    func unloadPreview\(\) \{/,/^    \}/')"
grep -qF 'clock.detach()' <<<"${UNLOAD}" && grep -qF 'audioEngineHost.stop()' <<<"${UNLOAD}" \
  || fail "${HOST}：unloadPreview() 要卸片（clock.detach()）并把引擎收掉（audioEngineHost.stop()）"
EMPTY_BUILD="$(code "${PROJECT}" | awk '/            guard let built else \{/,/^            \}/')"
grep -qF 'self.unloadPreview()' <<<"${EMPTY_BUILD}" \
  || fail "${PROJECT}：重建出来是空的（时间线空了）没走 unloadPreview() —— 上一个工程的引擎还开着占着声卡"
CLOSE="$(code "${DOCUMENT}" | awk '/    private func closeCurrentDocument\(\) \{/,/^    \}/')"
grep -qF 'unloadPreview()' <<<"${CLOSE}" || fail "${DOCUMENT}：换工程（closeCurrentDocument）没走 unloadPreview()"

# 3. 规矩：2 分钟；没有声音不开。
grep -qE 'var idleAfter: TimeInterval = 120$' "${POLICY}" || fail "${POLICY}：停着没人用 2 分钟停图（用户 2026-11-11 定的数，改它先问用户：短了冷着按播放容易碰上，长了 Mac 晚睡）"
grep -qF 'guard hasSound else { return false }' "${POLICY}" || fail "${POLICY}：没有声音的时间线不开图（在播也不开）"

# 4. 起回来不占调用方的线程。
WAKE="$(code "${ENGINE}" | awk '/    func wake\(\) \{/,/^    \}/')"
grep -qF 'run.startInBackground({ try start(engine) }, failed:' <<<"${WAKE}" \
  || fail "${ENGINE}：wake() 要在后台那条队列上起图（run.startInBackground）—— 在调用方的线程上起，用户回来的那一下主线程卡 0.15–0.3 秒"
RECOVER="$(code "${ENGINE}" | awk '/    func recoverIfNeeded\(\) throws -> Bool \{/,/^    \}/')"
SETTLE_LINE="$({ grep -n 'if run.state == .starting { run.settle() }' <<<"${RECOVER}" || true; } | head -1 | cut -d: -f1)"
SUSPENDED_LINE="$({ grep -n 'if run.state == .suspended {' <<<"${RECOVER}" || true; } | head -1 | cut -d: -f1)"
RUNNING_LINE="$({ grep -n 'guard !engine.isRunning else { return false }' <<<"${RECOVER}" || true; } | head -1 | cut -d: -f1)"
[ -n "${SETTLE_LINE}" ] && [ -n "${SUSPENDED_LINE}" ] && [ -n "${RUNNING_LINE}" ] \
  && [ "${SETTLE_LINE}" -lt "${SUSPENDED_LINE}" ] && [ "${SUSPENDED_LINE}" -lt "${RUNNING_LINE}" ] \
  || fail "${ENGINE}：recoverIfNeeded 要先等后台那一次起图（run.settle()）、再认「故意停的」（.suspended）、最后才看 engine.isRunning"
SUSPENDED_BRANCH="$(awk '/        if run.state == .suspended \{/,/^        \}/' <<<"${RECOVER}")"
grep -qF 'guard config.hasSound else { return false }' <<<"${SUSPENDED_BRANCH}" \
  || fail "${ENGINE}：故意停着的图只在有声音要出时才起（guard config.hasSound），没有声音的时间线按 host 时间走"
grep -qF 'try startGraph(engine)' <<<"${SUSPENDED_BRANCH}" && ! grep -qF 'wake()' <<<"${SUSPENDED_BRANCH}" \
  || fail "${ENGINE}：时钟要出声时图还停着就当场起（try startGraph(engine)），不许换成 wake() 让播放头先空走 —— 起声卡时进程本来就被拖住，先走的那一截画面和声音会被跳过"
SUSPEND="$(code "${ENGINE}" | awk '/    func suspend\(\) \{/,/^    \}/')"
grep -qF 'engine.pause()' <<<"${SUSPEND}" && grep -qF 'publishAnchor(frame, playing: wasPlaying)' <<<"${SUSPEND}" \
  || fail "${ENGINE}：suspend() 要停掉图的 IO（engine.pause()）并把在播的锚点改成按 host 时间走（publishAnchor）"
for entry in 'func replace(config new: AudioEngineConfig) {' 'func duck(_ gain: Float) {' 'func mute() {' 'func stop() {' 'func suspend() {'; do
  BODY="$(code "${ENGINE}" | awk -v start="    ${entry}" 'index($0, start) == 1 { on = 1 } on { print } on && /^    \}/ { exit }')"
  grep -qF 'run.settle()' <<<"${BODY}" || fail "${ENGINE}：${entry%% \{} 动图之前要先等后台那一次起图做完（run.settle()）"
done

# 5. 在播的锚点：时钟没数就发待钉的；不许再写死采样时间从 0 起。
PUBLISH="$(code "${ENGINE}" | awk '/    private func publishAnchor\(/,/^    \}/')"
grep -qF 'if playing, !renderClock.hasTicked {' <<<"${PUBLISH}" && grep -qF 'anchor.publish(.pending(' <<<"${PUBLISH}" \
  || fail "${ENGINE}：publishAnchor 在时钟没数时（图刚起 / 还在起 / 停着）要发待钉的锚点（.pending）"
# 「时钟有没有数」：渲染块先写采样时间 / host 时间 / 帧数，最后 release 发布 ticked；读的那边 acquire，而且只经 hasTicked 读。
CLOCK_FILE="$(code "${RENDER_CLOCK}")"
TICK="$(awk '/    func tick\(/,/^    \}/' <<<"${CLOCK_FILE}")"
LAST_FIELD="$({ grep -nE '(sampleTime|hostTime|quantum)\.store\(' <<<"${TICK}" || true; } | tail -1 | cut -d: -f1)"
PUBLISHED="$({ grep -n 'ticked.store(true, ordering: .releasing)' <<<"${TICK}" || true; } | head -1 | cut -d: -f1)"
[ -n "${LAST_FIELD}" ] && [ -n "${PUBLISHED}" ] && [ "${LAST_FIELD}" -lt "${PUBLISHED}" ] \
  || fail "${RENDER_CLOCK}：tick 要先写完采样时间 / host 时间 / 帧数，最后 ticked.store(true, ordering: .releasing) —— relaxed 不保证别的线程读到 true 时那几个数已经写好"
grep -qF 'var hasTicked: Bool { ticked.load(ordering: .acquiring) }' <<<"${CLOCK_FILE}" \
  || fail "${RENDER_CLOCK}：读 ticked 要 acquire（hasTicked）"
grep -qF 'private let ticked = Atomic<Bool>(false)' <<<"${CLOCK_FILE}" \
  || fail "${RENDER_CLOCK}：ticked 要是 private（别处只许经 hasTicked 读，免得又写出一处 relaxed）"
if grep -qE 'ticked\.(load|store)\([^)]*\.relaxed' <<<"${CLOCK_FILE}"; then
  fail "${RENDER_CLOCK}：ticked 的读写不许用 .relaxed"
fi
if grep -qE 'sampleTime: 0, playing: true' <<<"${ENGINE_CODE}"; then
  fail "${ENGINE}：在播的锚点写死了 sampleTime: 0 —— 真声卡上停过再起采样时间不从 0 重来，播放头会跳出去"
fi
grep -qF 'base.compareExchange(expected: Self.unlatched' "${ANCHOR}" || fail "${ANCHOR}：待钉的锚点要由第一个渲染块原子地钉上（compareExchange）"
[ "$(code "${ENGINE}" | grep -c 'anchor.position(sampleTime: Int64(timestamp.pointee.mSampleTime), hostTime: timestamp.pointee.mHostTime)' || true)" -ge 2 ] \
  || fail "${ENGINE}：时钟节点和每条轨的渲染块都要经 PlaybackAnchor.position(sampleTime:hostTime:) 取位置（待钉的在这儿钉）"

# 6. 播到头：声音主时钟自己按总长收尾；在尽头再按播放不开播；不听播放器的「播到头」通知。
grep -qF 'var duration: Double { get }' "${SOURCE_PROTOCOL}" || fail "${SOURCE_PROTOCOL}：声音源要报时间线总长（duration）—— 时钟按它收尾"
grep -qF 'var duration: Double { config.duration }' <<<"${ENGINE_CODE}" || fail "${ENGINE}：引擎报的总长要是配置里的时间线总长（config.duration）"
FINISH="$(awk '/    private func finishAtEnd\(/,/^    \}/' <<<"${CLOCK_CODE}")"
for line in 'source.pause()' 'player.pause()' 'seek(to: end)'; do
  grep -qF "${line}" <<<"${FINISH}" || fail "${CLOCK}：播到头的收尾（finishAtEnd）少了 ${line} —— 声音、画面都停，播放头钉在总长上"
done
grep -qF 'if let end = Self.end(of: source), position >= end {' <<<"${CLOCK_CODE}" && grep -qF 'finishAtEnd(end, source: source)' <<<"${CLOCK_CODE}" \
  || fail "${CLOCK}：声音主时钟的计时器走到总长要自己收尾（finishAtEnd）—— 不然播放头越过片尾一直走、引擎永远不算停着"
PLAY="$(awk '/    func play\(\) \{/,/^    \}/' <<<"${CLOCK_CODE}")"
AT_END_LINE="$({ grep -n 'if isAtEnd {' <<<"${PLAY}" || true; } | head -1 | cut -d: -f1)"
RECOVER_LINE="$({ grep -n 'guard recoverAudioIfNeeded(source) else { return }' <<<"${PLAY}" || true; } | head -1 | cut -d: -f1)"
[ -n "${AT_END_LINE}" ] && [ -n "${RECOVER_LINE}" ] && [ "${AT_END_LINE}" -lt "${RECOVER_LINE}" ] \
  || fail "${CLOCK}：play() 要先看播放头是不是已经在尽头（在就不开播）—— 到了头的播放器不会再报一次「播完了」，声音主时钟会带着播放头越过片尾一直走"
grep -qF 'return time >= end - Self.endSlack' <<<"${CLOCK_CODE}" \
  || fail "${CLOCK}：「在尽头」按播放头到没到时间线总长判（isAtEnd）"
if grep -qF 'AVPlayerItemDidPlayToEndTime' <<<"${CLOCK_CODE}"; then
  fail "${CLOCK}：不许再听播放器的「播到头」通知来停声音 —— 它会排着队等到用户回退重播之后才被处理，把新一轮停掉；播没播完由主时钟按总长自己判"
fi
grep -qF 'AVPlayerItemFailedToPlayToEndTime' <<<"${CLOCK_CODE}" || fail "${CLOCK}：条目播不下去（FailedToPlayToEndTime）时声音和画面要一起停"

# 7. 只算在 SkyCut 里的动作；宿主听「用户回来了」。
PRESENCE_CODE="$(code "${PRESENCE}")"
for signal in 'NSApplication.didBecomeActiveNotification' 'NSWindow.didBecomeKeyNotification' 'NSWindow.didBecomeMainNotification' \
              '.mouseMoved' '.mouseEntered' '.keyDown' '.leftMouseDown' '.scrollWheel' '.activeAlways'; do
  grep -qF -- "${signal}" <<<"${PRESENCE_CODE}" || fail "${PRESENCE}：用户回到 SkyCut 的信号少了 ${signal}（2026-11-11 用户定：变成活动的、窗口变成主 / 键窗口、鼠标移进窗口、按键都算）"
done
grep -qF 'NSEvent.addLocalMonitorForEvents(matching: Self.inputs)' <<<"${PRESENCE_CODE}" || fail "${PRESENCE}：鼠标 / 键盘事件要经本地事件监视器记下来"
grep -qF 'observers = Self.returns.map' <<<"${PRESENCE_CODE}" || fail "${PRESENCE}：三个「回来了」的通知没挂上"
grep -qF 'view.addTrackingArea(NSTrackingArea(' <<<"${PRESENCE_CODE}" \
  || fail "${PRESENCE}：窗口上没挂「指针进来了」的跟踪区（.activeAlways：SkyCut 不在前台时指针移进窗口也要算回来了）"
INPUTS="$(awk '/static let inputs: NSEvent.EventTypeMask = \[/,/^    \]/' <<<"${PRESENCE_CODE}")"
[ -n "${INPUTS}" ] || fail "${PRESENCE}：找不到算「在用」的事件表（inputs）"
if grep -qF '.mouseExited' <<<"${INPUTS}"; then
  fail "${PRESENCE}：指针移出（.mouseExited）不算「回来了」—— 划过窗口就走的那一下不该把图多留两分钟"
fi
grep -qF 'if let lastInput, time <= lastInput { return }' <<<"${PRESENCE_CODE}" \
  || fail "${PRESENCE}：lastInput 只许往后走（时间戳更早的事件不算数）—— 不然一个旧事件就让图被当成很久没人用"
LAUNCH="$(code "${APP}" | awk '/    func applicationDidFinishLaunching\(/,/^    \}/')"
grep -qF 'AppUserPresence.shared.start()' <<<"${LAUNCH}" \
  || fail "${APP}：App 一启动就要开始看用户在不在（AppUserPresence.shared.start()）—— 等第一次建音频引擎才看，打开工程的那一下已经错过，刚起的图当场被停"
grep -qF 'AppUserPresence.shared.whenReturned(self)' <<<"${HOST_CODE}" || fail "${HOST}：宿主没听「用户回来了」（AppUserPresence.shared.whenReturned）—— 图只能等按下播放才起"

# 8. 日志不在主线程上写。
grep -qF 'PreviewAudioEngineHost.logQueue.async { MainThreadWatchdog.shared.note(text) }' <<<"${HOST_CODE}" \
  || fail "${HOST}：停图 / 起图的日志要放到 logQueue 上写（起图那一句正落在按下播放的那一拍，主线程上写文件会慢半拍）"

# 9. 后台起图没起来：图还是故意停着的样子。
GRAPH_CODE="$(code "${GRAPH_RUN}")"
BACKGROUND="$(awk '/    func startInBackground\(/,/^    \}/' <<<"${GRAPH_CODE}")"
CATCH="$(awk '/            \} catch \{/,/^            \}$/' <<<"${BACKGROUND}")"
grep -qF 'state = .suspended' <<<"${CATCH}" \
  || fail "${GRAPH_RUN}：后台起图没起来要回到「故意停着」（state = .suspended）—— 记成 stopped 的话管空闲的每 5 秒记一句「停图」、喂样线程回到每 50 ms 轮询"
grep -qF 'CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, failed)' <<<"${CATCH}" \
  || fail "${GRAPH_RUN}：没起来要回主线程叫一次 failed（收拾喂样线程、告诉管空闲的）"
WAKE_FAILED="$(awk '/    private func wakeFailed\(\) \{/,/^    \}/' <<<"${ENGINE_CODE}")"
grep -qF 'for unit in units { unit.feeder.rest(true) }' <<<"${WAKE_FAILED}" && grep -qF 'onWakeFailed?()' <<<"${WAKE_FAILED}" \
  || fail "${ENGINE}：后台起图没起来要让喂样线程歇回去（rest(true)）并告诉管空闲的（onWakeFailed）"
grep -qF 'if !wakeFailed { audio.wake() }' <<<"${KEEPER_CODE}" \
  || fail "${KEEPER}：上一次没起来之后「看一眼」不许再替它重试（if !wakeFailed）—— 等用户下一次回来"
grep -qF 'if audio.graphIsUp { arm() } else { disarm() }' <<<"${KEEPER_CODE}" \
  || fail "${KEEPER}：图在跑（或正在起）才留着计时器 —— 没起来、收掉了还留着的话每 5 秒白看一次"
RECONCILE="$(awk '/    func reconcile\(\) \{/,/^    \}/' <<<"${KEEPER_CODE}")"
SUSPEND_LINE="$({ grep -n 'audio.suspend()' <<<"${RECONCILE}" || true; } | head -1 | cut -d: -f1)"
NOTE_GUARD_LINE="$({ grep -n 'if audio.isSuspended {' <<<"${RECONCILE}" || true; } | head -1 | cut -d: -f1)"
[ -n "${SUSPEND_LINE}" ] && [ -n "${NOTE_GUARD_LINE}" ] && [ "${SUSPEND_LINE}" -lt "${NOTE_GUARD_LINE}" ] \
  || fail "${KEEPER}：「停图」那一句只在真的停下来时记（suspend 之后 if audio.isSuspended）"

# 10. 一个判断只读一次图的状态（它是原子的，后台起图随时把 starting 改成 running；同一句里读两次，两头可以都比不上）。
grep -qF 'var isUp: Bool { self == .running || self == .starting }' <<<"${GRAPH_CODE}" \
  || fail "${GRAPH_RUN}：「在跑或者正在起」要在取出来的那一个值上判（State.isUp）"
grep -qF 'var graphIsUp: Bool { run.state.isUp }' <<<"${ENGINE_CODE}" \
  || fail "${ENGINE}：graphIsUp 要只读一次状态、在那个值上判（run.state.isUp）—— 读两次的话 starting → running 交接的那一下答成「没在跑」，管空闲的把计时器撤了、图就一直开着"
TWICE="$(grep -nE 'run\.state.*run\.state|graphState.*graphState' <<<"${ENGINE_CODE}"$'\n'"${HOST_CODE}"$'\n'"${KEEPER_CODE}" || true)"
[ -z "${TWICE}" ] || fail "同一句里读了两次图的状态（先 let state = … 再判）：${TWICE}"

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ audio-engine-idle-wiring：引擎交给管空闲的、空了就收、2 分钟、用户回来在后台起图、待钉的锚点、主时钟自己收尾、起不来不空转"
