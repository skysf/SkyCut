import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 图生视频的首帧：多宽多高、传哪个文件
//
// 管什么：首帧是用户的图，要 `/uploads` 给 Sky Studio（purpose `image`：jpeg / png / webp，最大 30 MB）。
// - 认得的格式、不太大的，原样传；
// - 别的格式（HEIC、TIFF……）或太大的，缩到长边 2048 像素、存成 JPEG（照片按 EXIF 摆正）再传，传完删掉。
// 宽高比（摆正之后的）给 generate_media 挑离它最近的画幅。2026-10-28 起（之前把图编成 data URI 直接送 fal）。
// 不管什么：传（SkyStudioAPI.upload）；能不能读这个文件（调用方先问过 AIWorkspace.confirmReading）。

enum SkyStudioGenerationFrame {
    /// Sky Studio 收的图片上限。
    static let maxBytes = 30 * 1024 * 1024
    static let maxLongEdge = 2048
    private static let passthrough: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]

    /// 要传的那个文件。`temporary`：转出来的，传完删掉。
    struct Prepared: Sendable {
        let url: URL
        let contentType: String
        let temporary: Bool

        func cleanUp() {
            if temporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    struct Problem: Error {
        let message: String
    }

    /// 摆正之后的宽 / 高；读不出来是 nil。
    static func aspect(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // EXIF 方向 5–8 是转了 90 度的：宽高对调。
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? height / width : width / height
    }

    static func prepare(_ url: URL, workFolder: URL) throws -> Prepared {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if let type = passthrough[url.pathExtension.lowercased()], size > 0, size <= maxBytes {
            return Prepared(url: url, contentType: type, temporary: false)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            throw Problem(message: "SkyCut could not read the picture \(url.lastPathComponent).")
        }
        guard let jpeg = resizedJPEG(data) else {
            throw Problem(message: "\(url.lastPathComponent) is not a picture SkyCut can read (use a PNG, JPEG, WebP or HEIC file).")
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let output = workFolder.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: output, options: .atomic)
        return Prepared(url: output, contentType: "image/jpeg", temporary: true)
    }

    /// 缩到长边不超过 `maxLongEdge`、存成 JPEG（照片方向按 EXIF 摆正）。读不出来是 nil。
    static func resizedJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
