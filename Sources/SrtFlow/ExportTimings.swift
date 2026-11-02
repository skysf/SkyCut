import Foundation
import SrtFlowMCPKit

// 一次导出的实际阶段计时：单调钟、互斥阶段、排队和失败/取消也保留；不估算百分比或耗时。
final class ExportTimings: @unchecked Sendable {
    static let stages = ["queue", "preparation", "overlay_render", "audio_processing", "prerender", "graph_build", "video_encode", "finalize"]
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var changed = ProcessInfo.processInfo.systemUptime
    private var active: String? = "preparation"
    private var ended: Double?
    private var seconds: [String: Double] = [:]

    func begin(_ stage: String) {
        lock.lock()
        defer { lock.unlock() }
        guard ended == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        close(at: now)
        active = stage
        changed = now
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard ended == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        close(at: now)
        active = nil
        ended = now
    }

    private func close(at now: Double) {
        if let active { seconds[active, default: 0] += max(0, now - changed) }
    }

    var detail: [String: JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        let now = ended ?? ProcessInfo.processInfo.systemUptime
        var measured = seconds
        if let active { measured[active, default: 0] += max(0, now - changed) }
        func value(_ seconds: Double) -> JSONValue { .number((seconds * 1000).rounded() / 1000) }
        let total = max(0, now - started)
        return [
            "phase": .string(active ?? "finished"),
            "phase_seconds": value(active == nil ? 0 : now - changed),
            "timings": [
                "total_seconds": value(total), "processing_seconds": value(max(0, total - (measured["queue"] ?? 0))),
                "complete": .bool(ended != nil),
                "stages": .object(Dictionary(uniqueKeysWithValues: Self.stages.map { ($0, value(measured[$0] ?? 0)) })),
                "video_encode_includes": ["decode", "filter_compositing", "video_encode", "aac_encode", "mux"]
            ]
        ]
    }
}
