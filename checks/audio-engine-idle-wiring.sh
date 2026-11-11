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
#   5. 图刚起 / 停着时发的在播锚点是待钉的（不许写死「采样时间从 0 起」）；
#   6. 播到片尾播放器自己停，声音主时钟跟着停（不然引擎永远不算停着）；
#   7. 用户回到 SkyCut 就算（变成活动的 App、窗口变成主 / 键窗口、发给 SkyCut 的鼠标和键盘事件），宿主听「用户回来了」；
#   8. 停图 / 起图的那句日志不在主线程上写。
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
APPLY="$(code "${HOST}" | awk '/    func apply\(_ config: AudioEngineConfig/,/^    \}/')"
REUSED="$(awk '/        if let engine \{/,/^        \}/' <<<"${APPLY}")"
grep -qF 'idle.reconcile()' <<<"${REUSED}" || fail "${HOST}：复用引擎换完配置没让管空闲的看一眼（idle.reconcile()）—— 新配置没有声音时图不会当场停"
grep -qF 'idle.keep(engine)' <<<"${APPLY}" || fail "${HOST}：新建的引擎没交给管空闲的（idle.keep(engine)）—— 图会一直开着"
grep -qF 'AppUserPresence.shared.start()' <<<"${APPLY}" || fail "${HOST}：建引擎时没开始看用户在不在（AppUserPresence.shared.start()）"
STOP="$(code "${HOST}" | awk '/    func stop\(\) \{/,/^    \}/')"
RELEASE_LINE="$(grep -n 'idle.release()' <<<"${STOP}" | head -1 | cut -d: -f1)"
ENGINE_STOP_LINE="$(grep -n 'engine?.stop()' <<<"${STOP}" | head -1 | cut -d: -f1)"
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
grep -qF 'run.startInBackground { try engine.start() }' <<<"${WAKE}" \
  || fail "${ENGINE}：wake() 要在后台那条队列上起图（run.startInBackground）—— 在调用方的线程上起，用户回来的那一下主线程卡 0.15–0.3 秒"
RECOVER="$(code "${ENGINE}" | awk '/    func recoverIfNeeded\(\) throws -> Bool \{/,/^    \}/')"
SETTLE_LINE="$(grep -n 'if run.state == .starting { run.settle() }' <<<"${RECOVER}" | head -1 | cut -d: -f1)"
SUSPENDED_LINE="$(grep -n 'if run.state == .suspended {' <<<"${RECOVER}" | head -1 | cut -d: -f1)"
RUNNING_LINE="$(grep -n 'guard !engine.isRunning else { return false }' <<<"${RECOVER}" | head -1 | cut -d: -f1)"
[ -n "${SETTLE_LINE}" ] && [ -n "${SUSPENDED_LINE}" ] && [ -n "${RUNNING_LINE}" ] \
  && [ "${SETTLE_LINE}" -lt "${SUSPENDED_LINE}" ] && [ "${SUSPENDED_LINE}" -lt "${RUNNING_LINE}" ] \
  || fail "${ENGINE}：recoverIfNeeded 要先等后台那一次起图（run.settle()）、再认「故意停的」（.suspended）、最后才看 engine.isRunning"
SUSPENDED_BRANCH="$(awk '/        if run.state == .suspended \{/,/^        \}/' <<<"${RECOVER}")"
grep -qF 'guard config.hasSound else { return false }' <<<"${SUSPENDED_BRANCH}" \
  || fail "${ENGINE}：故意停着的图只在有声音要出时才起（guard config.hasSound），没有声音的时间线按 host 时间走"
grep -qF 'try engine.start()' <<<"${SUSPENDED_BRANCH}" && ! grep -qF 'wake()' <<<"${SUSPENDED_BRANCH}" \
  || fail "${ENGINE}：时钟要出声时图还停着就当场起（try engine.start()），不许换成 wake() 让播放头先空走 —— 起声卡时进程本来就被拖住，先走的那一截画面和声音会被跳过"
