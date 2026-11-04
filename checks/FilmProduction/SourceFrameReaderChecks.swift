import CoreGraphics
import CoreMedia
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 公开来源证据的纯值/属性自检；fixture 只是非空字节，绝不把它说成真实视频或真实提帧。
struct SourceFrameFixture {
    let root: URL
    let source: URL
    let png: URL
    let sourceID: JSONValue
    let pngID: JSONValue
    let image: CGImage
    var bound: SourceFrameReader.BoundSource

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-metadata-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source-fixture.mov")
        png = root.appendingPathComponent("frame-fixture.png")
        try Data("synthetic source stat fixture".utf8).write(to: source)
        try Data("synthetic PNG stat fixture".utf8).write(to: png)
        sourceID = SourceFrameEvidence.fileIdentity(source)!
        pngID = SourceFrameEvidence.fileIdentity(png)!
        image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        bound = .init(identity: sourceID, start: 0, duration: 10, speed: 1, timelineStart: 0, fps: 24, sourceHalfFrame: 0.5 / 24)
    }

    func evidence(atEnd: Bool = false, actual: CMTime? = nil, fallback: Bool = false, scratch: UUID = UUID()) throws -> JSONValue {
        let requested = try SourceFrameReader.requestedTime(bound, atEnd: atEnd)
        let sample = NativeSourceFrameSample(image: image, requestedTime: requested, actualTime: actual ?? requested,
            usedToleranceFallback: fallback,
            usedTolerance: fallback ? NativeSourceFrameSampler.fallbackTolerance(for: bound.sourceHalfFrame) : .zero)
        return SourceFrameEvidence.make(sample: sample, sourceFile: source, sourceClipID: scratch,
            sourceStart: bound.start, sourceDuration: bound.duration, sourceIdentityBefore: sourceID,
            sourceIdentityAfter: sourceID, imageFile: png, imageIdentity: pngID)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

func changed(_ value: JSONValue, _ path: [String], _ replacement: JSONValue?) -> JSONValue {
    var fields = value.objectValue!
    let key = path[0]
    fields[key] = path.count == 1 ? replacement : changed(fields[key]!, Array(path.dropFirst()), replacement)
    return .object(fields)
}
func rejected(_ message: String, _ body: () throws -> Void) {
    do { try body(); check(false, message) } catch { check(true, message) }
}

func runSourceFrameReaderChecks() throws {
    var fixture = try SourceFrameFixture()
    defer { fixture.remove() }
    let input = try fixture.evidence(actual: CMTime(value: 1, timescale: 1000))
    let evidence = try SourceFrameReader.read(input)
    try SourceFrameReader.validate(evidence, against: fixture.bound, atEnd: false)
    try SourceFrameReader.validateFiles(evidence)
    check(evidence.actual.value == 1 && evidence.actual.timescale == 1000 && evidence.requested.timescale == 600,
          "read preserves the independent native actual and requested rational timestamps")
    let rounded = try SourceFrameReader.read(changed(input, ["requested_source_time", "flags"], 3))
    try SourceFrameReader.validate(rounded, against: fixture.bound, atEnd: false)
    check(rounded.requested.flags.rawValue == 3, "equivalent native request ticks keep their rounded flag without becoming stale")
    for key in input.objectValue!.keys.sorted() {
        rejected("missing native metadata field \(key) fails closed") { _ = try SourceFrameReader.read(changed(input, [key], nil)) }
    }
    for path in [["recipe_pin"], ["used_source_window", "profile"], ["actual_source_time", "private"], ["source_file_identity", "token"], ["image", "prompt"]] {
        rejected("unknown source metadata key \(path.joined(separator: ".")) is rejected") { _ = try SourceFrameReader.read(changed(input, path, "forbidden")) }
    }
    for (path, bad): ([String], JSONValue) in [
        (["scope"], "final_composite"), (["scope"], "source_upright"), (["version"], 2),
        (["source_clip_uuid"], "c1"), (["source_file_unchanged"], false), (["source_file_identity", "bytes"], "0"),
        (["source_file_identity", "inode"], "0001"), (["source_file_identity", "path"], "/different.mov"),
        (["used_source_window", "end"], 11), (["used_source_window", "bounds"], "closed"),
        (["requested_in_used_window"], false), (["actual_in_used_window"], false),
        (["actual_source_time", "value"], "1.0"), (["actual_source_time", "value"], "9223372036854775808"),
        (["actual_source_time", "timescale"], 1.5), (["actual_source_time", "timescale"], 0),
        (["requested_source_time", "timescale"], 1200),
        (["actual_source_time", "epoch"], "1"), (["actual_source_time", "flags"], 0),
        (["actual_source_time", "flags"], 5), (["actual_source_time", "seconds"], 1),
        (["drift_source_seconds"], 0), (["used_tolerance_fallback"], 0),
        (["used_tolerance"], SourceFrameEvidence.time(CMTime(value: 1, timescale: 600))),
        (["image", "file"], "relative.png")
    ] {
        rejected("invalid \(path.joined(separator: ".")) is rejected") { _ = try SourceFrameReader.read(changed(input, path, bad)) }
    }
    for actual in [CMTime(value: 10, timescale: 1), CMTime(value: -1, timescale: 600), .indefinite] {
        var outside = try fixture.evidence(actual: actual)
        outside = changed(outside, ["actual_in_used_window"], true)
        rejected("forged in-window flag cannot admit native timestamp \(actual)") { _ = try SourceFrameReader.read(outside) }
    }
    let tail = try SourceFrameReader.read(fixture.evidence(atEnd: true, fallback: true))
    try SourceFrameReader.validate(tail, against: fixture.bound, atEnd: true)
    check(tail.tolerance == NativeSourceFrameSampler.fallbackTolerance(for: fixture.bound.sourceHalfFrame),
          "native quantized fallback tolerance survives strict metadata read and validation unchanged")
    let oneTickWider = try SourceFrameReader.read(changed(try fixture.evidence(atEnd: true, fallback: true),
        ["used_tolerance"], SourceFrameEvidence.time(tail.tolerance + CMTime(value: 1, timescale: 600))))
    rejected("one native tick above the sampler's quantized fallback bound is rejected even with zero actual drift") {
        try SourceFrameReader.validate(oneTickWider, against: fixture.bound, atEnd: true)
    }
    check(tail.requested == NativeSourceFrameSampler.requestedTime(for: 239.0 / 24), "last used grid sample is inside the 10-second window, not its end")
    rejected("an early frame cannot stand in for the declared tail") { try SourceFrameReader.validate(evidence, against: fixture.bound, atEnd: true) }
    var altered = fixture.bound
    altered.identity = changed(altered.identity, ["inode"], "42")
    rejected("different authoritative source identity is rejected") { try SourceFrameReader.validate(evidence, against: altered, atEnd: false) }
    altered = fixture.bound; altered.duration = 9
    rejected("different authoritative used window is rejected") { try SourceFrameReader.validate(evidence, against: altered, atEnd: false) }
    let drifted = try SourceFrameReader.read(fixture.evidence(actual: CMTime(value: 1, timescale: 2)))
    rejected("in-window actual frame with excessive drift is rejected") { try SourceFrameReader.validate(drifted, against: fixture.bound, atEnd: false) }
    let wrongTolerance = try SourceFrameReader.read(changed(try fixture.evidence(fallback: true), ["used_tolerance"], SourceFrameEvidence.time(CMTime(value: 2, timescale: 1))))
    rejected("declared fallback tolerance cannot exceed native project/speed policy") { try SourceFrameReader.validate(wrongTolerance, against: fixture.bound, atEnd: false) }
    let narrowTolerance = try SourceFrameReader.read(changed(try fixture.evidence(fallback: true), ["used_tolerance"], SourceFrameEvidence.time(CMTime(value: 1, timescale: 600))))
    try SourceFrameReader.validate(narrowTolerance, against: fixture.bound, atEnd: false)
    check(narrowTolerance.tolerance.value == 1, "a stricter scratch sampling tolerance need not reconstruct historical clip speed")
    fixture.bound.speed = 2
    fixture.bound.sourceHalfFrame = 1.0 / 24
    let fast = try SourceFrameReader.read(fixture.evidence(atEnd: true, fallback: true))
    try SourceFrameReader.validate(fast, against: fixture.bound, atEnd: true)
    check(fast.requested == NativeSourceFrameSampler.requestedTime(for: 119.0 / 24 * 2), "speed changes the used source grid and tolerance together")
    fixture.bound.speed = 1
    fixture.bound.sourceHalfFrame = 0.5 / 24
    fixture.bound.timelineStart = 0.01
    let fractionalFirst = try SourceFrameReader.read(fixture.evidence())
    let fractionalLast = try SourceFrameReader.read(fixture.evidence(atEnd: true))
    check(fractionalFirst.requested == NativeSourceFrameSampler.requestedTime(for: 1.0 / 24 - 0.01),
          "fractional timeline start uses the first absolute project frame inside the clip")
    check(fractionalLast.requested == NativeSourceFrameSampler.requestedTime(for: 10 - 0.01),
          "fractional timeline end uses the last absolute project frame strictly inside the clip")
    fixture.bound.duration = 0.01
    rejected("short fractional clip with no project-grid sample cannot fabricate an edge") { _ = try fixture.evidence() }
    fixture.bound.duration = 10
    fixture.bound.timelineStart = 0
    fixture.bound.start = 1.0009
    rejected("native quantization below the used start cannot fabricate an in-window edge") { _ = try fixture.evidence() }
    try Data("PNG replacement has different bytes and file size".utf8).write(to: fixture.png)
    rejected("changed PNG identity invalidates stored evidence") { try SourceFrameReader.validateFiles(evidence) }
    try Data().write(to: fixture.png)
    rejected("zero-byte PNG identity is unusable") { try SourceFrameReader.validateFiles(evidence) }
}
