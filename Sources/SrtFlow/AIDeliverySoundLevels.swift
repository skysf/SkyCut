import Foundation

// MARK: - The timeline's sound per role group, frame by frame, plus where the music accents fall (blocking)
//
// Owns: one offline render of the export's configuration split by role group (DeliveryStemSplit: place, voice, music, effects;
// each group as it enters the master bus, before the limiter, like listen mix=true) measured per project frame
// (MixMeasurement / MixBandMeter: power and the four bands <300, 300–800, 800–3000, >3000 Hz), the music accents (the rendered
// music group at half the engine's rate, read per music clip with DeliveryMusicAccents, the research's accent reading, kept where
// the music is heard: above `audibleDB`), and the place group above 200 Hz in each cut window (DeliveryWindowCollector, the
// research's brick-wall reading). Readers: window levels in a band, a frame's level, a cut window above 200 Hz.
// Not here: which clip is which role (AIDeliverySoundRoles), the rules that read these levels (AIDeliveryCutJumps,
// AIDeliveryMusicSwell). Only on a MediaReadQueue queue (the engine reads files on the calling thread).

struct AIDeliverySoundLevels: Sendable {
    enum Group: String, CaseIterable, Sendable {
        case place, voice, music, effects

        init(_ role: DeliverySoundRole) {
            switch role {
            case .voice: self = .voice
            case .music: self = .music
            case .effects: self = .effects
            case .ambience, .object, .camera, .other: self = .place
            }
        }
    }

    enum Band: Sendable {
        /// Everything.
        case full
        /// Above 300 Hz: a rumble under both sides can hide a jump in the full band (MCP-37's "or above 200 Hz"; the engine's
        /// band edge is 300 Hz).
        case aboveLow
        /// 300–3000 Hz, where a voice is (music swelling under a line).
        case voice
    }

    struct Accent: Sendable, Equatable {
        let time: Double
        let strength: Double
    }

    let grid: MixFrameGrid
    /// Timeline frame of each group's first measured frame.
    let first: Int
    let frames: [Group: [MixFrameLevel]]
    let accents: [Accent]
    /// The place group's power above `highCutoff` in each requested window (timeline seconds).
    var placeHigh: [ClosedRange<Double>: Double] = [:]

    static let empty = AIDeliverySoundLevels(grid: MixFrameGrid(fps: 24), first: 0, frames: [:], accents: [])
    /// "Above 200 Hz" (MCP-37; the human film and the preview board measured there).
    static let highCutoff = 200.0

    /// Accents count only where the music is heard (dBFS).
    static let audibleDB = -45.0
    /// The rendered music is kept at half the engine's rate for the accent reading (24 kHz: its 1024-sample frames are 43 ms,
    /// near the research's 46 ms at 22.05 kHz; everything it reads is under 4 kHz).
    static let accentDecimation = 2

    // MARK: Reading

    /// One frame's power (mean square) of a group in a band: 0 outside the measured frames or without that group.
    func power(_ group: Group, frame: Int, band: Band = .full) -> Double {
        guard let levels = frames[group], frame >= first, frame - first < levels.count else { return 0 }
        let level = levels[frame - first]
        switch band {
        case .full: return level.meanSquare
        case .aboveLow: return level.bands[1] + level.bands[2] + level.bands[3]
        case .voice: return level.bands[1] + level.bands[2]
        }
    }

    func db(_ group: Group, frame: Int, band: Band = .full) -> Double { Self.db(power(group, frame: frame, band: band)) }

    /// Mean power over [from, to) timeline seconds (each frame weighted by its overlap), in dBFS.
    func db(_ group: Group, from: Double, to: Double, band: Band = .full) -> Double {
        guard to > from else { return Self.db(0) }
        var total = 0.0
        var frame = grid.frame(containing: from)
        while grid.seconds(ofFrame: frame) < to {
            let a = max(from, grid.seconds(ofFrame: frame)), b = min(to, grid.seconds(ofFrame: frame + 1))
            if b > a { total += power(group, frame: frame, band: band) * (b - a) }
            frame += 1
        }
        return Self.db(total / (to - from))
    }

