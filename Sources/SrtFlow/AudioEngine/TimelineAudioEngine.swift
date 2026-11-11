import AVFoundation
import Foundation
import Synchronization

// MARK: - 时间线的声音引擎：图、时钟锚点、实时播放与离线渲染
//
// 管什么：一个 AVAudioEngine，每条轨一个 AVAudioSourceNode（渲染块在 AudioTrackRenderer），各轨的喂样
// （AudioTrackFeeder），总推子在 mainMixer；播放头的锚点（`PlaybackAnchor`：引擎的采样时间 ↔ 时间线的帧），
// 实时的 play / pause / seek，和离线的整段渲染（manual rendering，成片和自检用同一条路）。
// 不管什么：配置怎么从时间线算（AudioEngineConfig）；和视频对表、喂 PlayerClock（PR1b，VideoEditProject 那边接）。
//
// 时钟：渲染块拿到的时间戳是引擎的采样时间，**所有轨同一拍拿到同一个数**，各自按锚点（PlaybackAnchor）换成时间线的帧 ——
// 不用谁先谁后的问题。seek = 发布一个新锚点 + 让各轨的喂样从新位置重读；暂停 = 锚点标成不播（渲染块出静音）；
// 所以 seek 和开播都只是改几个数，不拆任何东西（2026-10-01 探针：22 轨 9 ms，一个 IO 缓冲）。
// 图不是一直开着的（2026-11-11）：没有声音要出、或者停着没人用了，`suspend()` 把图的 IO 停掉（声卡放手，系统才能
// 空闲睡眠、App Nap 才生效）；用户回来动一下就 `wake()` 在后台先起好，时钟开播时还没起就当场起（`recoverIfNeeded`）。
// 没有声音的时间线不起图，播放头按 host 时间走（PlaybackAnchor 的「待钉」）。
// 什么时候停、什么时候起不归这里管（AudioEngineIdlePolicy / AudioEngineIdleKeeper）。
// 方案：docs/plans/2026-10-01-audio-engine.md；长期约束：docs/architecture/audio-engine.md 第二节第 11 条。

final class TimelineAudioEngine {
    static let sampleRate = AudioSegmentReader.engineRate
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    enum Mode { case realtime, offline }
    struct RenderError: Error { let status: AVAudioEngineManualRenderingStatus }

    let mode: Mode
    let engine = AVAudioEngine()
    private(set) var config: AudioEngineConfig
    /// 轨道头的电平表（nil = 不量）。每条轨的渲染块按拍把峰值写进自己的无锁槽（MeterSlot），总表从混音器的出口取
    /// （实时是 mainMixer 上的 tap，离线是渲出来的那一块）；槽登记进电平表，界面照旧按键读、照旧做回落和红灯
    /// （docs/architecture/audio-engine.md 第三节）。
    let meters: AudioMeterEngine?
    private let masterSlot = MeterSlot()
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。冒烟和自检看它。
    var underrunFrames: Int { renderClock.underruns.load(ordering: .relaxed) }

