import Foundation

/// ESTOI（扩展的短时客观可懂度，Jensen & Taal 2016）：一句话的干净人声和整条混音，量这句话在混音里还剩多少可懂度（docs/architecture/listening-engine.md）。
///
/// 管什么：每句一个数（一般在 0–1，越大越清楚；和人声毫不相干的声音会略低于 0，不夹）和每一段（30 帧 = 384 ms）的中间值。
/// 不管什么：句子从哪到哪（转写 / 旁白轨的位置，接线的任务给）；线画在哪、报不报（接线的任务，线的来历见架构文档）；
/// 「拿掉谁涨多少」和 150 Hz 以下（`MaskerAttribution`）。
///
/// 算法照研究时自己写、验过的 numpy 版（它又照论文和 pystoi 公开的参数）：
/// 两边按干净人声去静音、取 15 个带的包络 → 每 30 帧一段（相邻段差一帧）→ 每段先按带（行）去均值、归一，再按帧（列）去均值、归一
/// → 两边逐元素相乘加起来除以 30 → 所有段取平均。不截断、不缩放（那是原版 STOI）。
/// 和 pystoi 的差别（研究时写下的，没对 pystoi 跑过）：归一时分母加 eps，不加它那一点随机数（只防除以零），差在 1e-10 量级；
/// 重采样用整段 FFT 截断（`ListeningResample`），不是 pystoi 的多相滤波。
/// 干净人声和混音的总音量都不影响结果：两边各自归一。所以它也**不管响不响**，「整句太轻」要另外量。
enum ESTOI {
    /// 一段多少帧（30 × 12.8 ms = 384 ms）。
    static let segmentFrames = 30

    struct Result: Equatable {
        /// 整句：每段的平均。
        let score: Double
        /// 每段的中间值（去静音以后的帧上滑：相邻两段差一帧）。
        let segmentScores: [Double]
        /// 去静音以后分析了多少帧（每帧 12.8 ms）。
        let speechFrames: Int

        /// 连着的 `segments` 段（默认 78 段 ≈ 1 秒）平均最低的那一截；不够这么多段就是整句。研究里的「最差 1 秒」。
        /// 注意这里的「1 秒」是去静音以后的帧，句中停顿已经拿掉了。
        func worstWindow(segments: Int = 78) -> Double {
            guard !segmentScores.isEmpty else { return .nan }
            guard segmentScores.count > segments else { return score }
            var prefix = [0.0]
            prefix.reserveCapacity(segmentScores.count + 1)
            for value in segmentScores { prefix.append(prefix[prefix.count - 1] + value) }
            var worst = Double.infinity
            for end in segments...segmentScores.count {
                worst = min(worst, (prefix[end] - prefix[end - segments]) / Double(segments))
            }
            return worst
        }
    }

    /// 一句：干净人声和混音，同一采样率、同一个时间窗、单声道（立体声先取 (L+R)/2）。窗一般取人声起止前后各多 0.2 秒，
    /// 不说话的帧会按干净人声去掉。长度不一样、去静音以后不到 30 帧（约 0.4 秒）回 nil。
    static func score(clean: [Float], mix: [Float], sampleRate: Double) -> Result? {
        guard clean.count == mix.count else { return nil }
        let plan = ListeningResample.Plan(inputLength: clean.count, from: sampleRate, to: ESTOIAnalysis.sampleRate)
        let clean10k = plan.apply(ListeningResample.doubles(clean))
        return ESTOIReference(clean10k: clean10k)?.score(mix10k: plan.apply(ListeningResample.doubles(mix)))
    }

    /// 一段的 15 × 30 个包络值（按 [帧][带] 存）就地归一：先每个带在 30 帧上去均值、除以长度，再每帧在 15 个带上去均值、除以长度。
    /// 分母都加 eps：全是同一个数的行 / 列归一成全 0，不出 NaN。
    static func normalize(_ segment: inout [Double], frames: Int, bands: Int) {
        let eps = ESTOIAnalysis.eps
        for band in 0..<bands {
            var mean = 0.0
            for frame in 0..<frames { mean += segment[frame * bands + band] }
            mean /= Double(frames)
            var sum = 0.0
            for frame in 0..<frames {
                let v = segment[frame * bands + band] - mean
                segment[frame * bands + band] = v
                sum += v * v
            }
            let norm = sum.squareRoot() + eps
            for frame in 0..<frames { segment[frame * bands + band] /= norm }
        }
        for frame in 0..<frames {
            let base = frame * bands
            var mean = 0.0
            for band in 0..<bands { mean += segment[base + band] }
            mean /= Double(bands)
            var sum = 0.0
            for band in 0..<bands {
                let v = segment[base + band] - mean
                segment[base + band] = v
                sum += v * v
            }
            let norm = sum.squareRoot() + eps
            for band in 0..<bands { segment[base + band] /= norm }
        }
    }
}

/// 干净人声那一边只算一次：哪几帧在说话、每段归一好的包络。「拿掉谁涨多少」要给同一句打十几次分，都用它。
struct ESTOIReference {
    let sampleCount: Int
    let speechFrameStarts: [Int]
    /// 每段 15 × 30 个值，按 [帧][带] 平铺。
    private let segments: [[Double]]

    /// clean10k：10 kHz 的干净人声。去静音以后不到 30 帧回 nil。
    init?(clean10k: [Double]) {
        let starts = ESTOIAnalysis.speechFrames(clean: clean10k)
        let envelopes = ESTOIAnalysis.bandEnvelopes(ESTOIAnalysis.keep(clean10k, frames: starts))
        guard envelopes.count >= ESTOI.segmentFrames else { return nil }
        sampleCount = clean10k.count
        speechFrameStarts = starts
        segments = ESTOIReference.normalizedSegments(envelopes)
    }

    /// mix10k：同一个窗、同样长的 10 kHz 混音。长度不对回 nil。
    func score(mix10k: [Double]) -> ESTOI.Result? {
        guard mix10k.count == sampleCount else { return nil }
        let envelopes = ESTOIAnalysis.bandEnvelopes(ESTOIAnalysis.keep(mix10k, frames: speechFrameStarts))
        let mixSegments = ESTOIReference.normalizedSegments(envelopes)
        guard mixSegments.count == segments.count, !segments.isEmpty else { return nil }
        let frames = Double(ESTOI.segmentFrames)
        let scores = zip(segments, mixSegments).map { clean, mix -> Double in
            var sum = 0.0
            for i in 0..<clean.count { sum += clean[i] * mix[i] }
            return sum / frames
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return ESTOI.Result(score: mean, segmentScores: scores, speechFrames: envelopes.count)
    }

    private static func normalizedSegments(_ envelopes: [[Double]]) -> [[Double]] {
        let frames = ESTOI.segmentFrames
        let bands = ESTOIAnalysis.bandCount
        guard envelopes.count >= frames else { return [] }
        return (frames...envelopes.count).map { end in
            var segment = [Double]()
            segment.reserveCapacity(frames * bands)
            for frame in (end - frames)..<end { segment.append(contentsOf: envelopes[frame]) }
            ESTOI.normalize(&segment, frames: frames, bands: bands)
            return segment
        }
    }
}
