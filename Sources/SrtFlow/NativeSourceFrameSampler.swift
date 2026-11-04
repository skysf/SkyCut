import AVFoundation
import CoreGraphics
import Foundation

// 原生定格取样的唯一实现；手动 / MCP 定格和旁白尾帧共用。
// 只取摆正后的源画面，不合成时间线、不裁切、不叠文字；保持既有零容差与半帧退路。
struct NativeSourceFrameSample: Sendable {
    var image: CGImage
    /// AVFoundation 实际收到的量化时刻；不能用原始 Double 加 drift 反推 actualTime。
    var requestedTime: CMTime
    var actualTime: CMTime
    var usedToleranceFallback: Bool
    var usedTolerance: CMTime
    var drift: Double { (actualTime - requestedTime).seconds }
}

enum NativeSourceFrameSampler {
    static func requestedTime(for seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    static func fallbackTolerance(for tolerance: Double) -> CMTime {
        CMTime(seconds: max(tolerance, 0.001), preferredTimescale: 600)
    }

    static func extractFrame(from url: URL, atSourceTime seconds: Double, tolerance: Double) async throws -> NativeSourceFrameSample {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
        let requested = requestedTime(for: seconds)
        let window = fallbackTolerance(for: tolerance)
        return try await takeFrame(at: requested, fallbackTolerance: window) { requested, tolerance in
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            return try await generator.image(at: requested)
        }
    }

    /// 原生读取器的窄接缝：自检可交回合成 CGImage / CMTime，不必读真实媒体来验证请求与实取时刻。
    static func takeFrame(
        at requested: CMTime, fallbackTolerance: CMTime,
        read: (CMTime, CMTime) async throws -> (image: CGImage, actualTime: CMTime)
    ) async throws -> NativeSourceFrameSample {
        func take(tolerance: CMTime, fallback: Bool) async throws -> NativeSourceFrameSample {
            let result = try await read(requested, tolerance)
            return .init(image: result.image, requestedTime: requested, actualTime: result.actualTime,
                         usedToleranceFallback: fallback, usedTolerance: tolerance)
        }
        do {
            return try await take(tolerance: .zero, fallback: false)
        } catch {
            // 保留既有退路，取消传递属于单独的已有待办，不在本次改动里改变。
            return try await take(tolerance: fallbackTolerance, fallback: true)
        }
    }
}
