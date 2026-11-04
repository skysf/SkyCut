import Foundation

// 制作审查所需的请求时刻：按工程帧格映射到实际使用源范围。这里只排采样，不证明解码 actualTime。
enum AIFilmProductionSamples {
    struct UsedWindow {
        var sourceStart: Double
        var sourceDuration: Double
        var speed: Double
        var timelineStart: Double
        var fps: Int
        var timelineEnd: Double { timelineStart + sourceDuration / speed }

        var projectBounds: ClosedRange<Double>? {
            guard sourceStart.isFinite, sourceStart >= 0, sourceDuration.isFinite, sourceDuration > 0,
                  speed.isFinite, speed > 0, timelineStart.isFinite, timelineStart >= 0, fps > 0,
                  timelineEnd.isFinite else { return nil }
            let rate = Double(fps)
            let first = ceil(timelineStart * rate) / rate
            var last = (ceil(timelineEnd * rate) - 1) / rate
            if last >= timelineEnd { last -= 1 / rate }
            guard first >= timelineStart, first <= last, last < timelineEnd else { return nil }
            return first...last
        }

        func sourceTime(_ projectTime: Double) -> Double {
            sourceStart + (projectTime - timelineStart) * speed
        }

        func projectSample(_ desired: Double, in bounds: ClosedRange<Double>) -> Double {
            let frame = (desired * Double(fps)).rounded() / Double(fps)
            return min(bounds.upperBound, max(bounds.lowerBound, frame))
        }

        var sourceRequests: [Double] {
            guard let bounds = projectBounds else { return [] }
            let head = [0.0, 0.25, 0.5, 1, 1.5, 2].map { projectSample(bounds.lowerBound + $0, in: bounds) }
            let tail = [2.0, 1.5, 1, 0.5, 0].map { projectSample(bounds.upperBound - $0, in: bounds) }
            return Array(Set((head + tail).map(sourceTime))).sorted()
        }

        func containsSource(_ time: Double) -> Bool {
            time.isFinite && time >= sourceStart && time < sourceStart + sourceDuration
        }

        /// 转折观察必须跨过至少一工程帧；两个相邻浮点数不能冒充两幅不同画面。
        /// 这仍是调用方请求/观察声明，不是 native 解码 actualTime 或自动动作识别。
        func hasActionSamples(_ times: [Double]) -> Bool {
            guard let bounds = projectBounds, times.allSatisfy(containsSource),
                  let first = times.min(), let last = times.max() else { return false }
            let interval = 1 / Double(fps), minimum = interval * (1 - 1e-9)
            guard (last - first) / speed >= minimum else { return false }
            let a = projectSample(timelineStart + (first - sourceStart) / speed, in: bounds)
            let b = projectSample(timelineStart + (last - sourceStart) / speed, in: bounds)
            return b - a >= minimum
        }
    }

    static func seamRequests(left: UsedWindow, right: UsedWindow) -> [Double] {
        guard let a = left.projectBounds, let b = right.projectBounds else { return [] }
        let tail = [2.0, 1.5, 1, 0.5, 0].map { left.projectSample(a.upperBound - $0, in: a) }
        let head = [0.0, 0.25, 0.5, 1, 1.5, 2].map { right.projectSample(b.lowerBound + $0, in: b) }
        // 真正有空档还要看中间；不能看过两边就把没有采到的黑场当成审查完成。
        let gap = right.timelineStart - left.timelineEnd
        let middle = gap > 1 / Double(left.fps) ? [(left.timelineEnd + right.timelineStart) / 2] : []
        return Array(Set(tail + head + middle)).sorted()
    }

    static func contains(_ required: [Double], in supplied: [Double], tolerance: Double) -> Bool {
        !required.isEmpty && required.allSatisfy { wanted in supplied.contains { $0.isFinite && abs($0 - wanted) <= tolerance } }
    }
}
