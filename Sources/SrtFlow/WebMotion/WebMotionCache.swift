import CryptoKit
import Foundation
import SrtFlowWebMotionKit

// Immutable rendered movies and page-check receipts. Project files keep the source; this cache can always be rebuilt.
enum WebMotionCache {
    struct Rendered: Sendable {
        var record: WebMotionClipRecord
        var file: URL
        var result: WebMotionResult
        var cacheHit: Bool
    }

    private struct Identity: Encodable {
        var page: String
        var parameters: String
        var duration: Double
        var width: Int
        var height: Int
        var fps: Int
        var versions: WebMotionVersions
        var fonts: [String]
    }

    static func fingerprint(_ record: WebMotionClipRecord, versions: WebMotionVersions,
                            fonts: [String] = []) throws -> String {
        let record = try WebMotionParameters.normalized(record)
        let identity = Identity(page: record.page, parameters: try WebMotionParameters.canonical(WebMotionParameters.object(record.parametersJSON)),
                                duration: record.duration, width: record.width, height: record.height, fps: record.fps,
                                versions: versions, fonts: fonts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    static func render(_ original: WebMotionClipRecord, directory: URL, force: Bool = false) async throws -> Rendered {
        let original = try WebMotionParameters.normalized(original)
        try WebMotionValidation.validate(original)
        let fonts = WebMotionEnvironment.fonts(in: original)
        let identity = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                let versions = WebMotionEnvironment.versions
                return (versions, try fingerprint(original, versions: versions, fonts: WebMotionEnvironment.fontIdentities(fonts)))
            }
        }
        let (versions, key) = try identity.get()
        var record = original
        record.provenance = .init(fingerprint: key, renderer: versions.renderer, macOS: versions.macOS,
                                  macOSBuild: versions.macOSBuild, webKit: versions.webKit, fonts: fonts,
                                  renderedAt: original.provenance?.fingerprint == key ? original.provenance!.renderedAt : Date())
        let movie = directory.appendingPathComponent("motion-\(key).mov")
        let receipt = movie.deletingPathExtension().appendingPathExtension("render.json")
        if !force, let cached = await MediaReadQueue.run(on: MediaReadQueue.analysis, {
            readReceipt(receipt, movie: movie)
        }) {
            return Rendered(record: record, file: movie, result: cached, cacheHit: true)
        }
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        }.get()
        let rendered = try await WebMotionRenderer.render(.init(page: record.page, parameters: Data(record.parametersJSON.utf8),
                                                               duration: record.duration, width: record.width, height: record.height,
                                                               fps: record.fps, output: movie))
        try Task.checkCancellation()
        guard let actual = rendered.result.versions,
              actual == versions else { throw WebMotionRenderError.rendererFailed("The renderer's system identity changed; render again.") }
        let completed = record
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                try JSONEncoder().encode(rendered.result).write(to: receipt, options: .atomic)
                try writePage(completed, movie: movie)
            }
        }.get()
        return Rendered(record: record, file: movie, result: rendered.result, cacheHit: false)
    }

    private static func readReceipt(_ receipt: URL, movie: URL) -> WebMotionResult? {
        guard FileManager.default.fileExists(atPath: movie.path),
              let data = try? Data(contentsOf: receipt), let result = try? JSONDecoder().decode(WebMotionResult.self, from: data),
              result.accepted, result.checks.count == WebMotionCheckName.allCases.count,
              result.checks.allSatisfy({ $0.passed == true }) else { return nil }
        return result
    }

    static func writePage(_ record: WebMotionClipRecord, movie: URL) throws {
        try record.page.write(to: movie.deletingPathExtension().appendingPathExtension("html"), atomically: true, encoding: .utf8)
        try Data(record.parametersJSON.utf8).write(to: movie.deletingPathExtension().appendingPathExtension("parameters.json"), options: .atomic)
    }
}
