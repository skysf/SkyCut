import SwiftUI
import SrtFlowCore

// MARK: - 加字的「动效预设」一栏
//
// 管什么：剪辑页「+」里「动效预设…」弹出来的那一栏（2026-11-16 用户定的名字和位置）：三套现成的动效各一张卡，带小样
//（停着是这一套最好看的那一刻，鼠标放上去就循环播一遍），点一张就在播放头放一套（MotionPresetActions.add）。
// 小样是 MotionPresetStill 用导出那套渲染器画的，看到的就是成片里的样子。
// 不管什么：放进时间线以后怎么改（检查器「动画」区的「预设」、每一块自己的检查器）、AI 的 motion_preset。
// 弹出来的是 popover，不继承应用内语言：调用方套 `.appLanguage()`（docs/architecture/localization.md 第三节第 3 条）。

struct MotionPresetPanel: View {
    let project: VideoEditProject
    var onPick: () -> Void = {}

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 8) {
            Text("Motion Presets").font(.headline)
            Text("Lands on the playhead. Type your words; each piece stays an ordinary text or shape.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MotionPresetKind.allCases) { kind in
                MotionPresetCard(kind: kind) {
                    MotionPresetActions.add(kind, to: project)
                    onPick()
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// 一套预设的卡：小样 + 名字 + 一句话。
struct MotionPresetCard: View {
    let kind: MotionPresetKind
    let action: () -> Void

    @State private var hovering = false
    /// 鼠标放上去的那一刻：小样从头播。
    @State private var hoverStart = Date()
    /// 小样用的一组（占位字，跟着界面语言）和停着时那一帧。
    @State private var preview: MotionPresetPreview?
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Button(action: action) {
            HStack(spacing: 10) {
                thumbnail
                    .frame(width: MotionPresetPreview.size.width, height: MotionPresetPreview.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Label(LocalizedStringKey(kind.title), systemImage: kind.icon)
                        .font(.callout.weight(.medium))
                    Text(LocalizedStringKey(kind.blurb))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? AppThemePalette.current.selectionFill : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, !hovering { hoverStart = Date() }
            hovering = inside
        }
        .instantHelp("Add this preset at the playhead")
        // 占位字跟着界面语言：换了语言重新造一份小样。
        .task(id: locale.identifier) { preview = MotionPresetPreview(kind) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            if hovering {
                // 鼠标放上去：循环播一遍（只有这一张卡在画，停下就回到静止的那一帧）。
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    Image(decorative: preview.frame(at: context.date.timeIntervalSince(hoverStart)), scale: MotionPresetPreview.scale)
                        .resizable()
                }
            } else {
                Image(decorative: preview.still, scale: MotionPresetPreview.scale).resizable()
            }
        } else {
            Color.black
        }
    }
}

/// 卡上的小样：一组占位字照 16:9 的画面（960 × 540）造好、画出来，再裁出这一套周围那一块放大看 —— 整幅缩到卡片那么小，
/// 字只有几个像素、读不出来。停着画最好看的那一刻，播的时候按时钟取一帧（裁的地方不变）。
struct MotionPresetPreview {
    static let size = CGSize(width: 136, height: 76.5)
    static let scale = 2.0
    private static let canvas = CGSize(width: 960, height: 540)
    let members: MotionPresetMembers
    let still: CGImage
    let loop: Double
    private let crop: CGRect

    @MainActor
    init?(_ kind: MotionPresetKind) {
        let built = MotionPresetGroups.build(MotionPresetActions.placeholder(kind, hit: 0.3), canvas: Self.canvas)
        let crop = Self.crop(around: MotionPresetLayout.bounds(built, canvas: Self.canvas))
        guard let still = MotionPresetStill.image(built, canvas: Self.canvas, at: MotionPresetStill.showcaseTime(kind, hit: 0.3),
                                                  frameRate: .fps30)?.cropping(to: crop) else { return nil }
        members = built
        self.still = still
        self.crop = crop
        loop = built.end + 0.6
    }

    /// 播了 `elapsed` 秒时的那一帧（一遍放完停 0.6 秒再从头）。
    func frame(at elapsed: Double) -> CGImage {
        let time = max(0, elapsed).truncatingRemainder(dividingBy: loop)
        return MotionPresetStill.image(members, canvas: Self.canvas, at: time, frameRate: .fps30)?.cropping(to: crop) ?? still
    }

    /// 这一套周围留一圈、16:9 的一块（不出画面）。
    private static func crop(around box: CGRect) -> CGRect {
        guard !box.isNull else { return CGRect(origin: .zero, size: canvas) }
        let width = min(canvas.width, max(box.width * 1.4, box.height * 1.9 * 16 / 9, canvas.width * 0.3))
        let height = width * 9 / 16
        let x = min(max(0, box.midX - width / 2), canvas.width - width)
        let y = min(max(0, box.midY - height / 2), canvas.height - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

extension MotionPresetKind {
    /// 卡上的一句话（查表翻译：调用方 `LocalizedStringKey(kind.blurb)`）。
    var blurb: String {
        switch self {
        case .frameReveal: return "A thin box draws around the name, then lets go; the words stay."
        case .focusPull: return "Thin, wide-spaced words pull into focus, then blur away."
        case .titleCounter: return "The title pops in, a line draws under it and a number rolls like a slot machine."
        }
    }
}
