import Foundation
import ImageIO
import UniformTypeIdentifiers

// 本机参考图统一测量：只读真实文件与 ImageIO 元数据，不缩图、不转码、不决定用途或价格。
enum SkyStudioReferenceImage {
    static func measure(_ url: URL, role: String, bytes: Double) -> SkyStudioReference? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let size = pixelSize(properties) else { return nil }
        var image = SkyStudioReference(type: "image", file: url, role: role, bytes: bytes)
        image.width = size.width
        image.height = size.height
        image.contentType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
        image.hasTransparency = (properties[kCGImagePropertyHasAlpha] as? Bool) == true
        image.imageCount = CGImageSourceGetCount(source)
        return image
    }

    static func pixelSize(_ properties: [CFString: Any]) -> (width: Double, height: Double)? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let turned = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return turned >= 5 ? (height.doubleValue, width.doubleValue) : (width.doubleValue, height.doubleValue)
    }
}
