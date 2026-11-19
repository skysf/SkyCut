import SwiftUI
import AVFoundation
import Combine
import SrtFlowCore

/// Owns the AVPlayer and publishes playback time for subtitle sync.
///
/// **只有真跟着播放头动的小视图才许订阅它**（播放头的线、时间读数、预览上的叠层、电平表）：
/// 播放时它一秒发二十次，订阅它的大视图就一秒重算二十次。检查器、素材库那一栏读
/// `whilePaused` / `atRest`（`PacedPlayhead`）；按钮能不能点看播放头的，用
/// `.disabled(followingPlayhead:)`（docs/architecture/preview-perf-ratchet.md 第十二节）。
final class PlayerClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    /// 悬停预览（peek）此刻指着哪：非 nil 时画面显示的是这里的帧，而 `time`
    /// （真播放头）原地不动。时间线用它画那根半透明的影子指针。
    @Published private(set) var peekTime: TimeInterval?

    /// 播放头被放到了哪儿（`seek`、换片、卸片）。播放把它带着走的时间回调不发这里。
    let placed = PassthroughSubject<PlayheadPlacement, Never>()
    /// 播放头被「回到开头」（Return / Home，2026-09-26 用户拍板）送到了 0：时间线要滚回最左、露出它。
    /// **和 `placed` 分开**：重建预览之后调用方会 seek 回原位，那一下也发 `placed` —— 拿它来滚时间线的话，
    /// 每改一刀时间线都会被拽回播放头。只有用户明确要「回到开头」时才发这里。
    let wentToStart = PassthroughSubject<Void, Never>()
    /// 播放头的两种慢读法（见 `PacedPlayhead`）。懒建：烧字幕页的时钟用不上，不必挂订阅。
    lazy var whilePaused = PacedPlayhead(clock: self, pace: .whilePaused)
    lazy var atRest = PacedPlayhead(clock: self, pace: .atRest)

    /// 预览画面此刻实际显示的时间：悬停预览优先，否则就是播放头。
    /// 叠在画面上的东西（字幕、形状、变换框）读这个才和帧对得上。
    var displayTime: TimeInterval { peekTime ?? time }

    let player = AVPlayer()
    #if DEBUG
    var observePreviewItem: ((AVPlayerItem) -> Void)?
    var isPositioningPreview: Bool { previewSeek != nil }
    #endif
    /// 时间回调的间隔（init 时定）：`estimatedTime` 最多往前补这么长。
    let observationInterval: TimeInterval
    /// 最近一次时间回调落地（或 seek）时的 host 时间，给 `estimatedTime` 外推用。主线程读写。
    private var tickHostTime: TimeInterval = 0
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    /// Play can be pressed as soon as a document's timeline is visible, before AVFoundation can start its item.
    private var playbackRequested = false
    private let readiness = PreviewReadiness()
    private var previewSeek: UUID?
    private var positionedTime: TimeInterval?
    private var previewIsUnprimed = false
    /// A pause is waiting for the native picture to report where it stopped (`holdPausedPicture`).
    private var pausedPictureRequested = false
    /// A Play waiting for a just-started output device to render, so that both clocks can start on a known quantum.
    private let outputStart = OutputStartWait()
    private weak var previewLayer: AVPlayerLayer?
    /// 离总长不到这么多就算已经在尽头：没有东西可播了。
    private static let endSlack: TimeInterval = 0.001

    /// 链式 seek（Apple QA1820）：上一个 seek 还没完成时只记下最新目标，完成后再续发。
    private let scrubber = ChainedScrub()

    /// 声音引擎（开关开着时由工程挂上，见 PreviewAudioEngineHost）。挂着时它是主时钟：`time` 每 50 ms 从它读一次，
    /// 播放器的周期回调只用来对表（差过一帧就把视频重新钉到引擎的时间表上）。
    private(set) var audioSource: PlaybackAudioSource?
    private var audioTimer: Timer?
    /// 视频和引擎连续几拍对不上（一拍的偶差不管，连着两拍才对表）。
    private var drift = VideoDriftCheck()
    /// 对了几次表（冒烟看它）。
    var driftCorrections: Int { drift.corrections }
    /// 上一次往卡顿日志里记「对表」的时刻：连着对表只记第一次，别把日志淹了。
    private var lastDriftNote: TimeInterval = 0

    /// - Parameter observationInterval: 时间回调的间隔。烧字幕预览要靠它切换叠在
    ///   画面上的那句字幕，所以给得比字幕编辑器密一些。
    init(observationInterval: TimeInterval = 0.25) {
        self.observationInterval = observationInterval
        // GUI 冒烟的静音钩子：验播放时别往正在用机器的人耳朵里外放。
        // 环境变量不设就完全不生效（docs/testing/gui-smoke-testing.md）。
        if ProcessInfo.processInfo.environment["SRTFLOW_SMOKE_MUTE"] != nil { player.volume = 0 }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: observationInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            // 卸了片（detach）之后还会晚到一拍、报旧条目的时间：新建 / 打开工程先卸片、播放头归零，这一拍把它写回
            // 上一个工程的位置（2026-09-29，docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md）。没有条目就没有播放时间。
            guard let clock = self, clock.player.currentItem != nil else { return }
            if clock.audioSource != nil {
                // 引擎驱动：播放头从引擎读（attachAudioSource 的 timer），这一拍只用来对表。
                // The observer also fires when playback stops, with the time the picture stopped on.
                if clock.pausedPictureRequested, clock.player.rate == 0 { clock.holdPausedPicture(stoppedAt: cmTime) }
                clock.checkVideoDrift(videoTime: cmTime.seconds)
            } else {
                self?.observePlaybackTime(cmTime.seconds)
            }
        }
        // 播放/暂停按钮要跟着实际状态走：播到片尾时 rate 会自己变 0，
        // 光靠自己按下去的那一下记状态会不准。
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate > 0
            if Thread.isMainThread {
                self?.isPlaying = playing
            } else {
                DispatchQueue.main.async { self?.isPlaying = playing }
            }
        }
        // 播放器播不下去了（条目出错）：声音和画面一起停。正常播到头不靠通知，声音主时钟自己按总长收尾（finishAtEnd）。
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? AVPlayerItem) === player.currentItem, audioSource?.isPlaying == true else { return }
            pause()
        }
    }

    // MARK: 播到头

    /// 声音源说的时间线总长；不知道（0）就不替它收尾。
    private static func end(of source: PlaybackAudioSource) -> TimeInterval? {
        source.duration > 0 ? source.duration : nil
    }

    /// 播放头已经在时间线的尽头（刚播完、被放到了总长上、或者上一跳读数略微超出）：没有东西可播。
    private var isAtEnd: Bool {
        guard let source = audioSource, let end = Self.end(of: source) else { return false }
        return time >= end - Self.endSlack
    }

    /// 声音主时钟走到了时间线的总长：这一轮播完了，**主时钟自己收尾** —— 声音、画面都停，播放头钉在总长上（三处同一个位置）。
    ///
    /// 2026-11-11 之前没人收尾：播放器播到头自己停，声音引擎的锚点还标着在播，播放头照着它越过片尾一直往后走，引擎也永远
    /// 不算停着、图一直开着占着声卡（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。第一版改成听播放器的
    /// 「播到头」通知，两处不对（同一份案例「审查之后」）：通知只停声音、不把播放头收回总长，在片尾直接再按播放时到了头的
    /// 播放器不会再发第二次通知，声音主时钟又一直走下去；通知排着队还没处理时用户已经回退重播，旧通知把新一轮最后半秒的
    /// 声音停掉。所以正常播完**不听通知**：播没播完只有主时钟自己知道。
    private func finishAtEnd(_ end: TimeInterval, source: PlaybackAudioSource) {
        source.pause()
        player.pause()
        seek(to: end)
    }

    /// 播放器报来一次播放时间（播放时每 `observationInterval` 一次）。
    ///
    /// 单独成一个方法是为了性能测试：它的「时钟连跳」要走和真播放**同一段**
    /// 代码（PreviewBench.swift），不能另写一份直接改 `time`。
    func observePlaybackTime(_ seconds: TimeInterval) {
        PerfCounters.event(.clockTick)
        // 悬停预览期间播放器在别处扫帧，这些回调不能写回播放头 ——
        // 否则播放头还是会被悬停拖走，peek 就白做了。
        if peekTime == nil {
            time = seconds
            tickHostTime = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 播放头此刻大概在哪，**不问播放器**：最近一跳的时间，加上从那一跳到现在过了多久（最多补一跳）。
    ///
    /// 跟着播放头画东西的高频读者（电平条：每条轨每秒 30 次）读它。`player.currentTime()` 要拿播放器
    /// 内部那把锁，播放器自己的队列一忙（多轨合成的音频管线在干活）主线程就被堵住 —— 2026-10-01 在
    /// 南极工程里抓到一次 2.4 秒、几次 200–300 ms，空格按下去图标慢半拍就是它
    /// （docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md）。`checks/player-time-no-sync-read.sh`
    /// 钉着：App 代码里不许再出现 `currentTime()`，时间只从时钟的回调来。
    var estimatedTime: TimeInterval {
        PlaybackTimeEstimate.estimate(
            tick: time, tickHost: tickHostTime, now: ProcessInfo.processInfo.systemUptime,
            isPlaying: isPlaying, maxLead: observationInterval
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObservation?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        audioTimer?.invalidate()
        // 视图被销毁（比如切走了侧边栏那一栏）时别让声音还在响。
        player.pause()
    }

    // MARK: 声音引擎当主时钟

    /// 挂上当前引擎：同一个不重复挂；换源时先摘旧计时器和旧引擎。
    func attachAudioSource(_ source: PlaybackAudioSource) {
        guard audioSource !== source else { return }
        detachAudioSource()
        audioSource = source
        // `setRate(_:time:atHostTime:)` 要求关掉「等缓冲」（开着会抛异常）；本地文件本来也不用等。
        player.automaticallyWaitsToMinimizeStalling = false
        let timer = Timer(timeInterval: observationInterval, repeats: true) { [weak self] _ in
            guard let self, let source = audioSource, source.isPlaying else { return }
            guard recoverAudioIfNeeded(source) != nil else { return }
            let position = source.playhead
            if let end = Self.end(of: source), position >= end {
                finishAtEnd(end, source: source)
            } else {
                observePlaybackTime(position)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    /// 卸片 / 关预览时也摘掉主时钟，不能让下一次预览仍读着已停止的旧引擎。
    private func detachAudioSource() {
        audioSource?.pause()
        audioSource = nil
        audioTimer?.invalidate()
        audioTimer = nil
        drift.reset()
    }

    /// Reports whether the graph restarted. A nil result leaves both streams paused after a failed recovery.
    private func recoverAudioIfNeeded(_ source: PlaybackAudioSource) -> Bool? {
        do {
            let restarted = try source.recoverIfNeeded()
            if restarted {
                drift.reset()
                MainThreadWatchdog.shared.note("音频引擎已恢复，重新对齐视频时钟")
                if source.isPlaying { anchorVideo(to: source.playhead) }
            }
            return restarted
        } catch {
            pause()
            MainThreadWatchdog.shared.note("音频引擎恢复失败，已暂停播放：\(error.localizedDescription)")
            return nil
        }
    }

    /// 视频的周期回调报来的时间和引擎差过一帧（连着两拍）就把视频重新钉到引擎的时间表上。
    private func checkVideoDrift(videoTime: TimeInterval) {
        guard let source = audioSource, source.isPlaying, player.rate > 0 else {
            drift.reset()
            return
        }
        let audio = source.playhead
        guard drift.observe(video: videoTime, audio: audio) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDriftNote > 1 {
            lastDriftNote = now
            MainThreadWatchdog.shared.note(String(format: "视频对表：画面 %.3f s、引擎 %.3f s（差 %.0f ms），重新钉到引擎", videoTime, audio, abs(videoTime - audio) * 1000))
        }
        anchorVideo(to: audio)
    }

    /// Start at `host` (now when nil). With no explicit target, reuse the native preview's prepared position.
    private func anchorVideo(to seconds: TimeInterval?, atHostTime host: UInt64? = nil) {
        guard player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        let target = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        let start = host.map { CMClockMakeHostTimeFromSystemUnits($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        player.setRate(1, time: target, atHostTime: start)
        positionedTime = nil
    }

    func bindPreviewLayer(_ layer: AVPlayerLayer) { previewLayer = layer }

    /// Only the current item and request can release a waiting seek or Play; a failed item or player stops both.
    private func observeReadiness(of item: AVPlayerItem, layer: AVPlayerLayer? = nil, then resume: @escaping () -> Void) {
        readiness.watch(item, player: player, layer: layer, failed: { [weak self] in
            self?.invalidatePreviewSeek()
            self?.pause()
        }, ready: resume)
    }

    /// Advance the native preview and the audio clock from the placed playhead.
    func play() {
        guard let item = player.currentItem else {
            playbackRequested = true
            return
        }
        if item.status == .failed || player.status == .failed {
            invalidatePreviewSeek()
            pause()
            return
        }
        if previewSeek != nil {
            playbackRequested = true
            return
        }
        if audioSource != nil, item.status != .readyToPlay || player.status != .readyToPlay {
            playbackRequested = true
            observeReadiness(of: item) { [weak self] in
                if self?.playbackRequested == true { self?.play() }
            }
            return
        }
        playbackRequested = false
        readiness.clear()
        if let source = audioSource {
            pausedPictureRequested = false
            // 播放头已经在尽头：没有东西可播，这一下不开播。照样开播的话声音主时钟从尽头起步、带着播放头越过片尾一直走：
            // 到了头的播放器不会再报一次「播完了」。The user's Play at the end replays from 0 (`togglePlayback`, UI-2).
            if isAtEnd {
                if source.isPlaying { source.pause() }
                return
            }
            if source.isPlaying {
                // Already playing (a seek during playback re-anchored the picture): there is nothing to prepare.
                // Only a picture that stopped while the sound went on is set moving again on the sound's timeline.
                if player.rate == 0 { anchorVideo(to: source.playhead) }
                return
            }
            let start = time
            guard positionedTime == start, !previewIsUnprimed else {
                // The sound never starts ahead of the picture. A playhead whose picture is not placed and primed
                // (after a hover elsewhere, a scrub or a failed preparation) is placed first; a new item is primed.
                // This Play stays pending and starts both clocks once the picture can move
                // (docs/architecture/playback-start.md).
                playbackRequested = true
                if positionedTime == start {
                    let request = UUID()
                    previewSeek = request
                    preparePositionedPreview(request, at: start, seekFinished: true)
                } else {
                    positionPreview(at: CMTime(seconds: start, preferredTimescale: 600), seconds: start)
                }
                return
            }
            guard let restarted = recoverAudioIfNeeded(source) else { return }
            guard source.isRendering else {
                // The output device has just started (the idle stop, a system stop) and not rendered yet: both clocks
                // start together on its first known quantum, the picture never ahead of the sound.
                playbackRequested = true
                outputStart.begin(until: { [weak source] in source?.isRendering ?? true }) { [weak self, weak source] in
                    guard let self, let source, playbackRequested, audioSource === source else { return }
                    playbackRequested = false
                    positionedTime = nil
                    source.play(from: start)
                    // The sound is pinned to the output's next quantum; the picture starts at its host time, no seek.
                    if let host = source.startHostTime { anchorVideo(to: nil, atHostTime: host) } else { player.playImmediately(atRate: 1) }
                }
                return
            }
            positionedTime = nil
            source.play(from: start)
            if restarted {
                // The output device restarted under the positioned picture: start it on the new audio host clock.
                anchorVideo(to: nil)
            } else {
                player.playImmediately(atRate: 1)
            }
        } else {
            player.play()
        }
    }

    func attach(url: URL, autoplay: Bool = true) {
        pause()
        invalidatePreviewSeek()
        previewIsUnprimed = false
        scrubber.cancelPending()
        peekTime = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        hasVideo = true
        time = 0
        placed.send(PlayheadPlacement(time: 0, precise: true))
        if autoplay { player.play() }
    }

    /// 换上一个现成的条目（时间线合成不是 URL，`attach(url:)` 用不上）。
    /// 播放头交给调用方自己恢复。
    func attachItem(_ item: AVPlayerItem) {
        PerfCounters.event(.playerItemAttach)
        audioSource?.pause()
        player.pause()
        invalidatePreviewSeek()
        previewIsUnprimed = true
        scrubber.cancelPending()
        peekTime = nil
        #if DEBUG
        observePreviewItem?(item)
        #endif
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    /// Called after the new picture and sound are installed and positioned.
    func resumeAfterPreviewRebuild(wasPlaying: Bool) {
        if wasPlaying || playbackRequested { play() }
    }

    func detach() {
        pause()
        invalidatePreviewSeek()
        previewIsUnprimed = false
        audioSource?.seek(to: 0)
        detachAudioSource()
        player.replaceCurrentItem(with: nil)
        scrubber.cancelPending()
        peekTime = nil
        hasVideo = false
        time = 0
        placed.send(PlayheadPlacement(time: 0, precise: true))
    }

    /// - Parameter precise: 松手和按字幕跳转时给 `true`（立刻精确定位）；拖动/悬停
    ///   扫过的过程中给 `false` —— 也是零容差逐帧刷新，但走链式 seek 防洪。
    ///   注意不能退回「就近关键帧」的粗定位：合成条目的关键帧隔好几秒一个，
    ///   拖动中画面会看起来纹丝不动（docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md）。
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        // 任何真正的定位（点标尺、拖播放头、点字幕……）都终结悬停预览：
        // 播放头就该移过去，影子指针消失。
        peekTime = nil
        let clamped = max(0, seconds)
        time = clamped
        tickHostTime = ProcessInfo.processInfo.systemUptime
        placed.send(PlayheadPlacement(time: clamped, precise: precise))
        invalidatePreviewSeek()
        if let source = audioSource {
            // 引擎驱动：声音先跳过去（一个 IO 缓冲就出声）；视频在播就钉到同一个时刻（播放器自己定位、赶上来），
            // 停着就照旧精确定位 / 链式扫帧。
            source.seek(to: clamped)
            if source.isPlaying {
                scrubber.cancelPending()
                MainThreadWatchdog.shared.note(String(format: "播放中 seek → %.3f s（引擎先跳，视频钉过去自己赶）", clamped))
                anchorVideo(to: clamped)
                return
            }
        }
        if precise {
            scrubber.cancelPending()
            let target = CMTime(seconds: clamped, preferredTimescale: 600)
            if audioSource != nil, player.currentItem != nil {
                positionPreview(at: target, seconds: clamped)
            } else {
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else {
            scrub(to: clamped)
        }
    }

    private func invalidatePreviewSeek() {
        pausedPictureRequested = false
        outputStart.cancel()
        let wasPositioning = previewSeek != nil
        previewSeek = nil
        positionedTime = nil
        readiness.clear()
        if wasPositioning { player.cancelPendingPrerolls() }
    }

    private func positionPreview(at target: CMTime, seconds: TimeInterval) {
        let request = UUID()
        previewSeek = request
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                self?.preparePositionedPreview(request, at: seconds, seekFinished: finished)
            }
        }
    }

    private func preparePositionedPreview(_ request: UUID, at seconds: TimeInterval, seekFinished: Bool) {
        guard previewSeek == request else { return }
        // Every paused placement primes the picture, a new item's first one included, so Play only starts the clocks.
        guard seekFinished, !isAtEnd, player.rate == 0, let item = player.currentItem else {
            finishPreviewPosition(request, at: seekFinished ? seconds : nil)
            return
        }
        guard player.status == .readyToPlay, item.status == .readyToPlay else {
            observeReadiness(of: item) { [weak self] in
                self?.preparePositionedPreview(request, at: seconds, seekFinished: true)
            }
            return
        }
        // A new item with Play already pending primes at playback rate. A paused placement primes at a quarter: on the
        // M1 a new item primed that way started as fast as one primed at full rate, with less decoded ahead and held.
        player.preroll(atRate: previewIsUnprimed && playbackRequested ? 1 : 0.25) { [weak self] finished in
            DispatchQueue.main.async { self?.finishPreviewPosition(request, at: finished ? seconds : nil, primed: finished) }
        }
    }

    private func finishPreviewPosition(
        _ request: UUID, at seconds: TimeInterval?, primed: Bool = false, waitForDisplay: Bool = true
    ) {
        guard previewSeek == request else { return }
        if primed, waitForDisplay, previewIsUnprimed, let item = player.currentItem, item.videoComposition != nil,
           let layer = previewLayer, !layer.isReadyForDisplay {
            let resume = { [weak self] in
                guard let self, self.previewSeek == request else { return }
                self.readiness.clear()
                self.finishPreviewPosition(request, at: seconds, primed: true, waitForDisplay: false)
            }
            observeReadiness(of: item, layer: layer) { resume() }
            // A closed or hidden surface may never report its first frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { resume() }
            return
        }
        if primed {
            previewIsUnprimed = false
            PerfCounters.event(.previewPreroll)
        }
        previewSeek = nil
        positionedTime = seconds
        if playbackRequested { play() }
    }

    /// 每个 mouse move 都直发 `player.seek` 会淹死解码器（在飞的 seek 被反复取消，
    /// 帧刷新率反而不稳）。这里串行化：在飞时只记目标，完成回调里续发最新的。
    private func scrub(to seconds: TimeInterval) {
        scrubber.scrub(player, to: seconds) { [weak self] in
            guard let self, playbackRequested, previewSeek == nil else { return }
            play()
        }
    }

    // MARK: 悬停预览（peek）

    /// 画面滚到指的那一帧看一眼，但**不动播放头**。走链式 seek 防洪，
    /// 和拖动扫帧同一条路（docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md）。
    func peek(at seconds: TimeInterval) {
        guard !playbackRequested else { return }
        invalidatePreviewSeek()
        let clamped = max(0, seconds)
        peekTime = clamped
        scrub(to: clamped)
    }

    /// 悬停结束：影子指针消失，画面滚回播放头。没在 peek 时是无害的 no-op。
    func endPeek() {
        guard peekTime != nil else { return }
        peekTime = nil
        guard audioSource != nil, player.currentItem != nil else {
            scrub(to: time)
            return
        }
        // Back on the playhead with a placed and primed picture, ready for Play (a scrub would leave it unprimed).
        scrubber.cancelPending()
        invalidatePreviewSeek()
        positionPreview(at: CMTime(seconds: time, preferredTimescale: 600), seconds: time)
    }

    /// Return / Home：播放头回到开头。正在播就从开头接着播（`seek` 不改播放状态），停着就停在 0，
    /// 再按空格从头播。时间线听 `wentToStart` 滚回最左。
    func goToStart() {
        seek(to: 0)
        wentToStart.send()
    }

    func togglePlayback() {
        if playbackRequested || player.rate > 0 {
            pause()
        } else if isAtEnd {
            // Play at the end replays from the start, as in other editors and players (UI-2, 2026-11-18: "when the project
            // ends, pressing Play or going back to 0 both replay normally"). `play()` itself still never starts at the end: a
            // rebuild that resumes playback there must not jump to 0. `goToStart` also ends a hover peek and scrolls the
            // timeline back to the left.
            goToStart()
            play()
        } else {
            // 悬停预览把画面带去了别处：播放必须从**播放头**起，先precise跳回去。
            // seek 后紧跟 play 是安全的（play 不取消在飞的 seek，完成后从目标续播）。
            // With the engine, `play()` places and primes the picture at the playhead before either clock starts.
            if peekTime != nil {
                peekTime = nil
                scrubber.cancelPending()
                if audioSource == nil {
                    player.seek(
                        to: CMTime(seconds: time, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero
                    )
                }
            }
            play()
        }
    }

    func pause() {
        playbackRequested = false
        outputStart.cancel()
        if previewSeek == nil { readiness.clear() }
        let wasPlaying = audioSource?.isPlaying == true && player.rate > 0
        audioSource?.pause()
        player.pause()
        if wasPlaying {
            pausedPictureRequested = true
            holdPausedPicture(stoppedAt: nil)
        }
    }

    /// Paused playback leaves a positioned picture on the frame it stopped on (`PausedPictureHold` has the rule and why),
    /// read from the stopped timebase inside `pause()` or from the time observer's stop callback.
    private func holdPausedPicture(stoppedAt reported: CMTime?) {
        guard pausedPictureRequested, let source = audioSource, previewSeek == nil, player.rate == 0,
              let timebase = player.currentItem?.timebase, reported != nil || CMTimebaseGetRate(timebase) == 0 else { return }
        pausedPictureRequested = false
        let stopped = reported ?? CMTimebaseGetTime(timebase)
        let sound = max(0, source.playhead)
        guard let seconds = PausedPictureHold.position(picture: stopped, sound: sound) else {
            seek(to: sound)
            return
        }
        source.seek(to: seconds)
        time = seconds
        tickHostTime = ProcessInfo.processInfo.systemUptime
        positionedTime = seconds
        placed.send(PlayheadPlacement(time: seconds, precise: true))
    }
}
