import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen mix=true 要量什么（纯值）
//
// 管什么：AI 给的参数 → 量时间线的哪几帧（按工程帧率）、分哪几层、要不要逐帧的数；参数核对和合法建议
//（docs/architecture/mcp-edit-parameters.md：越界拒绝、给一个能用的值）。
// 层的写法（`layers`，一项一层）：一条轨（"A1"），几条轨用 + 连起来（"V1+V2"），或 "rest"（没点名的、其余有声音的轨）。
// 只认此刻在混音里出声的轨（V1 = 主轨自己的声音；藏起来、静音、没有声音的轨不在混音里）。不给就每条有声音的轨一层，
// 多过 `maxLayers` 条时最后几条并成 rest。给了 clip_id：量这一段在时间线上的那几秒，默认分成「它那条轨」和 rest 两层。
// 逐帧的数（`frames=true`）一次最多 `maxFrameValues` 个：混音每帧 4 个、每层每帧 5 个，层越多能要的帧越少；超了拒绝，
// 给一个放得下的 `to`。
// 不管什么：怎么渲、怎么量（MixMeasurement）、结果怎么写（AIListenMixReport）、任务和排队（AIListenMix）。

struct AIListenMixPlan: Sendable {
    let grid: MixFrameGrid
    /// 量哪几帧（时间线的第几帧）。
    let frames: Range<Int>
    let layers: [AudioStemLayer]
    /// 要不要逐帧的数。
    let perFrame: Bool
    let silenceDB: Double
    let minSilence: Double
    /// 时间线总长（秒）。
    let duration: Double

    /// 一次最多分几层（每层多渲一遍）。
    static let maxLayers = 12
    /// 逐帧的数一次最多回多少个（约 10 KB 的 JSON，AI 一次读得完）。
    static let maxFrameValues = 2_400
    /// 每帧：混音 4 个（电平、峰值、瞬时响度、限幅压了多少），每层 5 个（电平、四个频段）。
    static let mixValuesPerFrame = 4
    static let layerValuesPerFrame = 5
    static let rest = "rest"

    // MARK: 入口

    static func make(
        _ args: AIToolArguments, state: TimelineState, config: AudioEngineConfig,
        from requestedFrom: Double?, to requestedTo: Double?, silenceDB: Double, minSilence: Double
    ) throws -> AIListenMixPlan {
        let grid = MixFrameGrid(fps: state.frameRate.fps)
        var from = requestedFrom, to = requestedTo
        var defaultLayers: [String]?
        if let clipText = try args.string("clip_id") {
            let ids = AIShortIDs(state: state)
            let id = try ids.resolve(clipText)
            guard let clip = state.clip(with: id) else { throw AIToolError("\(clipText) is not a clip.") }
            from = max(from ?? clip.timelineStart, clip.timelineStart)
            to = min(to ?? clip.timelineEnd, clip.timelineEnd)
            if let slot = state.location(of: id)?.track {
                let own = AITrackName.name(of: slot)
                if audibleNames(config).contains(own) { defaultLayers = [own, rest] }
            }
        }
        let frames = try frameRange(grid: grid, config: config, from: from ?? 0, to: to)
        let specs = try args.stringArray("layers") ?? defaultLayers
        let layers = try layers(specs, config: config, state: state)
        let perFrame = try args.bool("frames") ?? false
        if perFrame { try checkFrameBudget(grid: grid, frames: frames, layers: layers.count, from: from ?? 0, to: to) }
        return AIListenMixPlan(
            grid: grid, frames: frames, layers: layers, perFrame: perFrame,
            silenceDB: silenceDB, minSilence: minSilence, duration: config.duration
        )
    }

    // MARK: 范围

    private static func frameRange(grid: MixFrameGrid, config: AudioEngineConfig, from: Double, to: Double?) throws -> Range<Int> {
        let total = MixMeasurement.frameCount(config, grid: grid)
        let lastStart = grid.seconds(ofFrame: max(0, total - 1))
        guard from <= lastStart + 1e-9 else {
            throw invalid("from", from, maximum: lastStart, message: String(
                format: "from is after the end: the timeline is %.3f s long, its last frame starts at %.3f s.", config.duration, lastStart
            ))
        }
        let first = grid.frame(containing: from)
        let end = min(total, grid.frame(endingAt: min(to ?? config.duration, config.duration)))
        guard end > first else { throw AIToolError("Nothing to measure between from and to.") }
        return first ..< end
    }

    /// 逐帧的数放不放得下：放不下就拒绝，给一个放得下的 `to`。
    private static func checkFrameBudget(grid: MixFrameGrid, frames: Range<Int>, layers: Int, from: Double, to: Double?) throws {
        let perFrame = mixValuesPerFrame + layerValuesPerFrame * layers
        let allowed = max(1, maxFrameValues / perFrame)
        guard frames.count > allowed else { return }
        let maximum = grid.seconds(ofFrame: frames.lowerBound + allowed)
        throw invalid("to", to ?? grid.seconds(ofFrame: frames.upperBound), maximum: maximum, message: String(
            format: "frames=true returns at most %d numbers: with %d layer(s) that is %d frames (%.3f s at %d fps). "
                + "Use to=%.3f, or name fewer layers.",
            maxFrameValues, layers, allowed, Double(allowed) / Double(grid.fps), grid.fps, maximum
        ))
    }

