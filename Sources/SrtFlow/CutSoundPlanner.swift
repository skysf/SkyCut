import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 声音怎么过一刀：一刀怎么改（纯值）
//
// 管什么：一种过法落到时间线上 —— 哪一边的声音要挪（画面自己带着的先分出去）、挪到哪一刻、渐变多长、余料够不够（不够就
// 照实报「最多 N 帧」、什么都不改，不悄悄改小）、顺手调哪一边的增益。画面一帧不动。
// 叠着换 / 先进 / 拖后 / 一刀切 / 落在拍子上在这里；量电平的两种（调增益、垫底）在 CutSoundLevelPlan。
// 每一刀改完，挪过的声音撞上同一条轨的就另找一条（CutSoundEdges.settle）。
// 不管什么：哪一刀（CutSoundCut）、量声音 / 找拍子（CutSoundMeasure，App 那一层）、结果怎么写（CutSoundReport）。
// 规矩见 docs/architecture/cut-sound.md。

/// 一刀做完记下的事（时间、渐变、轨道由 CutSoundReport 按最后的工程读）。
struct CutSoundOutcome {
    struct Gain: Equatable {
        var clip: UUID
        var requested: Double
        var applied: Double
    }

    struct Beat: Equatable {
        var at: Double
        var offsetFrames: Int
        var music: UUID
    }

    struct Bed: Equatable {
        var clip: UUID
        var extendedBefore: Int
        var extendedAfter: Int
        /// How much the bed was raised at the cut (dB, 0 = it already carried the cut).
        var raised = 0.0
    }

    /// 两边和底在切点附近听到的电平（dB：素材 + 段的音量线 + 推子），没量就是 nil。
    struct Levels: Equatable {
        var outgoing: Double?
        var incoming: Double?
        var bed: Double?
    }

    var cut: CutSoundCut
    var mode: CutSoundMode
    var frames: Int?
    /// 两边的声音现在在哪段（画面自己，或分出去的那段）；没声音的一边是 nil。
    var outgoing: UUID?
    var incoming: UUID?
    /// 这次新分出去的声音 → 它的画面。
    var separated: [UUID: UUID] = [:]
    var gains: [Gain] = []
    var beat: Beat?
    var bed: Bed?
    var levels: Levels?
    /// crossfade only: "equal_power", or "linear" for two pieces of one continuous take (those sum exactly with linear fades).
    var crossfadeShape: String?
    var notes: [String] = []
}

enum CutSoundPlanner {
    /// 量出来的**素材**电平（dB：文件本身在测量窗里的均方，不含段的音量、推子）。nil = 没量、或那里没声音。
    struct Material: Equatable {
        var outgoing: Double?
        var incoming: Double?
        var layer: Double?
    }

    /// 两边各是哪一头挨着切点。
    enum Side { case outgoing, incoming }

    /// 「这一边没有声音」的报错带的 status。
    static let noSoundStatus = "no_sound"

    /// 一刀要的外部输入：bed / on_beat 的那一层、量好的素材电平、拍子（App 那一层量好传进来）。
    struct Inputs {
        var layer: EditClip?
        var material = Material()
        var beats: [Double] = []
    }

    /// 几刀一起做（一步撤销）：有一刀做不到整个不做（报错点名第几刀）；`skipsSilent`（all=true）时缺声音的那几刀跳过、记下。
    static func run(
        _ request: CutSoundRequest, cuts: [CutSoundCut], inputs: [Inputs], skipsSilent: Bool, in state: inout TimelineState
    ) throws -> (outcomes: [CutSoundOutcome], skipped: [UUID]) {
        if request.mode == .gain, request.gainDB == nil, cuts.count > 1 {
            return try CutSoundBatchGain.run(request, cuts: cuts, inputs: inputs, skipsSilent: skipsSilent, in: &state)
        }
        let original = state
        var next = state
        var outcomes: [CutSoundOutcome] = []
        var skipped: [UUID] = []
        for (index, cut) in cuts.enumerated() {
            let input = inputs.indices.contains(index) ? inputs[index] : Inputs()
            do {
                outcomes.append(try apply(
                    request, at: cut, layer: input.layer, material: input.material, beats: input.beats, original: original, in: &next
                ))
            } catch let error as AIToolError where skipsSilent && error.details["status"]?.stringValue == noSoundStatus {
                skipped.append(cut.outgoing.id)
            } catch let error as AIToolError where cuts.count > 1 {
                let name = cut.outgoing.name
                throw AIToolError("Cut after \(name) (\(index + 1) of \(cuts.count)): \(error.message)", details: error.details)
            }
        }
        guard !outcomes.isEmpty else {
            throw AIToolError("None of these cuts has sound on the side this join needs. Nothing was changed.")
        }
        state = next
        return (outcomes, skipped)
    }

