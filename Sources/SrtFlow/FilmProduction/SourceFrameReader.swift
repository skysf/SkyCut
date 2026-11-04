import CoreMedia
import Foundation
import SrtFlowMCPKit

// 原生 source_frame 的严格公开入口；保留 CMTime 原始整数，不把源帧冒充最终合成画面。
// read 只验值；validateFiles 只读 stat，调用方必须在已授权路径上并放到 MediaReadQueue。
enum SourceFrameReader {
    struct Evidence {
        let json: JSONValue
        let sourceClipID: UUID
        let sourceFile: URL
        let sourceIdentity: JSONValue
        let sourceStart: Double
        let sourceDuration: Double
        let requested: CMTime
        let actual: CMTime
        let drift: Double
        let usedFallback: Bool
        let tolerance: CMTime
        let imageFile: URL
        let imageIdentity: JSONValue
    }

    /// 由当前 from_shot 的绑定 clip 构造；不是调用方自报的 source_frame 字段。
    struct BoundSource {
        var identity: JSONValue
        var start: Double
        var duration: Double
        var speed: Double
        var timelineStart: Double
        var fps: Int
        var sourceHalfFrame: Double
    }

    /// 只收集权限候选路径，不表示 source_frame 合法，不读任何文件属性。
    /// 存盘 Data 只投影 image.file；完整事实仍必须经过下方唯一的 read/validate。
    static func permissionImageURL(_ data: Data) -> URL? {
        guard data.count <= 32_768,
              let value = try? JSONDecoder().decode(PermissionImage.self, from: data) else { return nil }
        return try? file(.string(value.image.file), at: "source_frame.image.file")
    }

    static func permissionImageURL(_ input: JSONValue?) -> URL? {
        try? file(input?["image"]?["file"], at: "source_frame.image.file")
    }

    private struct PermissionImage: Decodable {
        struct Image: Decodable { var file: String }
        var image: Image
    }

    static func read(_ input: JSONValue, at path: String = "source_frame") throws -> Evidence {
        let value = try object(input, keys: ["version", "scope", "source_clip_uuid", "source_file", "source_file_identity",
            "source_file_unchanged", "used_source_window", "requested_source_time", "actual_source_time", "drift_source_seconds",
            "used_tolerance_fallback", "used_tolerance", "requested_in_used_window", "actual_in_used_window", "image"], at: path)
        guard value["version"] == 1, value["scope"] == "upright_source",
              let uuid = value["source_clip_uuid"]?.stringValue.flatMap(UUID.init(uuidString:)),
              value["source_file_unchanged"] == true else {
            throw error(path, "Use complete upright_source version 1 evidence from an unchanged native source file.")
        }
        let sourceFile = try file(value["source_file"], at: path + ".source_file")
        let sourceIdentity = try identity(value["source_file_identity"], file: sourceFile, at: path + ".source_file_identity")
        let window = try object(value["used_source_window"], keys: ["start", "duration", "end", "bounds"], at: path + ".used_source_window")
        let start = try number(window["start"], at: path + ".used_source_window.start")
        let duration = try number(window["duration"], at: path + ".used_source_window.duration")
        let end = try number(window["end"], at: path + ".used_source_window.end")
        guard start >= 0, duration > 0, end == start + duration, end > start, window["bounds"] == "half_open" else {
            throw error(path + ".used_source_window", "Use the exact positive half-open source window before freezing.")
        }
        let requested = try time(value["requested_source_time"], at: path + ".requested_source_time")
        let actual = try time(value["actual_source_time"], at: path + ".actual_source_time")
        guard requested.timescale == 600,
              value["requested_in_used_window"] == true, value["actual_in_used_window"] == true,
              SourceFrameEvidence.contains(requested, start: start, duration: duration),
              SourceFrameEvidence.contains(actual, start: start, duration: duration) else {
            throw error(path, "Both native requested and actual timestamps must lie inside the used source window; its end is excluded.")
        }
        let drift = try number(value["drift_source_seconds"], at: path + ".drift_source_seconds")
        guard drift == (actual - requested).seconds,
              let fallback = value["used_tolerance_fallback"]?.boolValue else {
            throw error(path, "Keep the native drift and explicit tolerance-fallback flag.")
        }
        let tolerance = try time(value["used_tolerance"], at: path + ".used_tolerance")
        guard fallback || value["used_tolerance"] == SourceFrameEvidence.time(.zero) else {
            throw error(path + ".used_tolerance", "A first-attempt frame reports zero native tolerance.")
        }
        let image = try object(value["image"], keys: ["file", "file_identity"], at: path + ".image")
        let imageFile = try file(image["file"], at: path + ".image.file")
        guard imageFile.pathExtension.lowercased() == "png" else { throw error(path + ".image.file", "Use the native extracted PNG.") }
        let imageIdentity = try identity(image["file_identity"], file: imageFile, at: path + ".image.file_identity")
        return Evidence(json: input, sourceClipID: uuid, sourceFile: sourceFile, sourceIdentity: sourceIdentity,
            sourceStart: start, sourceDuration: duration, requested: requested, actual: actual, drift: drift,
            usedFallback: fallback, tolerance: tolerance, imageFile: imageFile, imageIdentity: imageIdentity)
    }