    // MARK: 层

    /// 配置里的轨在 AI 那边叫什么：主轨（配置里叫 main）是 V1，其余 V2… / A1… 照旧。
    static func aiName(_ track: AudioEngineConfig.Track) -> String { track.name == "main" ? "V1" : track.name }

    /// 此刻在混音里出声的轨（AI 的叫法，顺序同配置：V1、V2…、A1…）。
    static func audibleNames(_ config: AudioEngineConfig) -> [String] { config.tracks.map(aiName) }

    static func layers(_ specs: [String]?, config: AudioEngineConfig, state: TimelineState) throws -> [AudioStemLayer] {
        let names = audibleNames(config)
        guard let specs, !specs.isEmpty else { return defaultLayers(names) }
        guard specs.count <= maxLayers else {
            throw AIToolError("layers takes at most \(maxLayers) entries; join tracks with + (\"A1+A2\") or use \"rest\".")
        }
        var used = Set<Int>()
        var parsed: [(name: String, tracks: [Int]?)] = []
        for spec in specs {
            let parts = spec.split(separator: "+").map { normalized(String($0)) }
            guard !parts.isEmpty, !parts.contains("") else { throw AIToolError("\"\(spec)\" is not a layer: use A1, V1+V2 or rest.") }
            if parts.contains(rest) {
                guard parts.count == 1, !parsed.contains(where: { $0.tracks == nil }) else {
                    throw AIToolError("rest stands alone and only once in layers (it is every audible track not named elsewhere).")
                }
                parsed.append((rest, nil))
                continue
            }
            var tracks: [Int] = []
            for part in parts {
                guard let index = names.firstIndex(of: part) else { throw notAudible(part, names: names, state: state) }
                guard used.insert(index).inserted else { throw AIToolError("\(part) is in more than one layer.") }
                tracks.append(index)
            }
            parsed.append((parts.joined(separator: "+"), tracks.sorted()))
        }
        return try parsed.map { entry in
            if let tracks = entry.tracks { return AudioStemLayer(name: entry.name, tracks: tracks) }
            let others = names.indices.filter { !used.contains($0) }
            guard !others.isEmpty else { throw AIToolError("rest has nothing left: every audible track is already named.") }
            return AudioStemLayer(name: rest, tracks: others)
        }
    }

    /// 不给 layers：每条有声音的轨一层；多过上限时最后几条并成 rest。
    private static func defaultLayers(_ names: [String]) -> [AudioStemLayer] {
        guard names.count > maxLayers else {
            return names.indices.map { AudioStemLayer(name: names[$0], tracks: [$0]) }
        }
        let singles = (0 ..< maxLayers - 1).map { AudioStemLayer(name: names[$0], tracks: [$0]) }
        return singles + [AudioStemLayer(name: rest, tracks: Array(maxLayers - 1 ..< names.count))]
    }

    /// "a1" / "Main" / " v2 " → "A1" / "V1" / "V2"；rest 照旧。
    private static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == rest { return rest }
        if trimmed.lowercased() == "main" { return "V1" }
        return trimmed.uppercased()
    }

    /// 点名的轨不在混音里：没有这条轨，还是有这条轨但不出声（藏起来、静音、上面没有带声音的段）。
    private static func notAudible(_ name: String, names: [String], state: TimelineState) -> AIToolError {
        let audible = names.joined(separator: ", ")
        let exists: Bool
        if name == "V1" {
            exists = true
        } else if let number = Int(name.dropFirst()), name.first == "V" {
            exists = number >= 2 && number - 2 < state.overlayTracks.count
        } else if let number = Int(name.dropFirst()), name.first == "A" {
            exists = number >= 1 && number - 1 < state.audioTracks.count
        } else {
            exists = false
        }
        return AIToolError(exists
            ? "\(name) makes no sound in the mix (hidden, muted, or no clip with sound). Tracks in the mix: \(audible)."
            : "There is no track \(name). Tracks in the mix: \(audible); or use rest.")
    }

    // MARK: 报错

    /// 越界：拒绝、给一个能用的值（同 AIEditLimits.invalid 的结构：status / parameter / requested / allowed / suggested，
    /// 只是话按 listen 说）。
    private static func invalid(_ field: String, _ requested: Double, maximum: Double, message: String) -> AIToolError {
        let suggested = JSONValue.number((maximum * 1000).rounded(.down) / 1000)
        return AIToolError(message, details: [
            "status": "invalid_parameter", "parameter": .string(field),
            "requested": requested.isFinite ? .number(requested) : .string(String(describing: requested)),
            "allowed": ["minimum": 0, "maximum": suggested], "suggested": suggested, "retryable": false
        ])
    }
}