SUSPEND="$(code "${ENGINE}" | awk '/    func suspend\(\) \{/,/^    \}/')"
grep -qF 'engine.pause()' <<<"${SUSPEND}" && grep -qF 'publishAnchor(frame, playing: wasPlaying)' <<<"${SUSPEND}" \
  || fail "${ENGINE}：suspend() 要停掉图的 IO（engine.pause()）并把在播的锚点改成按 host 时间走（publishAnchor）"
for entry in 'func replace(config new: AudioEngineConfig) {' 'func duck(_ gain: Float) {' 'func mute() {' 'func stop() {' 'func suspend() {'; do
  BODY="$(code "${ENGINE}" | awk -v start="    ${entry}" 'index($0, start) == 1 { on = 1 } on { print } on && /^    \}/ { exit }')"
  grep -qF 'run.settle()' <<<"${BODY}" || fail "${ENGINE}：${entry%% \{} 动图之前要先等后台那一次起图做完（run.settle()）"
done

# 5. 在播的锚点：时钟没数就发待钉的；不许再写死采样时间从 0 起。
PUBLISH="$(code "${ENGINE}" | awk '/    private func publishAnchor\(/,/^    \}/')"
grep -qF 'if playing, !renderClock.ticked.load(ordering: .relaxed) {' <<<"${PUBLISH}" && grep -qF 'anchor.publish(.pending(' <<<"${PUBLISH}" \
  || fail "${ENGINE}：publishAnchor 在时钟没数时（图刚起 / 还在起 / 停着）要发待钉的锚点（.pending）"
if grep -qE 'sampleTime: 0, playing: true' <<<"${ENGINE_CODE}"; then
  fail "${ENGINE}：在播的锚点写死了 sampleTime: 0 —— 真声卡上停过再起采样时间不从 0 重来，播放头会跳出去"
fi
grep -qF 'base.compareExchange(expected: Self.unlatched' "${ANCHOR}" || fail "${ANCHOR}：待钉的锚点要由第一个渲染块原子地钉上（compareExchange）"
[ "$(code "${ENGINE}" | grep -c 'anchor.position(sampleTime: Int64(timestamp.pointee.mSampleTime), hostTime: timestamp.pointee.mHostTime)' || true)" -ge 2 ] \
  || fail "${ENGINE}：时钟节点和每条轨的渲染块都要经 PlaybackAnchor.position(sampleTime:hostTime:) 取位置（待钉的在这儿钉）"

# 6. 播到片尾：声音主时钟跟着停。
ENDED="$(code "${CLOCK}" | awk '/    private func itemEnded\(/,/^    \}/')"
grep -qF 'source.pause()' <<<"${ENDED}" || fail "${CLOCK}：条目播到头（itemEnded）没停声音主时钟 —— 播放头一直往后走，引擎永远不算停着"
for name in 'AVPlayerItemDidPlayToEndTime' 'AVPlayerItemFailedToPlayToEndTime'; do
  grep -qF "${name}" <<<"${CLOCK_CODE}" || fail "${CLOCK}：没听 ${name}"
done

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
grep -qF 'AppUserPresence.shared.whenReturned(self)' <<<"${HOST_CODE}" || fail "${HOST}：宿主没听「用户回来了」（AppUserPresence.shared.whenReturned）—— 图只能等按下播放才起"

# 8. 日志不在主线程上写。
grep -qF 'PreviewAudioEngineHost.logQueue.async { MainThreadWatchdog.shared.note(text) }' <<<"${HOST_CODE}" \
  || fail "${HOST}：停图 / 起图的日志要放到 logQueue 上写（起图那一句正落在按下播放的那一拍，主线程上写文件会慢半拍）"

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ audio-engine-idle-wiring：引擎交给管空闲的、空了就收、2 分钟、用户回来在后台起图、待钉的锚点、片尾停主时钟"