    /// 一刀。`original`：这次调用之前的工程（分离时量「此刻实际响的样子」用）；`beats`：on_beat 那段音乐的拍子（时间线秒）。
    static func apply(
        _ request: CutSoundRequest, at cut: CutSoundCut, layer: EditClip?, material: Material, beats: [Double],
        original: TimelineState, in state: inout TimelineState
    ) throws -> CutSoundOutcome {
        var work = Work(request: request, cut: cut, original: original, state: state)
        switch request.mode {
        case .crossfade: try work.crossfade()
        case .lead: try work.lead()
        case .lag: try work.lag()
        case .cut: try work.hardCut(at: cut.time, offset: 0)
        case .onBeat: try work.onBeat(beats, music: layer)
        case .gain: try CutSoundLevelPlan.gain(&work, material: material)
        case .bed: try CutSoundLevelPlan.bed(&work, layer: layer, material: material)
        }
        if let gain = request.gainDB, request.mode != .gain, request.mode != .bed {
            try work.shiftGain(of: request.mode == .lag ? .outgoing : .incoming, by: gain)
        }
        work.outcome.outgoing = work.voice(.outgoing)?.id
        work.outcome.incoming = work.voice(.incoming)?.id
        CutSoundEdges.settle(work.touched, in: &work.state)
        state = work.state
        return work.outcome
    }

    /// 一刀改到一半的工作区：当下的工程、记下的结果、改过的声音。
    struct Work {
        let request: CutSoundRequest
        let cut: CutSoundCut
        let original: TimelineState
        var state: TimelineState
        var outcome: CutSoundOutcome
        /// 改过的声音段（改完一起让路）。
        var touched: Set<UUID> = []

        init(request: CutSoundRequest, cut: CutSoundCut, original: TimelineState, state: TimelineState) {
            self.request = request
            self.cut = cut
            self.original = original
            self.state = state
            let frames = request.mode.usesFrames ? request.resolvedFrames(state.frameRate) : nil
            outcome = CutSoundOutcome(cut: cut, mode: request.mode, frames: frames)
        }

        var frames: Int { outcome.frames ?? 0 }
        var rate: ProjectFrameRate { state.frameRate }
        var spf: Double { rate.secondsPerFrame }
        var time: Double { cut.time }

        /// 一边的画面（当下的那一份：前面几刀可能已经把它静音、分过声音）。
        func picture(_ side: Side) -> EditClip {
            let original = side == .outgoing ? cut.outgoing : cut.incoming
            return state.clip(with: original.id) ?? original
        }

        func voice(_ side: Side) -> CutSoundVoice? { CutSoundCut.voice(of: picture(side), in: state) }

        func sound(_ side: Side) -> EditClip? { voice(side).flatMap { state.clip(with: $0.id) } }

        func requireSound(_ side: Side) throws -> EditClip {
            guard let clip = sound(side) else { throw noSound(side) }
            return clip
        }

        /// 这一边没有声音（静音的视频、图片、藏着的轨）。all=true 时这样的刀跳过、报出来（`status` 认它），点名的那一刀照实报错。
        func noSound(_ side: Side) -> AIToolError {
            AIToolError(
                "\(picture(side).name) (\(side == .outgoing ? "before" : "after") the cut) has no sound to move: it is muted, silent "
                    + "or a picture. Use \(side == .outgoing ? "lead" : "lag") for the other side, or a bed. Nothing was changed.",
                details: ["status": .string(CutSoundPlanner.noSoundStatus), "retryable": false]
            )
        }