    /// 引擎的时钟：渲染线程每拍写、别处读（AudioRenderClock）。
    private let renderClock = AudioRenderClock()
    /// 图在不在跑、是不是故意停的（空闲），和后台起图的那条队列。
    private let run = AudioGraphRun()
    var graphState: AudioGraphRun.State { run.state }
    /// 图是不是故意停着（空闲）。
    var isSuspended: Bool { run.state == .suspended }
    /// 上一次从在播变成停着是什么时候（系统开机以来的秒；没播过是 nil）。空闲从这儿起算。
    private(set) var stoppedPlayingAt: TimeInterval?
    /// 时间线上有没有要出声的段。
    var hasSound: Bool { config.hasSound }
    /// 时间线总长（秒）：时钟按它收尾（PlaybackAudioSource.duration）。合成也正好这么长（builder 垫黑底铺到总长）。
    var duration: Double { config.duration }
    /// 图在跑或者正在起（管空闲的那一位只在这时候留着计时器）。状态只读一次、在那个值上判（AudioGraphRun.State.isUp）。
    var graphIsUp: Bool { run.state.isUp }
    /// 故意停着的图要起回来了（`wake()` / 时钟要出声，主线程上叫）：管空闲的那一位从这儿知道要重新开始数。
    var onWake: (() -> Void)?
    /// 后台那一次没起来（主线程上叫）：图还是故意停着的样子。
    var onWakeFailed: (() -> Void)?
    /// 怎么起原生图。只有自检换它（注一个起不来的，验「没有能用的输出设备」那条路）；生产就是 `start()`。
    var startGraph: @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }
    /// 一直挂着的静音节点：没有一条轨出声的时间线也要有人每拍更新时钟。
    private var clockNode: AVAudioSourceNode?
    private var running = false
    /// 试听让路时压的那一份（线性），乘在总推子上。
    private var duckGain: Float = 1
    private let anchor = AudioPublished<PlaybackAnchor>()
    private struct TrackUnit {
        let feeder: AudioTrackFeeder
        let renderer: AudioTrackRenderer
        let node: AVAudioSourceNode
    }
    private var units: [TrackUnit] = []

    init(config: AudioEngineConfig, mode: Mode, meters: AudioMeterEngine? = nil) throws {
        self.mode = mode
        self.config = config
        self.meters = meters
        if mode == .offline {
            try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        }
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: 0, playing: false))
        attachClockNode()
        for track in config.tracks { attach(track) }
        engine.mainMixerNode.outputVolume = config.master
        registerMeterSlots()
        if mode == .realtime, meters != nil {
            // 总表：混音器出口的那一拍（含总推子）。tap 在引擎自己的线程上拿到拷贝，不进渲染线程。
            let slot = masterSlot
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                guard let data = buffer.floatChannelData, buffer.format.channelCount >= 1 else { return }
                let right = data[min(1, Int(buffer.format.channelCount) - 1)]
                slot.offer(frames: Int(buffer.frameLength), left: data[0], right: right)
            }
        }
    }

    /// 每条轨的槽 + 总表的槽，整批登记（换配置时重来）。
    private func registerMeterSlots() {
        guard let meters else { return }
        var slots: [MeterKey: MeterSlot] = [.master: masterSlot]
        for (unit, track) in zip(units, config.tracks) { slots[track.meterKey] = unit.renderer.meterSlot }
        meters.registerSlots(slots)
    }

    /// 静音的节点，只负责把每一拍的时间戳记进 `renderClock`。
    private func attachClockNode() {
        let clock = renderClock
        let anchor = self.anchor
        let node = AVAudioSourceNode(format: Self.format) { isSilence, timestamp, frameCount, outputData -> OSStatus in
            clock.tick(timestamp, frames: Int(frameCount))
            // 待钉的锚点在这儿也钉一次：没有一条轨出声的时间线只有这个节点在渲。
            if let anchor = anchor.load(), anchor.playing {
                _ = anchor.position(sampleTime: Int64(timestamp.pointee.mSampleTime), hostTime: timestamp.pointee.mHostTime)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frameCount)) }
            isSilence.pointee = true
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        clockNode = node
    }

    private func attach(_ track: AudioEngineConfig.Track) {
        let feeder = AudioTrackFeeder(track: track)
        let renderer = AudioTrackRenderer(feeder: feeder, fader: track.fader)
        let anchor = self.anchor
        let clock = renderClock
        let node = AVAudioSourceNode(format: Self.format) { _, timestamp, frameCount, outputData -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            clock.tick(timestamp, frames: frames)
            guard let anchor = anchor.load(), anchor.playing else { return noErr }
            let position = anchor.position(sampleTime: Int64(timestamp.pointee.mSampleTime), hostTime: timestamp.pointee.mHostTime)
            let missing = renderer.render(position: position, frames: frames, into: left, right)
            if missing > 0 {
                clock.underruns.wrappingAdd(missing, ordering: .relaxed)
                feeder.poke()
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        units.append(TrackUnit(feeder: feeder, renderer: renderer, node: node))
    }

    // MARK: 离线：整段渲染

    /// 把时间线从 0 渲到 `duration` 秒，按拍交给 `consumer`（交错的立体声 f32、这一拍的帧数）；`consumer` 回 false 就停
    /// （导出被取消）。成片和自检走这里；喂样在这条线程上同步做。
    func renderOffline(duration: Double, consumer: (UnsafeBufferPointer<Float>, Int) -> Bool) throws {
        precondition(mode == .offline, "renderOffline 只在离线模式下用")
        let total = Int64((duration * Self.sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return }
        try engine.start()
        defer { engine.stop() }
        // 离线：渲染块的时间戳从 manualRenderingSampleTime 起，锚点钉在它上面。
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: Int64(engine.manualRenderingSampleTime), playing: true))
        var interleaved = [Float](repeating: 0, count: Int(buffer.frameCapacity) * 2)
        var position: Int64 = 0
        while position < total {
            let frames = Int(min(Int64(buffer.frameCapacity), total - position))
            for unit in units { unit.feeder.service(at: position) }
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
            guard status == .success, let data = buffer.floatChannelData else { throw RenderError(status: status) }
            let got = Int(buffer.frameLength)
            masterSlot.offer(frames: got, left: data[0], right: data[1])
            for index in 0..<got {
                interleaved[2 * index] = data[0][index]
                interleaved[2 * index + 1] = data[1][index]
            }
            let keepGoing = interleaved.withUnsafeBufferPointer { consumer(UnsafeBufferPointer(rebasing: $0[0..<(got * 2)]), got) }
            guard keepGoing else { return }
            position += Int64(got)
        }
    }

    // MARK: 换配置

    /// 整份配置换掉（预览重建之后）：轨的结构可能变了，节点和喂样重来；播放头和播放状态不变。
    /// 结构没变（同样的轨、同样的段）就只换增益，流不重开。
    func replace(config new: AudioEngineConfig) {
        if Self.sameStructure(config, new) {
            updateGains(config: new)
            return
        }
        run.settle()
        config = new
        for unit in units {
            unit.feeder.stop()
            engine.detach(unit.node)
        }
        units.removeAll()
        for track in new.tracks { attach(track) }
        engine.mainMixerNode.outputVolume = new.master * duckGain * (muted ? 0 : 1)
        registerMeterSlots()
        if running { startFeeders() }
    }

    /// 只换增益（拖推子 / 曲线、改音量）：按段对上的换采样器，轨道推子、总推子直接换。结构不同就退到 `replace`。
    func updateGains(config new: AudioEngineConfig) {
        guard Self.sameStructure(config, new) else {
            replace(config: new)
            return
        }
        run.settle()
        config = new
        for (unit, track) in zip(units, new.tracks) {
            unit.renderer.fader.store(track.fader, ordering: .relaxed)
            unit.feeder.update(Dictionary(track.segments.map { ($0.clipID, SegmentUpdate($0)) }, uniquingKeysWith: { first, _ in first }))
        }
        engine.mainMixerNode.outputVolume = new.master * duckGain * (muted ? 0 : 1)
    }

    /// 试听让路：总推子再乘这么多（1 = 不让）。
    func duck(_ gain: Float) {
        run.settle()
        duckGain = gain
        engine.mainMixerNode.outputVolume = config.master * gain * (muted ? 0 : 1)
    }

    /// 整个引擎静音（冒烟用）：总推子照常算，输出不出声卡。
    private var muted = false
    func mute() {
        run.settle()
        muted = true
        engine.mainMixerNode.outputVolume = 0
    }

    /// 同样的轨、同样的段、每段同样的几何（在时间线哪一段出声、从素材哪一秒起、倍速、文件），而且每段有没有场景也一样
    ///（`Segment.structure`：这些在开流时就抄死了，有一项不同就得重开流；只有增益、场景的参数、推子能在流活着时换）。
    /// 2026-10-01 到 10-06 只比 clipID 的顺序：挪一段 / 裁头尾 / 变速 / 换文件之后 `replace` 走了 `updateGains`，画面挪了、
    /// 声音还按旧位置出（docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md）；自检第 13 组钉着。
    static func sameStructure(_ a: AudioEngineConfig, _ b: AudioEngineConfig) -> Bool {
        guard a.tracks.count == b.tracks.count else { return false }
        return zip(a.tracks, b.tracks).allSatisfy { x, y in
            x.name == y.name && x.segments.map(\.structure) == y.segments.map(\.structure)
        }
    }

    // MARK: 实时：起、收、空闲时停、再起

    /// 起图、起各轨的喂样线程；一开始停在 0。
    func start() throws {
        precondition(mode == .realtime)
        try engine.start()
        running = true
        run.state = .running
        startFeeders()
    }

    /// 整个引擎收掉（关工程、摘预览）：之后不再用它。
    func stop() {
        run.settle()
        running = false
        run.state = .stopped
        for unit in units { unit.feeder.stop() }
        engine.stop()
    }

    private func startFeeders() {
        let resting = run.state == .suspended
        for unit in units {
            unit.feeder.rest(resting)
            unit.feeder.start { [weak self] in
                guard let self else { return 0 }
                return frames(of: anchor.load())
            }
        }
    }

    /// 故意把图的 IO 停掉（空闲：没有声音要出，或者停着没人用了）：声卡放手 —— coreaudiod 不再拦系统空闲睡眠、App Nap
    /// 才生效（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。节点、流、播放头、播放状态都留着；
    /// 喂样线程不再每 50 ms 醒一次。在播时（没有声音的时间线照样能播）播放头改按 host 时间走，位置不跳。
    /// 再起：`wake()`（用户回来了，先在后台起好），或者时钟开播前 / 播放中每拍调的 `recoverIfNeeded()`（要出声了，当场起）。
    func suspend() {
        run.settle()
        guard run.state == .running else { return }
        engine.pause()
        run.state = .suspended
        // 图刚停：最近一拍的位置 + 这一拍里已经过去的那一截。之后时钟没有数，在播的锚点改成待钉（按 host 时间走）。
        let frame = Int64((max(0, playhead) * Self.sampleRate).rounded())
        let wasPlaying = isPlaying
        renderClock.reset()
        publishAnchor(frame, playing: wasPlaying)
        for unit in units { unit.feeder.rest(true) }
    }

    /// 把故意停着的图**提前**起回来（用户回到 SkyCut 动了一下，还没按播放）：在后台那条队列上起，马上回来。
    /// 冷的声卡起一次要 0.15–0.3 秒（M1 内置扬声器，2026-11-11），而且起的这段时间里**整个进程**都被拖住（哪条线程起都一样，
    /// 裸 HAL 也一样）—— 所以要赶在按播放之前起：按下去的时候图已经在跑，和一直开着一样。
    /// 没起来（没有能用的输出设备）：图还是故意停着的样子 —— 喂样线程接着歇、声卡没占着，告诉管空闲的那一位别一直重试；
    /// 时钟再要声音时当场起、拿到真的错误。
    func wake() {
        guard run.state == .suspended else { return }
        for unit in units { unit.feeder.rest(false) }
        let engine = self.engine, start = startGraph
        run.startInBackground({ try start(engine) }, failed: { [weak self] in self?.wakeFailed() })
        onWake?()
    }

    /// 后台那一次没起来（回到主线程上收拾）：状态已经回到故意停着；喂样线程重新歇下，不然它们从此每 50 ms 白醒一次。
    private func wakeFailed() {
        guard run.state == .suspended else { return }   // 这当口时钟已经当场把图起起来了：不用收拾
        for unit in units { unit.feeder.rest(true) }
        onWakeFailed?()
    }

    /// 时钟开播前和播放中每拍都调（PlayerClock）：要出声了，图得在跑。回 true = 图被别人停掉过、刚重启（时钟要重新对画面）。
    /// 1. 故意停着的（空闲）、有声音要出：**当场起**（在调用方的线程上等声卡起来，0.15–0.3 秒）。不先让播放头按 host 时间走：
    ///    起声卡时整个进程都被拖住，界面这会儿本来就不动；先走的话这一截画面和声音就被跳过去了。等它起来再从原处开播，一帧不少。
    ///    没有声音的时间线不起图，播放头一直按 host 时间走，声卡不用开。
    /// 2. 后台正在起（用户刚动了一下就按了播放）：等它起完。
    /// 3. 被系统停掉的（输出设备换采样率 / 声道时系统会停图，但锚点的 playing 仍然为 true）：
    ///    当场重启，回 true；起不来抛错，时钟停播。不在音频系统的配置通知回调里拆图。mainMixer 到 output 没写死格式，
    ///    重新 start 会跟随当前设备。手动渲染模式也走这里，自检无需声卡就能验证重启之后的时间连续性。
    @discardableResult
    func recoverIfNeeded() throws -> Bool {
        if run.state == .starting { run.settle() }
        if run.state == .suspended {
            guard config.hasSound else { return false }
            for unit in units { unit.feeder.rest(false) }
            do {
                try startGraph(engine)
            } catch {
                for unit in units { unit.feeder.rest(true) }   // 没起来：还是故意停着的样子
                throw error
            }
            run.state = .running
            onWake?()
            return false
        }
        guard !engine.isRunning else { return false }
        let seconds = playhead
        let wasPlaying = isPlaying
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        // 重启后的采样时间不能指望（手动渲染从 0 重来，真声卡上接着往下走）：旧的采样 / host 时间不带过去，
        // 重启之后发的在播锚点是待钉的，由第一拍渲染钉上 —— 不然播放头要么等着追上旧采样数，要么一下跳出去老远。
        renderClock.reset()
        anchor.publish(PlaybackAnchor(position: frame, sampleTime: 0, playing: false))
        try startGraph(engine)
        run.state = .running
        if mode == .realtime {
            running = true
            startFeeders()
        }
        if wasPlaying { play(from: seconds) } else { seek(to: seconds) }
        return true
    }

    // MARK: 实时：播放头只是几个数

    var isPlaying: Bool { anchor.load()?.playing ?? false }

    /// 此刻播放头在时间线的第几秒：最近一拍的位置，再按 host 时间补上这一拍已经过去的那一截；停着就是锚点；
    /// 在播但锚点还没钉上（图还在起、或者没有声音所以故意停着）按 host 时间走。
    var playhead: Double {
        guard let anchor = anchor.load() else { return 0 }
        guard anchor.playing else { return Double(anchor.position) / Self.sampleRate }
        guard let start = anchor.sampleTime else {
            return Double(anchor.position + anchor.framesElapsed(until: mach_absolute_time())) / Self.sampleRate
        }
        var position = Double(anchor.position + max(0, currentSampleTime - start))
        let host = renderClock.hostTime.load(ordering: .relaxed)
        if host > 0 {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: host)
            let quantum = Double(renderClock.quantum.load(ordering: .relaxed)) / Self.sampleRate
            position += min(max(0, elapsed), quantum * 2) * Self.sampleRate
        }
        return position / Self.sampleRate
    }

    /// 从 `seconds` 起播（锚点钉在下一拍上，第一拍就是这儿的声音）。
    func play(from seconds: Double) {
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        publishAnchor(frame, playing: true)
        for unit in units { unit.feeder.seek(toFrame: frame) }
    }

    /// 从锚点停着的地方接着播。
    func resume() {
        publishAnchor(anchor.load()?.position ?? 0, playing: true)
    }

    func pause() {
        if isPlaying { stoppedPlayingAt = ProcessInfo.processInfo.systemUptime }
        anchor.publish(PlaybackAnchor(position: frames(of: anchor.load()), sampleTime: currentSampleTime, playing: false))
    }

    func seek(to seconds: Double) {
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        publishAnchor(frame, playing: isPlaying)
        for unit in units { unit.feeder.seek(toFrame: frame) }
    }

    /// 自检用：喂样线程是不是都歇着（图故意停着时该歇着；后台起图没起来之后也要歇回去）。
    var feedersResting: Bool { units.allSatisfy(\.feeder.isResting) }

    /// 自检和实测用（量「按下播放到第一拍」）：在播的锚点被渲染块渲到了没有；渲到了给最近一拍出声卡的 host 时间。
    var renderedHostTime: UInt64? {
        guard let anchor = anchor.load(), anchor.playing, let start = anchor.sampleTime,
              renderClock.hasTicked, currentSampleTime >= start else { return nil }
        return renderClock.hostTime.load(ordering: .relaxed)
    }

    /// 发布一个新锚点。在播的：时钟有数（图在跑、渲染块报过时间）就钉在下一拍上；没有数（图刚起、停着）发待钉的，
    /// 第一拍渲染把它钉上。图没在跑的时候（没有声音所以故意停着、或者播着的时候图正在起回来）待钉的锚点带上此刻的
    /// host 时间：钉上之前播放头按它走，钉的时候把过去的这一截算进去。图在跑（刚起、还没报过时间）就不带：钉在第一拍、
    /// 位置不动，和平时「钉在下一拍上」是一回事。离线渲染没有 host 时间。
    private func publishAnchor(_ frame: Int64, playing: Bool) {
        if playing, !renderClock.hasTicked {
            let onHostClock = mode == .realtime && run.state != .running
            anchor.publish(.pending(position: frame, hostTime: onHostClock ? mach_absolute_time() : 0, playing: true))
        } else {
            anchor.publish(PlaybackAnchor(position: frame, sampleTime: nextQuantumSampleTime, playing: playing))
        }
    }

    /// 最近一拍的采样时间（渲染块记的，节点的 48 kHz 域）。
    private var currentSampleTime: Int64 { renderClock.sampleTime.load(ordering: .relaxed) }

    /// 下一拍的采样时间：最近一拍的起点加上它的长度。
    private var nextQuantumSampleTime: Int64 {
        currentSampleTime + Int64(renderClock.quantum.load(ordering: .relaxed))
    }

    /// 此刻时间线的第几帧（到最近一拍为止；在播但还没钉上的锚点按 host 时间）。喂样线程也调它。
    private func frames(of anchor: PlaybackAnchor?) -> Int64 {
        guard let anchor else { return 0 }
        guard anchor.playing else { return anchor.position }
        guard let start = anchor.sampleTime else { return anchor.position + anchor.framesElapsed(until: mach_absolute_time()) }
        return anchor.position + max(0, currentSampleTime - start)
    }
}

/// `PlayerClock` 通过这个协议驱动引擎（AudioEngine/PlaybackAudioSource.swift）。
extension TimelineAudioEngine: PlaybackAudioSource {}
