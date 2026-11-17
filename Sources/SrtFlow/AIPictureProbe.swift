import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 看一段素材的画面：黑边、主体在哪
//
// 管什么：edit_clip 要「去黑边」「铺满时对准主体（主体走动就跟着走）」时，从这一段用到的那一截里抽帧（AIFrameSampler），
// 交给纯值的规则算（AIBlackBars、AISubjectFocus、AIFollowSubject；认主体用 Vision，AIVision），再把看到的写成 AI 读得懂的
// 一小段 JSON。
// 不管什么：裁切怎么算（AIFrameFit）、改工程（AIClipTools / AIClipEdit）。

enum AIPictureProbe {
    // Five midpoint frames distinguish a steady matte from a dark frame without decoding the whole source.
    static let sampleCount = 5

    struct BlackBars {
        var measured: AIBlackBars.Insets?
        var crop: AIBlackBars.Insets?

        var active: CGRect? { crop.flatMap { $0.isEmpty ? nil : $0.active } }
    }

    // Probe the clip's exact source window. Zero tolerance cannot borrow an unbarred frame from the next shot.
    // The measured values match look; the crop includes one analysis pixel at each detected boundary.
    static func blackBars(of clip: EditClip) async -> BlackBars {
        let frames = await AIFrameSampler.frames(of: clip, count: sampleCount, maxSide: AIBlackBars.measurementSide, tolerance: 0)
        let readings = frames.compactMap { frame -> (AIBlackBars.Reading, AIBlackBars.Reading)? in
            guard let luma = AIBlackBars.luma(of: frame.image, maxSide: AIBlackBars.measurementSide),
                  let reading = AIBlackBars.reading(in: luma) else { return nil }
            return (reading, AIBlackBars.includingBoundary(reading, in: luma))
        }
        return BlackBars(measured: AIBlackBars.combine(readings.map { $0.0 }), crop: AIBlackBars.combine(readings.map { $0.1 }))
    }

    /// 每秒两帧、至少 5 帧、最多 30 帧：固定的窗取中位数 5 帧就够，跟拍要看得出主体怎么走（第四块）。
    static func subjectSampleCount(duration: Double) -> Int {
        min(max(Int((duration * 2).rounded()), sampleCount), 30)
    }

    /// 这一段里主体在哪：沿着用到的那一截均匀抽帧，每帧让 Vision 认人脸 / 人 / 显眼的东西（源秒 + 认出来的框）。
    static func subjectSamples(of clip: EditClip) async -> [AIFollowSubject.Sample] {
        let count = clip.isStillImage ? 1 : subjectSampleCount(duration: clip.timelineDuration)
        let frames = await AIFrameSampler.frames(of: clip, count: count, maxSide: 640)
        var samples: [AIFollowSubject.Sample] = []
        for frame in frames {
            // 字在哪也认一下（fast，一帧几十毫秒）：没有人的幻灯片、录屏按字对准（AISubjectFocus）。
            samples.append(.init(time: frame.time, findings: await AIVision.analyze(frame.image, [.subject, .textRegions]).subject))
        }
        return samples
    }

    /// 写给 AI：认出了什么、对准哪；跟拍了就说几个关键帧，没跟但走动大就提醒。
    static func json(_ subject: AISubjectFocus.Result?, window: CGSize, followKeyframes: Int?) -> JSONValue {
        guard let subject else { return "none found: filled around the centre" }
        var object: [String: JSONValue] = [
            "kind": .string(subject.kind.rawValue),
            "x": AIFormat.seconds(subject.point.x), "y": AIFormat.seconds(subject.point.y),
            "seen_in_frames": .number(Double(subject.frames))
        ]
        if let followKeyframes {
            object["follows"] = .number(Double(followKeyframes))
            object["note"] = .string(
                "The subject moves around, so the crop follows it with \(followKeyframes) position keyframes. "
                    + "Pass follow=false for one fixed crop."
            )
        } else if subject.kind == .text, subject.textCut > 0.05 {
            object["text_cut"] = AIFormat.seconds(subject.textCut)
            object["note"] = .string(
                "The text is wider than the frame: about \(Int((subject.textCut * 100).rounded()))% of it falls outside. "
                    + "fit=fit shows all of it (with bars), or keep this crop if the middle is enough."
            )
        } else if subject.kind != .text, AISubjectFocus.movesTooMuch(subject, window: window) {
            object["note"] = .string(
                "The subject moves around in this clip, so one fixed crop may lose it. "
                    + "Leave follow on to follow it with keyframes, or split the clip where it moves."
            )
        }
        return .object(object)
    }
}