        /// 要挪这一边的声音：画面自己带着的先分出去（另一头照它此刻实际响的样子），返回放声音的那段。
        mutating func movable(_ side: Side) throws -> UUID {
            guard let voice = voice(side) else { throw noSound(side) }
            guard voice.embedded else {
                clearCrossfadeCurve(side, of: voice.id)
                touched.insert(voice.id)
                return voice.id
            }
            let picture = picture(side)
            guard let id = CutSoundEdges.separate(picture, keeping: side == .outgoing ? .start : .end, from: original, in: &state) else {
                throw noSound(side)
            }
            outcome.separated[id] = picture.id
            touched.insert(id)
            return id
        }

        // MARK: 叠着换 / 先进 / 拖后

        mutating func crossfade() throws {
            let out = try requireSound(.outgoing)
            let into = try requireSound(.incoming)
            try CutSoundLimits.check(frames, request.mode, [
                CutSoundLimits.after(out, picture(.outgoing), at: time, rate),
                CutSoundLimits.before(into, picture(.incoming), at: time, rate),
                CutSoundLimits.shot(.incoming, cut, rate), CutSoundLimits.shot(.outgoing, cut, rate)
            ])
            let reach = Double(frames) * spf
            let o = try movable(.outgoing)
            let i = try movable(.incoming)
            CutSoundEdges.set(.end, of: o, to: time + reach, fade: 2 * reach, in: &state)
            CutSoundEdges.set(.start, of: i, to: time - reach, fade: 2 * reach, in: &state)
            // Equal power by default (2026-11-16 decision): a bump on each curve turns the linear fades into cos / sin, so two
            // different sounds keep their loudness through the middle. One continuous take stays linear: it sums exactly.
            guard !continuousTake(o, i) else { outcome.crossfadeShape = "linear"; return }
            CutSoundCurves.shapeCrossfade(o, from: time - reach, to: time + reach, incoming: false, in: &state)
            CutSoundCurves.shapeCrossfade(i, from: time - reach, to: time + reach, incoming: true, in: &state)
            outcome.crossfadeShape = "equal_power"
        }

        /// Both sounds read the same file and the next one carries on where the previous one is at the cut.
        private func continuousTake(_ outgoing: UUID, _ incoming: UUID) -> Bool {
            guard let a = state.clip(with: outgoing), let b = state.clip(with: incoming), a.sourceURL == b.sourceURL,
                  abs(a.speed - b.speed) < 1e-9 else { return false }
            return abs(a.sourceTime(atTimeline: time) - b.sourceTime(atTimeline: time)) < 0.001
        }

        /// Setting an edge again: if it still carries a crossfade (fade = twice its overhang past the cut), the bump that crossfade
        /// drew into the curve goes first, so a join never stacks on the previous one.
        private mutating func clearCrossfadeCurve(_ side: Side, of id: UUID) {
            guard let clip = state.clip(with: id), !clip.volumeCurve.isEmpty else { return }
            let overhang = side == .outgoing ? clip.timelineEnd - time : time - clip.timelineStart
            let fade = side == .outgoing ? clip.fadeOutDuration : clip.fadeInDuration
            guard overhang > 1e-6, abs(fade - 2 * overhang) < 1e-6 else { return }
            CutSoundCurves.clear(id, from: time - overhang, to: time + overhang, in: &state)
        }

        mutating func lead() throws {
            let into = try requireSound(.incoming)
            try CutSoundLimits.check(frames, request.mode, [
                CutSoundLimits.before(into, picture(.incoming), at: time, rate), CutSoundLimits.shot(.outgoing, cut, rate)
            ])
            let reach = Double(frames) * spf
            let i = try movable(.incoming)
            CutSoundEdges.set(.start, of: i, to: time - reach, fade: reach, in: &state)
        }

