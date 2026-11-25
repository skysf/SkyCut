import CoreGraphics
import Foundation
import ImageIO
import os
import SrtFlowMCPKit
import UniformTypeIdentifiers

// 真 JPEG / PNG 字节经过生产下载器和同一份落盘收口；不重编码、错误 MIME / URL 不能伪装 PNG。
// The image's check runs on the download's private file before it takes a name (SkyStudioImageResult.downloadCheck): its bytes name
// the extension, and an answer holding only a PNG header is never the result, the next GET fetches it again (CXD4 on PR #554).
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
            SkyStudioStub.reset { _ in .data(200, bytes) }
            let found = OSAllocatedUnfairLock<SkyStudioImageResult.Format?>(initialState: nil)
            let file = try await jobAPI().download(remote, into: CloudResultPlace(folder: folder, stem: "download-\(index)", pathExtension: suffix),
                                                   check: SkyStudioImageResult.downloadCheck(found)).url
            guard let format = found.withLock({ $0 }) else { check(false, "the image's check read its format"); continue }
            checkEqual(file.pathExtension, type == .jpeg ? "jpg" : "png", "actual downloaded bytes determine saved extension")
            checkEqual(format.contentType, type == .jpeg ? "image/jpeg" : "image/png", "actual file content type is reportable separately from remote metadata")
            checkEqual(format.dimensions["width"], 12, "image width comes from downloaded pixels when server width is absent/null")
            checkEqual(format.dimensions["height"], 8, "image height comes from downloaded pixels when server height is absent/null")
            checkEqual(try Data(contentsOf: file), bytes, "original JPEG/PNG bytes are preserved exactly")
            check(SkyStudioStub.log.allSatisfy { $0.method == "GET" && $0.headers["Authorization"] == nil }, "result download does not send Key or regenerate")
        }
        // Only a PNG header (8 bytes, its whole declared length): never the result; the next GET brings the image, which then takes
        // its name. Three of them end download_incomplete with nothing placed.
        let png = try Data(contentsOf: folder.appendingPathComponent("source-3.data"))
        var quick = SkyStudioDownloadRetry()
        quick.sleep = { _ in }
        let api = SkyStudioAPI(session: SkyStudioStub.session, base: jobBase, version: "0.18.50", machine: String(repeating: "a", count: 64),
                               downloadRetry: quick)
        let answers = OSAllocatedUnfairLock(initialState: 0)
        SkyStudioStub.reset { _ in answers.withLock { $0 += 1; return $0 } == 1 ? .data(200, png.prefix(8)) : .data(200, png) }
        let remote = URL(string: "https://example.org/header.png")!
        let second = try await api.download(remote, into: CloudResultPlace(folder: folder, stem: "header", pathExtension: "png"),
                                                 check: SkyStudioImageResult.downloadCheck())
        check(second.gets == 2 && (try? Data(contentsOf: second.url)) == png, "a PNG header alone is thrown away; the next GET's image is saved")
        SkyStudioStub.reset { _ in .data(200, png.prefix(8)) }
        do {
            _ = try await api.download(remote, into: CloudResultPlace(folder: folder, stem: "headers", pathExtension: "png"),
                                            check: SkyStudioImageResult.downloadCheck())
            check(false, "three PNG headers never stand as the result")
        } catch let failure as SkyStudioDownloadFailure {
            check(failure.kind == .incomplete && failure.attempts == 3 && failure.lastError.contains("not an image that decodes")
                  && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("headers.png").path),
                  "three PNG headers: download_incomplete after three GETs, nothing placed: \(failure)")
        }
        let invalid = folder.appendingPathComponent("not-an-image.png")
        try Data("a server error page".utf8).write(to: invalid)
        check((try? SkyStudioImageResult.format(at: invalid)) == nil, "non-image delivery is a recoverable local failure")
        check(FileManager.default.fileExists(atPath: invalid.path), "failed format verification retains original delivery evidence")
    } catch { check(false, "image download/file verification: \(error)") }
}
