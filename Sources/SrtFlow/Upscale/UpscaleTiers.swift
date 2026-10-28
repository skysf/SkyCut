import CoreGraphics
import Foundation

// MARK: - upscale 升到哪一档、用哪个模型、一次能送多少（纯值；2026-10-28 起模型和上限从 Sky Studio 的 /models 读）
//
// 管什么：目标（按短边 1080 / 1440 / 2160，Sky Studio 叫 1080p / 2K / 4K）；Sky Studio 的 upscale 模型（`/models` 里 kind = upscale 的那几条，
// 2026-10-28 是 `topaz-starlight`（Topaz Starlight Precise 2.6，没有 2K）和 `bytedance-upscaler-pro`）能升到哪几档、一次最长几秒、最高几帧、
// 上传最大多少、给人看的每秒价；送去的那一段能不能做、为什么不能；面板上的一句介绍。
// **SkyCut 不写死模型、价格和上限**：都从 /models 来，扣多少问 /quote（收费方案第 9、16、17 条）。fal 那六个档位 2026-10-28 删了（第 6 刀）。
// 不管什么：问 Sky Studio（UpscaleOffers）、裁哪一段（UpscaleRange）、任务（UpscaleJob）。

/// 升到哪一档：按**短边**算，和导出的分辨率档位一个口径（docs/architecture/export-settings.md）。
enum UpscaleTarget: Int, CaseIterable, Codable, Sendable {
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var shortSide: Int { rawValue }

    /// 给人看的档位名（分辨率的叫法不翻译）。
    var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// Sky Studio 的叫法（`/models` 的 `params.target`、`/quote` 和 `/jobs` 的 `params.target`）。
    var skyStudioName: String {
        switch self {
        case .p1080: return "1080p"
        case .p1440: return "2K"
        case .p2160: return "4K"
        }
    }

    init?(skyStudioName: String) {
        guard let match = Self.allCases.first(where: { $0.skyStudioName == skyStudioName }) else { return nil }
        self = match
    }

    /// 源升到这一档要放大几倍。
    func factor(for source: CGSize) -> Double {
        Double(shortSide) / max(1, min(source.width, source.height))
    }

    /// 源的短边已经不比这一档小：没什么可升的。
    func applies(to source: CGSize) -> Bool { factor(for: source) > 1.0001 }

    /// 不问服务器先估的输出尺寸（偶数）：报价回来之前给人看。真正的尺寸看 /quote 的 plan（服务器还会按像素上限封顶）和做出来的文件。
    func outputSize(for source: CGSize) -> CGSize {
        let factor = self.factor(for: source)
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(source.width * factor), height: even(source.height * factor))
    }
}

/// Sky Studio 的一个 upscale 模型（`/models` 里 kind = upscale 的一条）。
struct UpscaleTier: Equatable, Identifiable, Sendable {
    /// 没点名模型时用的（面板的默认、AI 的默认）：Topaz Starlight 快（几分钟），字节 pro 每秒视频要约一分钟。服务器那边没有它就用列表里第一个。
    static let defaultID = "topaz-starlight"

    /// Sky Studio 的模型名，也是文件名里的那一截（`Shot_鲸鱼_1920x1080_topaz-starlight.mp4`）。
    let id: String
    let title: String
    /// 能升到哪几档（服务器给的名字认不出的不管）。
    let targets: [UpscaleTarget]
    /// 一次最长几秒（两头的余料算在里面）、最高几帧、上传最大几字节；服务器没写就是 nil（不拦，服务器会回 invalid_request）。
    let maxSourceSeconds: Double?
    let maxSourceFPS: Double?
    let maxUploadBytes: Int?
    /// 给人看的每秒价（积分）；扣多少问 /quote。
    let creditsPerSecond: [UpscaleTarget: Double]

    init(
        id: String, title: String, targets: [UpscaleTarget], maxSourceSeconds: Double? = nil, maxSourceFPS: Double? = nil,
        maxUploadBytes: Int? = nil, creditsPerSecond: [UpscaleTarget: Double] = [:]
    ) {
        self.id = id
        self.title = title
        self.targets = targets
        self.maxSourceSeconds = maxSourceSeconds
        self.maxSourceFPS = maxSourceFPS
        self.maxUploadBytes = maxUploadBytes
        self.creditsPerSecond = creditsPerSecond
    }

