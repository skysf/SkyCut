import Foundation

// MARK: - 克隆的参考录音用哪一段（纯值）
//
// 管什么：一段声音按 20 ms 一格的响度（均方根）挑出当参考的那一段（SkyCut 声音方案第六节，决定第三节第 3 条）：
// - 不到 3 分钟用整段；超过就挑**有效人声最多**的连续一段：起点是这段声音的开头，或一个 ≥ 0.2 秒停顿之后的开口
//   前 40 ms；终点落在 3:00 前后 1 秒内的停顿里、离停顿两头至少 40 ms（round5 B 节「切口修正」），或这段声音的尽头。
//   一段最长不到 181 秒（服务器的上限 180 秒、容差 1 秒，Sky Studio 声音方案 3.4）。
//   有效人声一样多时前 15 秒人声更密的优先（IndexTTS2 上游只用参考的前 15 秒），再一样取最早的、最短的。
//   哪个起点都找不到这样的终点（一直有声、没有停顿）才退一步：终点放在 3:00 前后 1 秒内最安静的那个格子边上。
// - 「有效人声几秒」也只在这里数：均方根 ≥ 0.0056（约 −45.04 dBFS）的整格 × 20 ms，不满 20 ms 的尾巴不算。
//   挑段按它数，写好的文件再按它数一遍；不到 10 秒不收（MiniMax 克隆的硬要求）。门限是和 Sky Studio 的跨仓库合同
//   （`speechRMSFloor`），服务器的 too_little_speech 故意放宽到 0.0055，只会比 SkyCut 宽、不会更严。
// 不管什么：解码、重采样、写 WAV、上传（VoiceReferenceSample / VoiceReferenceReader）。

struct VoiceReferenceWindow: Equatable, Sendable {
    /// 一格 20 ms（44.1 kHz 是 882 个采样）。
    static let frameSeconds = 0.02
    /// 有声的门限：一格的均方根 ≥ 0.0056（均方 ≥ 3.136e-5，约 −45.04 dBFS），比它轻的一格算停顿。
    /// 这是和 Sky Studio 的**跨仓库合同**：服务器的 too_little_speech 故意放宽到 0.0055，吃掉两边浮点和取整的差别。
    /// 单独写死在这里，不借 AIVoiceLevel.activeFloor —— 那是配音响度的门限，调它不许把合同带着变
    /// （docs/bugfixes/2026-11-10-voice-reference-floor-borrowed-from-voice-level.md）。
    static let speechRMSFloor: Float = 0.0056
    /// 至少 10 秒有效人声 = 500 格。
    static let minimumVoicedFrames = 500
    /// 最长 3 分钟 = 9,000 格；超过时终点在 3:00 前后 1 秒（50 格）内，且不到 181 秒。
    static let maximumFrames = 9_000
    static let endSlackFrames = 50
    /// 能切的停顿至少 0.2 秒（10 格）；切口离停顿两头至少 40 ms（2 格）。
    static let pauseFrames = 10
    static let cutMarginFrames = 2
    /// 比密度的前 15 秒 = 750 格。
    static let leadFrames = 750

    static var minimumVoicedSeconds: Double { Double(minimumVoicedFrames) * frameSeconds }
    static var maximumSeconds: Double { Double(maximumFrames) * frameSeconds }

    /// 用的那一段，相对这段声音开头的秒数。
    let start: Double
    let end: Double
    /// 这一段里响度够的整格数（× 20 ms 就是有效人声的秒数）。
    let voicedFrames: Int
    /// 只用了其中一段（false = 整段都用）。
    let autoSelected: Bool

    var seconds: Double { end - start }
    var voicedSeconds: Double { Self.seconds(frames: voicedFrames) }
    var hasEnoughSpeech: Bool { voicedFrames >= Self.minimumVoicedFrames }

    static func seconds(frames: Int) -> Double { Double(frames) * frameSeconds }

    /// `levels`：从这段声音开头起每个整格的均方根（`Meter`）；`duration`：这段声音实际多长（含不满一格的尾巴）。
    static func choose(levels: [Float], duration: Double) -> VoiceReferenceWindow {
        let voiced = Prefix(levels)
        guard duration > maximumSeconds else {
            return VoiceReferenceWindow(start: 0, end: duration, voicedFrames: voiced.count(0, levels.count), autoSelected: false)
        }
        let pauses = pauseRuns(levels)
        let starts = [0] + pauses.compactMap { $0.upperBound < levels.count ? $0.upperBound - cutMarginFrames : nil }
        let natural = starts.compactMap { naturalEnd(from: $0, pauses: pauses, levels: levels, duration: duration, voiced: voiced) }
        let candidates = natural.isEmpty ? starts.map { quietEnd(from: $0, levels: levels, voiced: voiced) } : natural
        // starts 至少有开头那一个，所以 candidates 不空。
        let best = candidates.min { better($0, than: $1) } ?? quietEnd(from: 0, levels: levels, voiced: voiced)
        let end = best.end.map { seconds(frames: $0) } ?? duration
        let start = seconds(frames: best.start)
        return VoiceReferenceWindow(start: start, end: end, voicedFrames: best.voiced, autoSelected: best.start > 0 || best.end != nil)
    }

    /// 一段采样（写好的文件、或刚解码的一块）里有效人声多少格：按同一个格子、同一个门限。
    static func voicedFrames(levels: [Float]) -> Int { levels.reduce(0) { $0 + ($1 >= speechRMSFloor ? 1 : 0) } }

