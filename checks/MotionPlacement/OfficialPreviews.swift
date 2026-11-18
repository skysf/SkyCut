import CryptoKit
import Foundation
import SrtFlowMCPKit
import SrtFlowWebMotionKit
@testable import SrtFlow

// Three shipped preview assets have a small receipt each. Pin the source/default values and movie bytes so a source edit
// cannot leave the browser showing an older design; actual helper checks above still rerender every current page twice.
@MainActor func officialPreviewChecks(_ template: OfficialWebMotionTemplate, record: WebMotionClipRecord) async throws {
    guard let movie = template.previewURL else { throw AIToolError("Missing bundled preview for \(template.id)") }
    let receiptURL = movie.deletingPathExtension().appendingPathExtension("json")
    let receipt = try JSONDecoder().decode(OfficialPreviewReceipt.self, from: Data(contentsOf: receiptURL))
    motionRequire(receipt.source_sha256 == officialSHA(Data(record.page.utf8))
                    && receipt.parameters.objectValue == WebMotionParameters.object(record.parametersJSON),
                  "\(template.id) bundled preview matches its current page and exact default parameters")
    motionRequire(receipt.movie_sha256 == officialSHA(try Data(contentsOf: movie)),
                  "\(template.id) bundled movie bytes match their generation receipt")
    motionRequire(receipt.width == 320 && receipt.height == 180 && receipt.fps == 24 && receipt.duration == 4,
                  "\(template.id) ships a small 320×180 four-second preview at 24 fps")
    motionRequire(receipt.result.accepted && receipt.result.transparent && receipt.result.frameCount == 96
                    && Set(receipt.result.checks.map(\.name)) == Set(WebMotionCheckName.allCases)
                    && receipt.result.checks.allSatisfy { $0.passed == true },
                  "\(template.id) preview receipt records all six real helper checks and alpha")
    let info = try await MediaProbe.probe(url: movie, ffmpeg: nil).get()
    motionRequire(info.width == receipt.width && info.height == receipt.height && abs(info.duration - receipt.duration) < 0.000001
                    && abs(info.frameRate - Double(receipt.fps)) < 0.000001 && info.alpha == .premultiplied,
                  "\(template.id) shipped movie really has the declared duration, rate, dimensions and premultiplied alpha")
}

private struct OfficialPreviewReceipt: Decodable {
    var source_sha256: String
    var parameters: JSONValue
    var movie_sha256: String
    var width: Int
    var height: Int
    var fps: Int
    var duration: Double
    var result: WebMotionResult
}

private func officialSHA(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
