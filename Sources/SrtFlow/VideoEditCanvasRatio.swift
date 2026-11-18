import SrtFlowCore
import CoreGraphics

// MARK: - 画布比例
//
// 管什么：输出画面的宽高比有哪几种、各自的标准输出尺寸。按素材挑最接近的比例在用到它的地方。
// Its lenient decoding (`LenientCodableEnum`) is at the end of this file since 2026-11-18 (moved out of VideoEditModels.swift,
// which is on the line-count baseline, to make room for a clip field).
// 2026-10-02 从 VideoEditModels.swift 挪出来（那个文件在行数基线上，给工程的磁吸字段腾地方）。

/// 输出画面的宽高比。`auto` 跟随主轨第一段素材。
enum CanvasRatio: String, CaseIterable, Identifiable, Hashable, Sendable {
    case auto
    case wide16x9
    case tall9x16
    case standard4x3
    case tall3x4
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .wide16x9: return "16:9"
        case .tall9x16: return "9:16"
        case .standard4x3: return "4:3"
        case .tall3x4: return "3:4"
        case .square: return "1:1"
        }
    }

    /// 固定比例对应的标准输出尺寸；auto 返回 nil（按素材算）。
    var fixedSize: CGSize? {
        switch self {
        case .auto: return nil
        case .wide16x9: return CGSize(width: 1920, height: 1080)
        case .tall9x16: return CGSize(width: 1080, height: 1920)
        case .standard4x3: return CGSize(width: 1440, height: 1080)
        case .tall3x4: return CGSize(width: 1080, height: 1440)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

extension CanvasRatio: LenientCodableEnum {
    static var decodingFallback: CanvasRatio { .auto }
}
