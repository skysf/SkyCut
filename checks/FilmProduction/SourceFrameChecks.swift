import CoreGraphics
import CoreMedia
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 合成 CGImage / 原生 CMTime 的来源证据守卫；不抽真实媒体帧，不调用 ffmpeg 或云服务。
func runSourceFrameChecks() async throws {
    let requested = NativeSourceFrameSampler.requestedTime(for: 1.0009)
    check(requested.value == 600 && requested.timescale == 600, "request records the exact quantized native time")
    let fixedGridRequests: [(String, Double, Int64)] = [
        ("trim first", 0.5, 300),
        ("trim last", 0.5 + 28.0 / 24, 1000),
        ("fractional speed2 first", 0.5 + (1.0 / 24 - 0.02) * 2, 326),
        ("fractional speed2 last", 0.5 + (14.0 / 24 - 0.02) * 2, 976)
    ]
    for (label, seconds, ticks) in fixedGridRequests {
        let native = NativeSourceFrameSampler.requestedTime(for: seconds)
        check(native.value == ticks && native.timescale == 600 && native.epoch == 0,
              "fixed MCP \(label) fixture uses its exact native 600-scale request")
    }
    let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    var calls: [(CMTime, CMTime)] = []
    var sample = try await NativeSourceFrameSampler.takeFrame(at: requested, fallbackTolerance: CMTime(value: 13, timescale: 600)) {
        requested, tolerance in
        calls.append((requested, tolerance))
        return (image, CMTime(value: 1001, timescale: 1000))
    }
    check(calls.count == 1 && calls[0].0 == requested && calls[0].1 == .zero, "native sampling first uses the exact request with zero tolerance")
    enum SyntheticReadError: Error { case zeroTolerance }
    calls = []
    let fallback = try await NativeSourceFrameSampler.takeFrame(at: requested, fallbackTolerance: CMTime(value: 13, timescale: 600)) {
        requested, tolerance in
        calls.append((requested, tolerance))
        if calls.count == 1 { throw SyntheticReadError.zeroTolerance }
        return (image, CMTime(value: 1001, timescale: 1000))
    }
    check(calls.count == 2 && calls[0].1 == .zero && calls[1].1 == CMTime(value: 13, timescale: 600), "zero-tolerance failure retries once with the source-space tolerance")
    check(fallback.requestedTime == requested && fallback.actualTime == CMTime(value: 1001, timescale: 1000) && fallback.usedToleranceFallback,
          "fallback preserves actual native time separately from the original quantized request")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-frame-evidence-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("synthetic-source.bin"), png = root.appendingPathComponent("synthetic-png-identity.bin")
    try Data("synthetic source identity fixture".utf8).write(to: source)
    try Data("synthetic PNG identity fixture".utf8).write(to: png)
    let sourceID = SourceFrameEvidence.fileIdentity(source), pngID = SourceFrameEvidence.fileIdentity(png)
    let clipID = UUID(uuidString: "1D9A3C48-008D-46B1-88A6-BB134C1CD7A3")!
    func evidence(_ value: NativeSourceFrameSample, after: JSONValue? = sourceID) -> JSONValue {
        SourceFrameEvidence.make(sample: value, sourceFile: source, sourceClipID: clipID, sourceStart: 1, sourceDuration: 0.1,
            sourceIdentityBefore: sourceID, sourceIdentityAfter: after, imageFile: png, imageIdentity: pngID)
    }
    var result = evidence(sample)
    check(result["scope"] == "upright_source", "scope reports native source pixels, not timeline composition")
    check(result["source_clip_uuid"] == .string(clipID.uuidString), "source UUID is retained as provenance")
    check(result["requested_source_time"]?["value"] == "600", "requested rational value is preserved")
    check(result["requested_source_time"]?["flags"] == 3, "native hasBeenRounded flag is preserved")
    check(result["actual_source_time"]?["value"] == "1001" && result["actual_source_time"]?["timescale"] == 1000,
          "actual native time is preserved instead of reconstructed on the request scale")
    check(abs((result["drift_source_seconds"]?.doubleValue ?? 1) - (sample.actualTime - requested).seconds) < 1e-12,
          "drift is actual minus the quantized request")
    check(result["requested_in_used_window"] == true && result["actual_in_used_window"] == true, "request and actual frame lie inside the trimmed used window")
    check(result["used_source_window"]?["start"] == 1 && result["used_source_window"]?["duration"] == 0.1 &&
          result["used_source_window"]?["bounds"] == "half_open", "original source window is preserved before splitting")
    check(result["source_file_unchanged"] == true && result["image"]?["file_identity"] == pngID, "unchanged source and written PNG retain their stat identities")
    check(result["used_tolerance_fallback"] == false && result["used_tolerance"]?["value"] == "0", "zero-tolerance path is reported explicitly")

    sample.usedToleranceFallback = true
    sample.usedTolerance = CMTime(value: 13, timescale: 600)
    result = evidence(sample)
    check(result["used_tolerance_fallback"] == true && result["used_tolerance"]?["value"] == "13", "fallback flag and actual tolerance stay distinct from drift")
    sample.actualTime = CMTime(value: 11, timescale: 10)
    check(evidence(sample)["actual_in_used_window"] == false, "actual frame at exact used end is outside the half-open window")
    sample.actualTime = CMTime(value: 999, timescale: 1000)
    check(evidence(sample)["actual_in_used_window"] == false, "actual frame before used start is outside")
    sample.actualTime = CMTime(value: 1, timescale: 1)
    check(evidence(sample)["actual_in_used_window"] == true, "actual frame at used start is inside")
    sample.requestedTime = CMTime(value: 11, timescale: 10)
    check(evidence(sample)["requested_in_used_window"] == false, "request rounded onto used end is reported outside even when actual frame is inside")
    sample.actualTime = .indefinite
    check(evidence(sample)["actual_source_time"]?["seconds"] == .null && evidence(sample)["actual_in_used_window"] == false,
          "unknown native timestamp is explicit, never a fabricated in-window frame")

    let large = CMTime(value: 9_007_199_254_740_993, timescale: 600, flags: .valid, epoch: 3)
    let exact = SourceFrameEvidence.time(large)
    check(exact["value"] == "9007199254740993" && exact["epoch"] == "3", "native integer time and epoch never lose JSON integer precision")
    check(!SourceFrameEvidence.contains(large, start: 0, duration: 10), "a different source epoch cannot be declared in a seconds window")
    check(!SourceFrameEvidence.contains(.zero, start: 0, duration: 0), "empty source window contains no frame")
    check(evidence(sample, after: nil)["source_file_unchanged"] == false, "missing post-sample file identity is unknown")
    try Data("a replaced source with changed bytes and size".utf8).write(to: source)
    check(evidence(sample, after: SourceFrameEvidence.fileIdentity(source))["source_file_unchanged"] == false, "source replacement cannot retain unchanged evidence")
    check(SourceFrameEvidence.fileIdentity(root) == nil, "directory cannot be a frame source identity")
    try Data().write(to: png)
    check(SourceFrameEvidence.fileIdentity(png) == nil, "zero-byte PNG cannot provide valid identity evidence")
}
