import CoreGraphics
import Foundation
import SrtFlowCore

// Transition kinds and native geometry; clip persistence remains in VideoEditModels (only the lenient decoding of the
// kind is here, next to it: moved 2026-11-18 to make room in VideoEditModels.swift, which is on the line-count baseline).
// MARK: - 转场

/// 主轨相邻两段之间的转场。
///
/// 全部按「重叠 d 秒」来算：前一段的尾巴和后一段的开头叠在一起渐变/推移/擦除。
/// 这样预览（AVFoundation 斜坡）和导出（ffmpeg xfade）的时间账完全一致。
/// 预览侧三族的合成模型见 docs/architecture/preview-free-transform.md。
///
/// 方向语义与 xfade 实测对齐（2026-08-23 纯色实测）：名字里的方向 = 画面内容
/// / 擦除边的运动方向。pushLeft/wipeLeft 后段从**右**边进来，以此类推。
enum ClipTransition: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case crossFade
    case blackFade
    case whiteFade
    case pushLeft
    case pushRight
    case pushUp
    case pushDown
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .blackFade: return "Black fade"
        case .crossFade: return "Cross dissolve"
        case .whiteFade: return "White fade"
        case .pushLeft: return "Push left"
        case .pushRight: return "Push right"
        case .pushUp: return "Push up"
        case .pushDown: return "Push down"
        case .wipeLeft: return "Wipe left"
        case .wipeRight: return "Wipe right"
        case .wipeUp: return "Wipe up"
        case .wipeDown: return "Wipe down"
        }
    }

    /// ffmpeg `xfade` 滤镜里对应的名字。
    var xfadeName: String? {
        switch self {
        case .none: return nil
        case .blackFade: return "fadeblack"
        case .crossFade: return "fade"
        case .whiteFade: return "fadewhite"
        case .pushLeft: return "slideleft"
        case .pushRight: return "slideright"
        case .pushUp: return "slideup"
        case .pushDown: return "slidedown"
        case .wipeLeft: return "wipeleft"
        case .wipeRight: return "wiperight"
        case .wipeUp: return "wipeup"
        case .wipeDown: return "wipedown"
        }
    }

    /// 三族：淡变（透明度）、推移（平移）、擦除（裁切窗口）。选择器分组
    /// 和预览合成的路径分派都以它为准。
    enum Family {
        case fade, push, wipe
    }

    var family: Family {
        switch self {
        case .none, .crossFade, .blackFade, .whiteFade: return .fade
        case .pushLeft, .pushRight, .pushUp, .pushDown: return .push
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown: return .wipe
        }
    }

    /// 推移的内容运动方向 / 擦除边的运动方向（单位向量，视频坐标 y 向下）。
    /// 淡变族没有方向。
    var motion: (dx: CGFloat, dy: CGFloat)? {
        switch self {
        case .pushLeft, .wipeLeft: return (-1, 0)
        case .pushRight, .wipeRight: return (1, 0)
        case .pushUp, .wipeUp: return (0, -1)
        case .pushDown, .wipeDown: return (0, 1)
        case .none, .crossFade, .blackFade, .whiteFade: return nil
        }
    }

    /// 擦除到进度 p 时，**出场段**还占着的画布区（进场段从对面那条边露出来）。
    func wipeRemainingRect(progress: Double, canvas: CGSize) -> CGRect {
        let p = min(max(progress, 0), 1)
        guard let motion else { return CGRect(origin: .zero, size: canvas) }
        if motion.dx < 0 {
            return CGRect(x: 0, y: 0, width: canvas.width * (1 - p), height: canvas.height)
        } else if motion.dx > 0 {
            return CGRect(x: canvas.width * p, y: 0, width: canvas.width * (1 - p), height: canvas.height)
        } else if motion.dy < 0 {
            return CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * (1 - p))
        } else {
            return CGRect(x: 0, y: canvas.height * p, width: canvas.width, height: canvas.height * (1 - p))
        }
    }
}

extension ClipTransition: LenientCodableEnum {
    static var decodingFallback: ClipTransition { .none }
}
