import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 声音怎么过一刀：请求（纯值）
//
// 管什么：set_transition 的 `sound`（声音过切点的几种过法，2026-11-16 MCP-32）—— 词表、每种默认几帧、一次请求带什么。
// 帧数按工程帧率换成秒（`TimelineState.frameRate`，不写死帧率）。
// 不管什么：切点在哪、两边的声音是谁（CutSoundCut）、怎么改时间线（CutSoundPlanner）、量声音（CutSoundMeasure）。
// 规矩和每种过法为什么这样定见 docs/architecture/cut-sound.md。

/// 声音怎么过一刀（词表 = `MCPVocabulary.cutSounds`，自检对账）。画面一律不动。
enum CutSoundMode: String, CaseIterable {
    /// 叠着换：两边的声音在切点前后各叠 N 帧，交叉渐变（整段重叠 2N 帧）。Equal power by default (a bump drawn on each volume
    /// curve, CutSoundCurves); two pieces of one continuous take stay linear (2026-11-16 decision).
    case crossfade
    /// 先进（J）：下一个镜头的声音提前 N 帧、在这 N 帧里淡进来；上一个镜头的声音不动。
    case lead
    /// 拖后（L）：上一个镜头的声音拖过切点 N 帧、在这 N 帧里淡掉；下一个镜头的声音不动。
    case lag
    /// 垫一层底：一层连续的声音（音乐、环境）在切点两边各铺 N 帧. The bed is raised around the cut until it is within 6 dB
    /// of the louder side; only what the volume limit leaves uncovered comes off the loud side (2026-11-16 decision).
    case bed
    /// 落在拍子上硬换：声音一刀切，切口挪到 ±N 帧里最近的一拍上（画面的切点不动）。
    case onBeat = "on_beat"
    /// 调增益：with gain_db the next shot's sound moves by it; without, the louder side comes down to the quieter one's level
    /// (2026-11-16 decision: keeps headroom, never lifts noise).
    case gain
    /// 回到一刀切：两边的声音都正好断在画面的切点上，没有渐变。
    case cut

    /// 不给 `frames` 时用几秒（按工程帧率换成帧）。nil = 这种过法不用帧数。
    /// 出处：真人南极正片 45 刀（joins-human.md，24 帧/秒剪的）里先进的中位数 16 帧、拖过的中位数 21 帧；
    /// 「从下面穿过去」= 两边都待 2 秒以上；音乐重音在 ±8 帧以内算跟上（W15 预览板检查的口径）。
    var defaultSeconds: Double? {
        switch self {
        case .crossfade: return 0.25
        case .lead: return 0.667
        case .lag: return 0.875
        case .bed: return 2
        case .onBeat: return 0.333
        case .gain, .cut: return nil
        }
    }

    /// 至少几帧：叠、先进、拖后、垫底没有 0 帧这回事（0 帧就是一刀切，用 cut）。
    var minimumFrames: Int {
        switch self {
        case .crossfade, .lead, .lag, .bed: return 1
        case .onBeat, .gain, .cut: return 0
        }
    }

    var usesFrames: Bool { defaultSeconds != nil }
}

/// 一次请求：哪种过法、几帧、要不要顺手调一边的增益、拿哪一层当底 / 找拍子。
struct CutSoundRequest: Equatable {
    var mode: CutSoundMode
    /// 帧数（工程帧率）；nil = 按 `defaultSeconds`。
    var frames: Int?
    /// 增益（dB）：gain 给了就照这个调下一个镜头的声音（not given: the louder side comes down）；lead / crossfade / on_beat / cut 调下一个、
    /// lag 调上一个。bed 不收（它自己按底压两边）。
    var gainDB: Double?
    /// bed：铺在底下的那一层；on_beat：找拍子的那段音乐。nil = 跨过切点最长的那段声音。
    var layer: UUID?

    static let maximumFrames = 600

    /// 实际用的帧数（没给就按默认秒数换算，至少 `minimumFrames`）。
    func resolvedFrames(_ rate: ProjectFrameRate) -> Int {
        if let frames { return frames }
        guard let seconds = mode.defaultSeconds else { return 0 }
        return max(mode.minimumFrames, Int((seconds * Double(rate.fps)).rounded()))
    }
}

/// 帧 ↔ 秒（工程帧率）。
enum CutSoundFrames {
    static func seconds(_ frames: Int, _ rate: ProjectFrameRate) -> Double {
        Double(frames) * rate.secondsPerFrame
    }

    /// 这么多秒里放得下几整帧（往下取整，留一点浮点余量）。
    static func whole(_ seconds: Double, _ rate: ProjectFrameRate) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * Double(rate.fps) + 1e-6).rounded(.down))
    }

    /// 秒换成帧（四舍五入，给结果看）。
    static func nearest(_ seconds: Double, _ rate: ProjectFrameRate) -> Int {
        Int((seconds * Double(rate.fps)).rounded())
    }
}

// MARK: 参数

extension CutSoundRequest {
    /// set_transition 带 sound 时的参数：词表、帧数的范围（过法不用帧数的不收）、增益的范围（bed 不收）、layer_id（只给 bed / on_beat）；
    /// 和 type / duration 一起给就整个不做（画面的转场另调一次）。
    static func read(_ args: AIToolArguments, _ state: TimelineState) throws -> CutSoundRequest {
        guard let raw = try args.choice("sound", from: MCPVocabulary.cutSounds), let mode = CutSoundMode(rawValue: raw) else {
            throw AIToolError("sound is required here.")
        }
        if args.has("type") || args.has("duration") {
            throw AIToolError(
                "sound changes only how the sound crosses the cut; type / duration set a picture transition. Make two calls: one "
                    + "with type, one with sound. Nothing was changed."
            )
        }
        let frames = try args.int("frames")
        if let frames {
            guard mode.usesFrames else {
                throw AIToolError("frames does not apply to sound=\(mode.rawValue). Leave it out. Nothing was changed.")
            }
            try AIEditLimits.require("frames", Double(frames), in: Double(mode.minimumFrames)...Double(CutSoundRequest.maximumFrames))
        }
        let gain = try args.double("gain_db")
        if gain != nil, mode == .bed {
            throw AIToolError("gain_db does not apply to sound=bed: the bed sets the two sides' levels itself. Use sound=gain in another call.")
        }
        let span = AudioGain.maximumDB - AudioGain.minimumDB
        try AIEditLimits.require("gain_db", gain, in: -span...span)
        let layerText = try args.string("layer_id")
        if layerText != nil, mode != .bed, mode != .onBeat {
            throw AIToolError("layer_id is only for sound=bed or sound=on_beat. Nothing was changed.")
        }
        let layer = try layerText.map { try AIShortIDs(state: state).resolve($0) }
        return CutSoundRequest(mode: mode, frames: frames, gainDB: gain, layer: layer)
    }
}
