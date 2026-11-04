import CoreMedia
import Foundation
import SrtFlowMCPKit

// 定格 PNG 的公开来源证据：原生请求 / 实取时刻、原片用窗、文件身份和源 clip UUID。
// 不认证整条时间线的合成画面，也不挑首尾帧；scratch UUID 仅为来源记录，不替代制作镜头绑定。
enum SourceFrameEvidence {
    static func make(
        sample: NativeSourceFrameSample, sourceFile: URL, sourceClipID: UUID, sourceStart: Double, sourceDuration: Double,
        sourceIdentityBefore: JSONValue?, sourceIdentityAfter: JSONValue?, imageFile: URL, imageIdentity: JSONValue?
    ) -> JSONValue {
        let end = sourceStart + sourceDuration
        return [
            "version": 1, "scope": "upright_source", "source_clip_uuid": .string(sourceClipID.uuidString),
            "source_file": .string(sourceFile.standardizedFileURL.path),
            "source_file_identity": sourceIdentityBefore ?? .null,
            "source_file_unchanged": .bool(sourceIdentityBefore != nil && sourceIdentityBefore == sourceIdentityAfter),
            "used_source_window": ["start": finite(sourceStart), "duration": finite(sourceDuration), "end": finite(end), "bounds": "half_open"],
            "requested_source_time": time(sample.requestedTime), "actual_source_time": time(sample.actualTime),
            "drift_source_seconds": finite(sample.drift), "used_tolerance_fallback": .bool(sample.usedToleranceFallback),
            "used_tolerance": time(sample.usedTolerance),
            "requested_in_used_window": .bool(contains(sample.requestedTime, start: sourceStart, duration: sourceDuration)),
            "actual_in_used_window": .bool(contains(sample.actualTime, start: sourceStart, duration: sourceDuration)),
            "image": ["file": .string(imageFile.standardizedFileURL.path), "file_identity": imageIdentity ?? .null]
        ]
    }

    /// 64 位 value / epoch 保留十进制字符串，避免 JSON Double 舍掉整数位；flags / timescale 是精确的 32 位数。
    static func time(_ value: CMTime) -> JSONValue {
        ["value": .string(String(value.value)), "timescale": .number(Double(value.timescale)),
         "epoch": .string(String(value.epoch)), "flags": .number(Double(value.flags.rawValue)), "seconds": finite(value.seconds)]
    }

    /// 时间窗完全沿用素材的 start / duration；末端为开区间，不用一格或 epsilon 把末端外的帧算进来。
    static func contains(_ time: CMTime, start: Double, duration: Double) -> Bool {
        let end = start + duration
        return time.isNumeric && time.epoch == 0 && start.isFinite && start >= 0 && duration.isFinite && duration > 0 && end.isFinite &&
            time.seconds >= start && time.seconds < end
    }

    /// 和生成确认 / 回执相同的 stat 身份形状；只读非空普通文件。调用方把 IO 放到 MediaReadQueue。
    static func fileIdentity(_ file: URL) -> JSONValue? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
              values[.type] as? FileAttributeType == .typeRegular,
              let bytes = values[.size] as? NSNumber, bytes.int64Value > 0,
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let modified = values[.modificationDate] as? Date else { return nil }
        return ["path": .string(file.standardizedFileURL.path), "device": .string(device.stringValue),
                "inode": .string(inode.stringValue), "bytes": .string(bytes.stringValue), "modified": .number(modified.timeIntervalSince1970)]
    }

    private static func finite(_ value: Double) -> JSONValue { value.isFinite ? .number(value) : .null }
}