    /// `/models` 的一条；不是 upscale 的、一档都认不出的不算。
    init?(model: SkyStudioModel) {
        guard model.kind == "upscale" else { return nil }
        let targets = model.choices("target").compactMap(UpscaleTarget.init(skyStudioName:))
        guard !targets.isEmpty else { return nil }
        var prices: [UpscaleTarget: Double] = [:]
        for (name, value) in model.price["credits_by_target"]?.objectValue ?? [:] {
            if let target = UpscaleTarget(skyStudioName: name), let credits = value.doubleValue { prices[target] = credits }
        }
        self.init(
            id: model.id, title: model.title, targets: targets.sorted { $0.rawValue < $1.rawValue },
            maxSourceSeconds: model.limit("max_source_seconds"), maxSourceFPS: model.limit("max_source_fps"),
            maxUploadBytes: model.limit("max_upload_bytes").map { Int($0) }, creditsPerSecond: prices
        )
    }

    /// `/models` 里全部 upscale 模型，顺序照服务器给的。
    static func all(in catalog: SkyStudioCatalog) -> [UpscaleTier] {
        catalog.models(kind: "upscale").compactMap(UpscaleTier.init(model:))
    }

    func offers(_ target: UpscaleTarget) -> Bool { targets.contains(target) }

    /// 这一段送不送得了；nil = 能送。`seconds` 是含余料的那一段（UpscaleRange 已经按上限少留了余料）。
    func refusal(seconds: Double, frameRate: Double, target: UpscaleTarget) -> UpscaleRefusal? {
        if !offers(target) { return .targetNotOffered(targets) }
        if let limit = maxSourceFPS, frameRate > limit + 0.01 { return .frameRateTooHigh(limit: limit) }
        if let limit = maxSourceSeconds, seconds > limit + 0.001 { return .tooLong(limit: limit) }
        return nil
    }

    /// 工程里记着的档位名（`ClipUpscaleRecord.tier`）给人看的名字：Sky Studio 的模型名、fal 时代的档位名都认，认不出的原样。
    /// 检查器、对比窗口用（换过源之后不一定还问得到 /models）。
    static func displayName(for id: String) -> String {
        switch id {
        case "topaz-starlight": return "Topaz Starlight"
        case "bytedance-upscaler-pro": return "ByteDance Upscaler Pro"
        case "topaz-precision": return "Topaz precision · Proteus"
        case "topaz-generative": return "Topaz generative · Starlight Precise 2.6"
        case "flux-precise": return "FLUX video upscale · precise"
        case "flux-creative": return "FLUX video upscale · creative"
        case "bytedance-standard": return "ByteDance upscaler · standard"
        case "bytedance-pro": return "ByteDance upscaler · pro"
        default: return id
        }
    }

    /// 面板上的一句介绍（本地化键）：认识的模型才有。
    static func blurb(for id: String) -> String {
        switch id {
        case "topaz-starlight": return "Re-draws detail: fur, leaves, water. No 1440p."
        case "bytedance-upscaler-pro": return "Large-model restoration. Slow: about a minute per second of video."
        default: return ""
        }
    }
}

/// 一段送不了的原因。
enum UpscaleRefusal: Equatable, Sendable {
    /// 选中的那段（不算余料）就超过一次的上限了：先切开。
    case tooLong(limit: Double)
    case frameRateTooHigh(limit: Double)
    case targetNotOffered([UpscaleTarget])

    /// 写给 AI 的（英文）。
    var message: String {
        switch self {
        case .tooLong(let limit):
            return "Sky Studio upscales at most \(Self.seconds(limit)) s at a time (handles included); split the clip and upscale the parts."
        case .frameRateTooHigh(let limit):
            return "Sky Studio upscales video up to \(Int(limit)) fps; this source is faster."
        case .targetNotOffered(let targets):
            return "This model offers only " + targets.map { "\($0.shortSide)p" }.joined(separator: ", ") + "."
        }
    }

    /// 面板上那一行（本地化）。
    var localized: String {
        switch self {
        case .tooLong(let limit): return String(format: L10n("At most %@ s at a time: split the clip first"), Self.seconds(limit))
        case .frameRateTooHigh(let limit): return String(format: L10n("Up to %d fps only"), Int(limit))
        case .targetNotOffered: return L10n("Not offered at this resolution")
        }
    }

    /// 服务器的上限带一点宽限（30 秒收到 30.5 秒）：说给人听的按整秒往下取。
    private static func seconds(_ value: Double) -> String { String(Int(value.rounded(.down))) }
}