    static func validate(_ evidence: Evidence, against source: BoundSource, atEnd: Bool, at path: String = "source_frame") throws {
        guard source.identity == evidence.sourceIdentity, source.start == evidence.sourceStart,
              source.duration == evidence.sourceDuration else {
            throw error(path, "The source file identity and used window must match the current bound output of from_shot_id.")
        }
        let expected = try requestedTime(source, atEnd: atEnd, at: path)
        guard CMTimeCompare(evidence.requested, expected) == 0,
              source.sourceHalfFrame.isFinite, source.sourceHalfFrame > 0,
              abs(evidence.drift) <= source.sourceHalfFrame else {
            throw error(path, "Request the declared used-window edge on the project frame grid; native drift must stay within a source-space half frame.")
        }
        let expectedTolerance = evidence.usedFallback
            ? NativeSourceFrameSampler.fallbackTolerance(for: source.sourceHalfFrame) : .zero
        guard CMTimeCompare(evidence.tolerance, expectedTolerance) <= 0 else {
            throw error(path + ".used_tolerance", "The native sampling tolerance must not exceed the current source-space half-frame policy.")
        }
    }

    /// 首尾是当前工程绝对格点落在用窗内的第一/最后一格；不声称是含转场/叠层的最终合成切点。
    static func requestedTime(_ source: BoundSource, atEnd: Bool, at path: String = "source_frame") throws -> CMTime {
        let window = AIFilmProductionSamples.UsedWindow(sourceStart: source.start, sourceDuration: source.duration,
            speed: source.speed, timelineStart: source.timelineStart, fps: source.fps)
        guard let bounds = window.projectBounds else { throw error(path, "The used source window has no current project frame.") }
        let seconds = window.sourceTime(atEnd ? bounds.upperBound : bounds.lowerBound)
        let requested = NativeSourceFrameSampler.requestedTime(for: seconds)
        guard SourceFrameEvidence.contains(requested, start: source.start, duration: source.duration) else {
            throw error(path, "Native time quantization puts this edge outside the used window; obtain another valid source anchor.")
        }
        return requested
    }

    static func validateFiles(_ evidence: Evidence, at path: String = "source_frame") throws {
        guard SourceFrameEvidence.fileIdentity(evidence.sourceFile) == evidence.sourceIdentity,
              SourceFrameEvidence.fileIdentity(evidence.imageFile) == evidence.imageIdentity else {
            throw error(path, "The source or extracted PNG changed or is no longer a nonempty regular file; extract and prepare a fresh anchor.")
        }
    }

    private static func time(_ input: JSONValue?, at path: String) throws -> CMTime {
        let value = try object(input, keys: ["value", "timescale", "epoch", "flags", "seconds"], at: path)
        guard let raw = value["value"]?.stringValue, let ticks = Int64(raw), raw == String(ticks), ticks >= 0,
              value["epoch"] == "0", let scale = value["timescale"]?.doubleValue, scale.isFinite,
              scale.rounded(.towardZero) == scale, scale > 0, scale <= Double(Int32.max),
              let flags = value["flags"]?.doubleValue, flags == 1 || flags == 3 else {
            throw error(path, "Keep a numeric nonnegative native CMTime with exact decimal value/epoch and valid flags.")
        }
        let result = CMTime(value: ticks, timescale: Int32(scale), flags: CMTimeFlags(rawValue: UInt32(flags)), epoch: 0)
        guard result.isNumeric, value["seconds"]?.doubleValue == result.seconds else {
            throw error(path + ".seconds", "Seconds must agree with the original native rational timestamp.")
        }
        return result
    }

    private static func identity(_ input: JSONValue?, file: URL, at path: String) throws -> JSONValue {
        let value = try object(input, keys: ["path", "device", "inode", "bytes", "modified"], at: path)
        guard value["path"] == .string(file.path) else { throw error(path, "File identity must name its exact standardized path.") }
        for key in ["device", "inode", "bytes"] {
            guard let text = value[key]?.stringValue, let integer = UInt64(text), text == String(integer), key != "bytes" || integer > 0 else {
                throw error(path + "." + key, "Use the complete native nonempty file stat identity.")
            }
        }
        _ = try number(value["modified"], at: path + ".modified")
        return .object(value)
    }

    private static func file(_ input: JSONValue?, at path: String) throws -> URL {
        guard let text = input?.stringValue, text.hasPrefix("/"), text.utf8.count <= 4096,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw error(path, "Use an absolute standardized local file path.")
        }
        let url = URL(fileURLWithPath: text).standardizedFileURL
        guard url.path == text else { throw error(path, "Use the exact standardized local file path.") }
        return url
    }

    private static func object(_ input: JSONValue?, keys: [String], at path: String) throws -> [String: JSONValue] {
        let value = try SkyStudioFilmReader.object(input, keys: keys, at: path)
        guard Set(value.keys) == Set(keys) else { throw error(path, "Complete native source-frame evidence is required.") }
        return value
    }

    private static func number(_ input: JSONValue?, at path: String) throws -> Double {
        guard let value = input?.doubleValue, value.isFinite else { throw error(path, "Expected a finite number.") }
        return value
    }

    private static func error(_ path: String, _ message: String) -> SkyStudioFilmError { SkyStudioFilmReader.error(path, message) }
}
