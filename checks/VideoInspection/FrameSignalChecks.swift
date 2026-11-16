import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// 夹帧和成片逐帧扫的纯值规则（docs/architecture/stray-frames.md）：逐帧小信号怎么记、逐帧的刀、成片的四种疑点、
// 一段的源范围跨没跨过素材的刀、成片比工程旧。全是手造的数，不读文件；真文件走 StrayFrameChecks。
enum FrameSignalChecks {
    static func run(require: (Bool, String) -> Void) {
        builder(require)
        hardCuts(require)
        frameScan(require)
        sourceCuts(require)
        freshness(require)
    }

    /// 一帧 4 × 4 像素、全是同一个灰度。
    private static func frame(_ level: UInt8, pixels: Int = 16) -> [UInt8] { Array(repeating: level, count: pixels * 3) }

    private static func builder(_ require: (Bool, String) -> Void) {
        var builder = AIFrameSignals.Builder()
        for index in 0..<4 { builder.add(frame(100), at: Double(index) / 24) }
        builder.add(frame(200), at: 4.0 / 24)
        // 每帧只差 15 / 48 / 255（约 0.31，低于帧间门槛 0.35），但一直往一个方向走：和锚帧的差攒过 stillDrift（0.5）就换锚。
        var drifting = frame(200)
        for index in 5..<9 {
            for byte in 0..<15 { drifting[byte] += 1 }
            builder.add(drifting, at: Double(index) / 24)
        }
        let signals = builder.signals
        require(signals.held == [false, true, true, true, false, true, false, true, false],
                "held: still frames hold, a change re-anchors, a slow drift re-anchors once it adds up: \(signals.held)")
        require(signals.changes[0] == 0 && abs(signals.changes[4] - 100.0 / 255) < 1e-9, "changes: first frame 0, then mean RGB difference")
        var patch = frame(0, pixels: 1000)
        patch[0] = 255; patch[1] = 255; patch[2] = 255
        for index in 3..<30 { patch[index] = 255 }
        require(AIFrameSignals.Builder.darkShare(frame(0)) == 1 && AIFrameSignals.Builder.darkShare(frame(16)) == 1
                    && AIFrameSignals.Builder.darkShare(frame(17)) == 0, "dark share: luma 16 counts as dark, 17 does not")
        require(AIFrameSignals.Builder.darkShare(patch) < AIFrameScan.blackShare,
                "white text on black (1% of the pixels) is not a black frame")
    }

    private static func hardCuts(_ require: (Bool, String) -> Void) {
        let motion = 4.0 / 255
        var changes = Array(repeating: motion, count: 100)
        changes[0] = 0
        require(AIShotDetector.hardCuts(changes: changes).isEmpty, "steady motion has no cut")
        changes[50] = 60.0 / 255
        changes[52] = 60.0 / 255
        require(AIShotDetector.hardCuts(changes: changes) == [50, 52], "two cuts two frames apart are both found (median, not mean)")
        changes[1] = 60.0 / 255
        changes[99] = 60.0 / 255
        require(AIShotDetector.hardCuts(changes: changes) == [1, 50, 52, 99], "cuts next to the start and the end are kept")
        var pan = Array(repeating: 30.0 / 255, count: 60)
        pan[0] = 0
        pan[30] = 60.0 / 255
        require(AIShotDetector.hardCuts(changes: pan).isEmpty, "a fast pan: a frame twice its neighbours is not a cut")
        var quiet = Array(repeating: 0.0, count: 40)
        quiet[20] = 14.0 / 255
        require(AIShotDetector.hardCuts(changes: quiet).isEmpty, "below the minimum change (noise in a still picture) is not a cut")
        quiet[20] = 16.0 / 255
        require(AIShotDetector.hardCuts(changes: quiet) == [20], "above the minimum on a still picture is a cut")
    }

    /// 24 帧每秒的手造信号：`levels` 是每一帧的亮度（0…255），变化按相邻亮度差算，`held` 照帧间不变算。
    private static func signals(_ levels: [Double], held: Set<Int> = [], dark: Set<Int> = []) -> AIFrameSignals {
        var signals = AIFrameSignals()
        for (index, level) in levels.enumerated() {
            signals.times.append(Double(index) / 24)
            signals.changes.append(index == 0 ? 0 : abs(level - levels[index - 1]) / 255)
            signals.brightness.append(level / 255)
            signals.dark.append(dark.contains(index) ? 1 : 0)
            signals.held.append(held.contains(index))
        }
        return signals
    }