    // MARK: 挑段

    /// 一个候选：起点格、终点格（nil = 这段声音的尽头）、有效人声格数、前 15 秒的有效人声格数。
    private struct Candidate {
        let start: Int
        let end: Int?
        let voiced: Int
        let lead: Int

        func endFrame(_ count: Int) -> Int { end ?? count }
    }

    /// 人声多的赢；一样多比前 15 秒；再一样取早的、短的。
    private static func better(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if lhs.voiced != rhs.voiced { return lhs.voiced > rhs.voiced }
        if lhs.lead != rhs.lead { return lhs.lead > rhs.lead }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.endFrame(Int.max) < rhs.endFrame(Int.max)
    }

    private static func candidate(_ start: Int, _ end: Int?, count: Int, voiced: Prefix) -> Candidate {
        let stop = end ?? count
        return Candidate(start: start, end: end, voiced: voiced.count(start, stop), lead: voiced.count(start, min(stop, start + leadFrames)))
    }

    /// 连续 ≥ 0.2 秒都比门限轻的那几段（格的下标区间）。开头、结尾的静音也算。
    static func pauseRuns(_ levels: [Float]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var begin: Int?
        for index in 0...levels.count {
            let silent = index < levels.count && levels[index] < speechRMSFloor
            if silent, begin == nil { begin = index }
            if !silent, let first = begin {
                if index - first >= pauseFrames { runs.append(first..<index) }
                begin = nil
            }
        }
        return runs
    }

    /// 从 `start` 起、自然收尾的最好终点：这段声音的尽头（够得着的话），或 3:00 前后 1 秒内的停顿。
    private static func naturalEnd(from start: Int, pauses: [Range<Int>], levels: [Float], duration: Double,
                                   voiced: Prefix) -> Candidate? {
        let count = levels.count
        let earliest = start + maximumFrames - endSlackFrames
        let latest = start + maximumFrames + endSlackFrames - 1
        var options: [Candidate] = []
        if duration - seconds(frames: start) < seconds(frames: maximumFrames + endSlackFrames) {
            options.append(candidate(start, nil, count: count, voiced: voiced))
        }
        // 停顿按位置排好、互不重叠：二分找到第一个切口区间够得着 earliest 的，往后只看落进 latest 之前的几个。
        var index = firstPause(endingAtOrAfter: earliest + cutMarginFrames, in: pauses)
        while index < pauses.count {
            let pause = pauses[index]
            let low = max(pause.lowerBound + cutMarginFrames, earliest)
            guard low <= latest else { break }
            if low <= pause.upperBound - cutMarginFrames { options.append(candidate(start, low, count: count, voiced: voiced)) }
            index += 1
        }
        return options.min { better($0, than: $1) }
    }

    /// 第一个 `upperBound >= bound` 的停顿（没有就是 count）。
    private static func firstPause(endingAtOrAfter bound: Int, in pauses: [Range<Int>]) -> Int {
        var low = 0, high = pauses.count
        while low < high {
            let middle = (low + high) / 2
            if pauses[middle].upperBound < bound { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// 退一步：3:00 前后 1 秒内最安静的格子边（两边的格加起来最轻；一样轻取早的）。
    private static func quietEnd(from start: Int, levels: [Float], voiced: Prefix) -> Candidate {
        let low = min(start + maximumFrames - endSlackFrames, max(1, levels.count - 1))
        let high = min(start + maximumFrames + endSlackFrames - 1, levels.count - 1)
        var cut = low
        var quietest = Float.infinity
        if low <= high {
            for boundary in low...high where boundary >= 1 {
                let loudness = levels[boundary - 1] + levels[boundary]
                if loudness < quietest { quietest = loudness; cut = boundary }
            }
        }
        return candidate(start, cut, count: levels.count, voiced: voiced)
    }

    /// 有效人声格数的前缀和：任意一段 O(1)。
    private struct Prefix {
        private let sums: [Int]
        init(_ levels: [Float]) {
            var running = 0
            var sums = [0]
            sums.reserveCapacity(levels.count + 1)
            for level in levels {
                running += level >= VoiceReferenceWindow.speechRMSFloor ? 1 : 0
                sums.append(running)
            }
            self.sums = sums
        }
        func count(_ from: Int, _ to: Int) -> Int {
            let low = min(max(0, from), sums.count - 1), high = min(max(low, to), sums.count - 1)
            return sums[high] - sums[low]
        }
    }

    // MARK: 边读边算响度

    /// 20 ms 一格的均方根，边读边算：一块一块交进来，结果和一口气算的一样；不满一格的尾巴不出格。
    struct Meter: Sendable {
        let samplesPerFrame: Int
        private(set) var levels: [Float] = []
        private var sum: Double = 0
        private var filled = 0

        init(sampleRate: Double) {
            samplesPerFrame = max(1, Int((sampleRate * VoiceReferenceWindow.frameSeconds).rounded()))
        }

        mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                sum += Double(sample) * Double(sample)
                filled += 1
                if filled == samplesPerFrame {
                    levels.append(Float((sum / Double(filled)).squareRoot()))
                    sum = 0
                    filled = 0
                }
            }
        }

        mutating func append(_ samples: [Float]) { samples.withUnsafeBufferPointer { append($0) } }
    }
}
