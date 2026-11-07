import CoreGraphics
import Foundation
import ImageIO
import SrtFlowMCPKit
import UniformTypeIdentifiers

// 真 JPEG / PNG 字节经过生产下载器和同一份落盘收口；不重编码、错误 MIME / URL 不能伪装 PNG。
@MainActor
func runImageResultChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-image-result-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, type, mime, remoteSuffix) in [(0, UTType.jpeg, "image/jpeg", "png"), (1, UTType.jpeg, "image/png", "png"),
            (2, UTType.jpeg, "application/octet-stream", ""), (3, UTType.png, "image/png", "png")] {
            let original = folder.appendingPathComponent("source-\(index).data")
            guard let context = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let encoder = CGImageDestinationCreateWithURL(original as CFURL, type.identifier as CFString, 1, nil) else {
                check(false, "image encoder exists"); continue
            }
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
            CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
            check(CGImageDestinationFinalize(encoder), "real image bytes are synthesized")
            let bytes = try Data(contentsOf: original)
            let remote = URL(string: "https://example.org/result" + (remoteSuffix.isEmpty ? "" : ".\(remoteSuffix)"))!
            let suffix = SkyStudioGeneration.fileExtension(contentType: mime, url: remote, kind: .image)
            let download = folder.appendingPathComponent("download-\(index).\(suffix)")
            SkyStudioStub.reset { _ in .data(200, bytes) }
            try await jobAPI().download(remote, to: download)
            let format = try SkyStudioImageResult.format(at: download)
            let file = try SkyStudioImageResult.finalize(download, format: format) { folder.appendingPathComponent("download-\(index).\($0)") }
            checkEqual(file.pathExtension, type == .jpeg ? "jpg" : "png", "actual downloaded bytes determine saved extension")
            checkEqual(format.contentType, type == .jpeg ? "image/jpeg" : "image/png", "actual file content type is reportable separately from remote metadata")
            checkEqual(format.dimensions["width"], 12, "image width comes from downloaded pixels when server width is absent/null")
            checkEqual(format.dimensions["height"], 8, "image height comes from downloaded pixels when server height is absent/null")
            checkEqual(try Data(contentsOf: file), bytes, "original JPEG/PNG bytes are preserved exactly")
            check(SkyStudioStub.log.allSatisfy { $0.method == "GET" && $0.headers["Authorization"] == nil }, "result download does not send Key or regenerate")
        }
        let invalid = folder.appendingPathComponent("not-an-image.png")
        try Data("a server error page".utf8).write(to: invalid)
        check((try? SkyStudioImageResult.format(at: invalid)) == nil, "non-image delivery is a recoverable local failure")
        check(FileManager.default.fileExists(atPath: invalid.path), "failed format verification retains original delivery evidence")
    } catch { check(false, "image download/file verification: \(error)") }
}