    private static func frameScan(_ require: (Bool, String) -> Void) {
        // 一个镜头（亮度 100 上下动），第 40–41 帧夹 2 帧别的（亮度 200），第 80–88 帧 9 帧闪白（255）。
        var levels = (0..<200).map { 100 + Double($0 % 3) * 2 }
        levels[40] = 160; levels[41] = 160
        for index in 80...88 { levels[index] = 255 }
        let kinds = AIFrameScan.findings(signals(levels)).map { "\($0.kind.rawValue)@\($0.first)-\($0.last)" }
        require(kinds == ["stray_frames@40-41", "flash@80-88"], "a 2-frame piece is stray frames, a 9-frame bright piece is a flash: \(kinds)")

        // 片头 3 帧别的画面、片尾 5 帧别的画面。
        var edges = (0..<120).map { 100 + Double($0 % 3) * 2 }
        for index in 0..<3 { edges[index] = 30 }
        for index in 115..<120 { edges[index] = 220 }
        let edgeKinds = AIFrameScan.findings(signals(edges)).map { "\($0.kind.rawValue)@\($0.first)-\($0.last)" }
        require(edgeKinds.contains("stray_frames@0-2") && edgeKinds.contains("stray_frames@115-119"),
                "a few frames of another picture at the very start or end are stray frames: \(edgeKinds)")

        // 第 20–163 帧（144 帧 = 6 秒）不动；第 170–193 帧（1 秒）全黑；片头 6 帧（0.25 秒）的黑是淡入。
        var still = (0..<240).map { 100 + Double($0 % 3) * 2 }
        for index in 20...163 { still[index] = 100 }
        for index in 0..<6 { still[index] = 0 }
        for index in 170...193 { still[index] = 0 }
        let stillKinds = AIFrameScan.findings(signals(still, held: Set(21...163), dark: Set(0..<6).union(170...193)))
            .map { "\($0.kind.rawValue)@\($0.first)-\($0.last)" }
        require(stillKinds == ["frozen_picture@20-163", "black_frame@170-193"],
                "6 s without movement is frozen; a black second is one finding; a short black lead-in is a fade: \(stillKinds)")
        let shortStill = AIFrameScan.findings(signals(still, held: Set(21...162), dark: Set(170...193)))
        require(!shortStill.contains { $0.kind == .frozen }, "just under 6 s without movement is not reported")
        var darkPiece = (0..<100).map { 100 + Double($0 % 3) * 2 }
        darkPiece[50] = 5; darkPiece[51] = 5
        require(AIFrameScan.findings(signals(darkPiece)).isEmpty, "a very dark short piece is left to the black check, not a stray piece")
    }

    private static func sourceCuts(_ require: (Bool, String) -> Void) {
        let times = (0..<192).map { Double($0) / 24 }
        // 南极第二稿：入点 1.95、出点 5.45，素材第 129 帧（5.375 秒）有一刀 → 末尾 2 帧是另一个镜头。
        let tail = AISourceCuts.crossings(window: 1.95...5.45, times: times, cuts: [129])
        require(tail.count == 1 && tail.first?.kind == .tail && tail.first?.frame == 129 && tail.first?.after == 2
                    && tail.first?.suggestion?.key == "suggested_source_out" && tail.first?.suggestion?.value == 5.375,
                "the trailer case: the last 2 frames show the next shot, suggest source_out 5.375: \(tail)")
        require(AISourceCuts.crossings(window: (1.95 - 2.0 / 24)...(5.45 - 2.0 / 24), times: times, cuts: [129]).isEmpty,
                "two frames earlier the window stops before the cut")
        require(AISourceCuts.crossings(window: 1.95...(5.375 + 0.000_001), times: times, cuts: [129]).isEmpty,
                "an out point a microsecond past the cut shows nothing of the next shot")
        let head = AISourceCuts.crossings(window: 0...8, times: times, cuts: [3, 129])
        require(head.map(\.kind) == [.head, .twoShots] && head.first?.before == 3 && head.first?.suggestion?.key == "suggested_source_in"
                    && head.last?.suggestion == nil,
                "3 frames of another shot at the start suggest source_in; a long-long cut among several has no suggestion: \(head)")
        let inside = AISourceCuts.crossings(window: 0...8, times: times, cuts: [100, 102])
        require(inside.map(\.kind) == [.inside] && inside.first?.frame == 100 && inside.first?.after == 2 && inside.first?.suggestion == nil,
                "a 2-frame flash inside the file is reported once, without a trim suggestion: \(inside)")
        let sole = AISourceCuts.crossings(window: 3...7, times: times, cuts: [129])
        require(sole.map(\.kind) == [.twoShots] && sole.first?.suggestion?.key == "suggested_source_out",
                "one cut with two long sides suggests keeping the longer side: \(sole)")
        let tiny = AISourceCuts.crossings(window: 5.2...5.5, times: times, cuts: [129])
        require(tiny.map(\.kind) == [.tail] && tiny.first?.after == 3, "both sides short: trim the shorter one: \(tiny)")
    }

    private static func freshness(_ require: (Bool, String) -> Void) {
        let made = Date(timeIntervalSince1970: 1_000_000)
        typealias F = AIInspectionFreshness
        require(F.verdict(made: made, saved: made.addingTimeInterval(10), unsaved: false, now: made.addingTimeInterval(20))
                    == .older(changedBy: made.addingTimeInterval(7)), "a save well after the file means the project changed after it")
        require(F.verdict(made: made, saved: made.addingTimeInterval(-5), unsaved: false, now: made.addingTimeInterval(20)) == .newer,
                "the last save before the file: the file has every change")
        require(F.verdict(made: made, saved: made.addingTimeInterval(2), unsaved: false, now: made.addingTimeInterval(20)) == .unknown,
                "an autosave right after the export cannot tell which came first")
        require(F.verdict(made: made, saved: made.addingTimeInterval(-60), unsaved: true, now: made.addingTimeInterval(30))
                    == .older(changedBy: made.addingTimeInterval(27)), "unsaved changes long after the file are newer than it")
        require(F.verdict(made: made, saved: nil, unsaved: true, now: made.addingTimeInterval(30)) == .unknown,
                "a project that was never saved cannot be judged")
    }
}
