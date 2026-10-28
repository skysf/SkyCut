import Foundation
import SrtFlowMCPKit

// MARK: - Upscale 面板背后的数（从工程算出来，纯值）
//
// 管什么：点开面板的那一段用的原片是谁、这个原片在工程里被哪些画面段用到（换算到原片时间）、三种范围各送几秒（按档位的上限少留余料）、
// 每个档位在当前范围 × 目标下送不送得了、问 Sky Studio 要报价的那一份、估的输出尺寸、文件会叫什么名、画布的短边（默认目标按它选）、
// 「另一处更长」的提示。面板（UpscalePanel）只做显示和回调；AI 的 upscale_clip 用同一份数。点「开始」时这里把 `UpscaleRequest` 拼好。
// 档位从 Sky Studio 的 /models 来（UpscaleOffers 取），价从 /quote 来：这里不写死。
// 不管什么：界面；问 Sky Studio（UpscaleOffers）；钱花不花（面板本身就是确认，UpscaleJob 直接记账；AI 的过 SkyStudioJobGate）。

struct UpscaleTierRow: Identifiable, Equatable {
    var id: String { tier.id }
    let tier: UpscaleTier
    /// 送不了的原因（目标这一档没有、太长、帧率太高）；nil = 能送。
    let refusal: UpscaleRefusal?
    /// 问报价的那一份。
    let quote: SkyStudioJobRequest
    /// 不问服务器先估的输出尺寸（报价回来后看它的 plan）。
    let estimatedSize: CGSize
}

struct UpscalePanelModel {
    let clipID: UUID
    let clipName: String
    let originalURL: URL
    let originalInfo: MediaInfo
    /// 这个原片在工程里的全部用处（原片时间轴上）。
    let uses: [UpscaleUse]
    /// 画布的短边（默认目标按它选）。
    let canvasShortSide: Int
    let fallbackFolders: [URL]

    /// 从工程里算。音频段、图片段、没探测信息的段没有面板（返回 nil）。
    @MainActor
    init?(project: VideoEditProject, clipID: UUID) {
        guard let clip = project.state.allClips.first(where: { $0.id == clipID }), !clip.isAudioOnly, !clip.isStillImage else { return nil }
        let original = clip.upscale?.originalURL ?? clip.sourceURL
        guard let info = clip.upscale?.originalInfo ?? clip.info else { return nil }
        self.clipID = clipID
        clipName = clip.name
        originalURL = original
        originalInfo = info
        uses = project.state.clipIDs(usingPicture: original).compactMap { id in
            guard let user = project.state.allClips.first(where: { $0.id == id }) else { return nil }
            return UpscaleUse(clipID: id, start: ClipSourceSwap.originalStart(of: user), duration: user.sourceDuration)
        }
        let canvas = VideoEditCompositionBuilder.renderSize(for: project.state)
        canvasShortSide = Int(min(canvas.width, canvas.height).rounded())
        var fallbacks: [URL] = []
        if let home = project.documentURL?.deletingLastPathComponent() { fallbacks.append(home) }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { fallbacks.append(downloads) }
        fallbackFolders = fallbacks
    }

    /// 点开的这一段用了多久（面板上「This clip uses …」）。
    var thisUse: UpscaleUse? { uses.first { $0.clipID == clipID } }

    /// 工程里另一处用得更长：提示并默认选最长的那处。
    var longerElsewhere: UpscaleUse? { UpscaleRange.longerUseElsewhere(thisClip: clipID, uses: uses) }

    /// 默认选哪种范围：别处用得更长就选最长的那处，否则这一段。
    var defaultChoice: UpscaleRangeChoice { longerElsewhere == nil ? .thisClip : .longestUse }

    /// 默认目标：画布的短边够得上哪一档就选哪一档（源比它小才有意义），都够不上就 1080p。
    var defaultTarget: UpscaleTarget {
        let fitting = UpscaleTarget.allCases.filter { $0.shortSide <= canvasShortSide && $0.applies(to: originalInfo.displaySize) }
        return fitting.last ?? .p1080
    }

    /// 默认档位：认识的那个在就用它，否则列表里第一个能升到这一档的。
    static func defaultTier(in tiers: [UpscaleTier], target: UpscaleTarget) -> UpscaleTier? {
        if let preferred = tiers.first(where: { $0.id == UpscaleTier.defaultID }), preferred.offers(target) { return preferred }
        return tiers.first { $0.offers(target) } ?? tiers.first
    }

    /// 哪些目标对这个源有意义（源的短边已经不比它小的灰掉）。
    func targetApplies(_ target: UpscaleTarget) -> Bool { target.applies(to: originalInfo.displaySize) }

    /// 送哪一段：两头各留 1 秒余料，这一档一次放不下就少留（`tier` 为 nil 时不管上限）。
    func range(for choice: UpscaleRangeChoice, tier: UpscaleTier?) -> UpscaleRange {
        UpscaleRange.make(
            choice, thisClip: clipID, uses: uses, fileDuration: originalInfo.duration, frameRate: originalInfo.frameRate,
            maxSeconds: tier?.maxSourceSeconds
        )
    }

    func rows(tiers: [UpscaleTier], choice: UpscaleRangeChoice, target: UpscaleTarget) -> [UpscaleTierRow] {
        tiers.map { tier in
            let range = range(for: choice, tier: tier)
            return UpscaleTierRow(
                tier: tier, refusal: tier.refusal(seconds: range.duration, frameRate: originalInfo.frameRate, target: target),
                quote: quoteRequest(range: range, target: target, tier: tier), estimatedSize: target.outputSize(for: originalInfo.displaySize)
            )
        }
    }

    /// 问报价的那一份：`source` 照要送上去的那一段（原片的宽高帧率、范围的秒数）；交任务时照裁出来的文件再报一遍。
    func quoteRequest(range: UpscaleRange, target: UpscaleTarget, tier: UpscaleTier) -> SkyStudioJobRequest {
        UpscaleRequest.job(
            tier: tier, target: target,
            source: UpscaleRequest.source(size: originalInfo.displaySize, seconds: range.duration, frameRate: originalInfo.frameRate)
        )
    }

    func request(choice: UpscaleRangeChoice, target: UpscaleTarget, tier: UpscaleTier, quote: SkyStudioQuote) -> UpscaleRequest {
        UpscaleRequest(
            originalURL: originalURL, originalInfo: originalInfo, range: range(for: choice, tier: tier), tier: tier, target: target,
            credits: quote.credits, typicalSeconds: quote.typicalSeconds, fallbackFolders: fallbackFolders
        )
    }

    /// 报价回来的输出尺寸（服务器按像素上限封过顶）；没有就是估的。
    static func outputSize(_ quote: SkyStudioQuote?, fallback: CGSize) -> CGSize {
        guard let width = quote?.plan["output_width"]?.doubleValue, let height = quote?.plan["output_height"]?.doubleValue,
              width > 0, height > 0 else { return fallback }
        return CGSize(width: width, height: height)
    }

    /// 文件会叫什么（撞名的编号真写的时候才加；尺寸照报价的，落盘时照做出来的文件）。
    func fileName(size: CGSize, tier: UpscaleTier) -> String {
        UpscaleOutputName.stem(original: originalURL, outputSize: size, tier: tier.id) + ".mp4"
    }
}