    static func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }

    /// The place group above 200 Hz over a cut window (dBFS). A window that was not rendered (rule checks on made-up levels)
    /// reads the band meter's split at 300 Hz instead.
    func placeHighDB(_ window: ClosedRange<Double>) -> Double {
        if let power = placeHigh[window] { return Self.db(power) }
        return db(.place, from: window.lowerBound, to: window.upperBound, band: .aboveLow)
    }

    // MARK: Measuring

    /// Renders `frames` of the timeline split by role group and measures every group per frame; keeps the place group's samples
    /// in `windows` for the reading above 200 Hz. Blocking.
    static func measure(_ config: AudioEngineConfig, roles: AIDeliverySoundRoles, grid: MixFrameGrid, frames range: Range<Int>,
                        windows: [ClosedRange<Double>], isCancelled: () -> Bool) throws -> AIDeliverySoundLevels {
        let split = DeliveryStemSplit.split(config, wanted: Group.allCases, name: \.rawValue) { Group(roles.role(of: $0.clipID)) }
        guard !split.layers.isEmpty, !range.isEmpty else { return AIDeliverySoundLevels(grid: grid, first: range.lowerBound, frames: [:], accents: []) }
        let music = split.layers.firstIndex { $0.key == .music }, place = split.layers.firstIndex { $0.key == .place }
        let collector = MusicCollector(decimation: accentDecimation)
        let cutWindows = DeliveryWindowCollector(windows: windows, sampleRate: Double(grid.sampleRate), cutoff: highCutoff)
        let request = MixMeasurement.Request(config: split.config, layers: split.layers.map(\.layer), grid: grid, frames: range)
        let result = try MixMeasurement.measure(request, isCancelled: isCancelled) { block in
            if let music { collector.add(block.layers[music], at: block.position, frames: block.frames) }
            if let place { cutWindows.add(block.layers[place], at: block.position, frames: block.frames) }
        }
        var frames: [Group: [MixFrameLevel]] = [:]
        for (index, entry) in split.layers.enumerated() { frames[entry.key] = result.layers[index].frames }
        var levels = AIDeliverySoundLevels(grid: grid, first: range.lowerBound, frames: frames, accents: [])
        if music != nil {
            let spans = config.tracks.flatMap(\.segments).filter { roles.role(of: $0.clipID) == .music }.map { ($0.start, $0.end) }
            levels = AIDeliverySoundLevels(grid: grid, first: range.lowerBound, frames: frames,
                                           accents: accents(collector, spans: spans, levels: levels))
        }
        levels.placeHigh = place == nil ? [:] : cutWindows.powers
        return levels
    }

    /// The accents of each music clip's stretch of the rendered music (one z-score per stretch), where the music is heard.
    private static func accents(_ music: MusicCollector, spans: [(Double, Double)], levels: AIDeliverySoundLevels) -> [Accent] {
        let engineRate = Double(levels.grid.sampleRate), rate = engineRate / Double(music.decimation)
        var found: [Accent] = []
        for (start, end) in spans {
            let from = max(0, Int(((start * engineRate - Double(music.start)) / Double(music.decimation)).rounded(.up)))
            let to = min(music.samples.count, Int(((end * engineRate - Double(music.start)) / Double(music.decimation)).rounded(.down)))
            guard to - from > DeliveryMusicAccents.frameSize * 2 else { continue }
            let origin = (Double(music.start) + Double(from * music.decimation)) / engineRate
            for accent in DeliveryMusicAccents.accents(Array(music.samples[from ..< to]), sampleRate: rate) {
                let time = origin + accent.time
                guard levels.db(.music, frame: levels.grid.frame(containing: time)) > audibleDB,
                      !found.contains(where: { abs($0.time - time) < Double(DeliveryMusicAccents.hop) / rate }) else { continue }
                found.append(Accent(time: time, strength: accent.strength))
            }
        }
        return found.sorted { $0.time < $1.time }
    }
}

/// The rendered music as one channel ((L + R) / 2) at a fraction of the engine's rate, for the onset reading.
private final class MusicCollector {
    let decimation: Int
    private(set) var start: Int64 = 0
    private(set) var samples: [Float] = []
    private var sum: Float = 0
    private var count = 0
    private var started = false

    init(decimation: Int) { self.decimation = decimation }

    func add(_ block: UnsafeBufferPointer<Float>, at position: Int64, frames: Int) {
        if !started { start = position; started = true }
        for index in 0 ..< frames {
            sum += (block[index * 2] + block[index * 2 + 1]) / 2
            count += 1
            if count == decimation {
                samples.append(sum / Float(decimation))
                sum = 0
                count = 0
            }
        }
    }
}
