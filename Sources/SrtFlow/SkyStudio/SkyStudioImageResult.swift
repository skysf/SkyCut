import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 生成图片的实际文件格式
// 管什么：下载后用 ImageIO 读真实格式，纠正扩展名而不重编码；不改远端元数据、不重新生成、不解释扣费。
enum SkyStudioImageResult {
    struct Format: Equatable, Sendable {
        var fileExtension: String
        var contentType: String
    }

    /// MIME / URL 用于下载时的初始命名；最终扩展名以实际图像字节为准。
    static func format(at file: URL) throws -> Format {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let name = CGImageSourceGetType(source) as String?, let type = UTType(name),
              let suffix = type.preferredFilenameExtension, let mime = type.preferredMIMEType else {
            throw AIToolError("The original image result was downloaded but its format could not be verified. Recover the original job; do not regenerate.")
        }
        return Format(fileExtension: suffix == "jpeg" ? "jpg" : suffix, contentType: mime)
    }

    static func finalize(_ file: URL, format: Format, claim: (String) -> URL) throws -> URL {
        guard file.pathExtension.lowercased() != format.fileExtension else { return file }
        let corrected = claim(format.fileExtension)
        try FileManager.default.moveItem(at: file, to: corrected)
        return corrected
    }
}