        mutating func lag() throws {
            let out = try requireSound(.outgoing)
            try CutSoundLimits.check(frames, request.mode, [
                CutSoundLimits.after(out, picture(.outgoing), at: time, rate), CutSoundLimits.shot(.incoming, cut, rate)
            ])
            let reach = Double(frames) * spf
            let o = try movable(.outgoing)
            CutSoundEdges.set(.end, of: o, to: time + reach, fade: reach, in: &state)
        }

        // MARK: 一刀切（cut，和 on_beat 落点之后同一个做法）

        /// 两边的声音都断在 `at`、没有渐变。画面带着的声音正好断在切点上、这一刀又没有转场时不用分：只把那一头的渐变清掉。
        mutating func hardCut(at edge: Double, offset: Int) throws {
            guard voice(.outgoing) != nil || voice(.incoming) != nil else { throw noSound(.outgoing) }
            for side in [Side.outgoing, .incoming] {
                guard let voice = voice(side) else { continue }
                if voice.embedded, offset == 0, cut.transition == nil {
                    state.update(voice.id) { side == .outgoing ? ($0.fadeOutDuration = 0) : ($0.fadeInDuration = 0) }
                    continue
                }
                let id = try movable(side)
                CutSoundEdges.set(side == .outgoing ? .end : .start, of: id, to: edge, fade: 0, in: &state)
            }
        }

        // MARK: 落在拍子上硬换

        /// 切口挪到 ±frames 帧里最近的一拍（取整到帧；一样近的取往后的）；挪不过去的拍（余料不够、会把一边裁没）跳过。
        mutating func onBeat(_ beats: [Double], music: EditClip?) throws {
            let window = Double(frames) * spf + spf / 2
            let offsets = beats.map { CutSoundFrames.nearest($0 - time, state.frameRate) }
            let near = zip(beats, offsets).filter { abs($0.0 - time) <= window }
            let usable = near.filter { fits($0.1) }
                .sorted { abs($0.1) != abs($1.1) ? abs($0.1) < abs($1.1) : $0.1 > $1.1 }
            guard let chosen = usable.first else {
                throw CutSoundLimits.noBeat(window: frames, nearest: offsets.min { abs($0) < abs($1) }, blocked: !near.isEmpty)
            }
            try hardCut(at: time + Double(chosen.1) * spf, offset: chosen.1)
            if let music {
                outcome.beat = CutSoundOutcome.Beat(at: chosen.0, offsetFrames: chosen.1, music: music.id)
            }
        }

        /// 声音的切口挪 `offset` 帧做得到吗：往后挪要上一个镜头的声音还有素材、下一个镜头的声音不被裁没；往前挪反过来。
        private func fits(_ offset: Int) -> Bool {
            let edge = time + Double(offset) * spf
            let minimum = TimelineTrim.clipMinimumDuration
            if let out = sound(.outgoing) {
                if offset > 0, CutSoundEdges.roomAfter(out, at: time) < Double(offset) * spf - 1e-6 { return false }
                if edge - out.timelineStart < minimum { return false }
            }
            if let into = sound(.incoming) {
                if offset < 0, CutSoundEdges.roomBefore(into, at: time) < Double(-offset) * spf - 1e-6 { return false }
                if into.timelineEnd - edge < minimum { return false }
            }
            return true
        }

        // MARK: 顺手调一边的增益

        /// 一边的声音整段平移 `delta` dB（有音量曲线就整条平移，同 edit_clip 的 volume_db）；记下要的和实际调了多少（到顶会被夹住）。
        mutating func shiftGain(of side: Side, by delta: Double) throws {
            let clip = try requireSound(side)
            let at = side == .outgoing ? time - CutSoundWindows.middle : time + CutSoundWindows.middle
            let before = clip.volumeLineDecibels(atTimeline: at)
            state.update(clip.id) { $0.shiftWholeVolume(byDecibels: delta) }
            let after = state.clip(with: clip.id)?.volumeLineDecibels(atTimeline: at) ?? before
            outcome.gains.append(CutSoundOutcome.Gain(clip: clip.id, requested: delta, applied: after - before))
        }
    }
}
