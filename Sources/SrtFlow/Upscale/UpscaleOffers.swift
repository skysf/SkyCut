import Foundation

// MARK: - Upscale 面板问 Sky Studio 的两件事：有哪些模型、这一段多少积分
//
// 管什么：面板一打开取 `/models`（SkyStudioCatalogCache：10 分钟内不再问）读成 upscale 的档位（UpscaleTier）；用户每换一次范围 / 目标，
// 给每个送得了的档位问一次 `/quote`（同一个请求问过就用记下的）。只订阅这一个小对象的是面板本身（sheet，不读工程）。
// 打开面板**不弹钥匙串授权框**（用户只是想看看价）：读不到就说去设置里点「允许…」；点了「开始」才可能弹（UpscaleJob，面板起的）。
// 不管什么：每个档位能不能送、文件叫什么（UpscalePanelModel）、扣多少（服务器的 /quote）、任务（UpscaleJob）。

@MainActor
final class UpscaleOffers: ObservableObject {
    enum Catalog: Equatable {
        case loading
        case ready([UpscaleTier])
        /// 没有 Key、读不到 Key、问不到：说一句（英文是服务器 / SkyCut 的原话，界面再套一句本地化的前缀）。
        case failed(String)
    }

    enum Quote: Equatable {
        case loading
        case ready(SkyStudioQuote)
        case failed(String)
    }

    @Published private(set) var catalog: Catalog = .loading
    @Published private(set) var quotes: [String: Quote] = [:]

    private let api: SkyStudioAPI
    private var key: String?
    private var started = false

    init(api: SkyStudioAPI = SkyStudioAPI()) {
        self.api = api
    }

    var tiers: [UpscaleTier] {
        if case .ready(let tiers) = catalog { return tiers }
        return []
    }

    /// 面板出现时调一次。
    func load() async {
        guard !started else { return }
        started = true
        switch await SkyStudioJobKey.key(.silent) {
        case .failure(let problem):
            catalog = .failed(problem.message)
        case .success(let found):
            key = found
            do {
                let tiers = UpscaleTier.all(in: try await SkyStudioCatalogCache.shared.catalog(key: found, api: api))
                catalog = tiers.isEmpty ? .failed("Sky Studio offers no upscale model right now.") : .ready(tiers)
            } catch let failure as SkyStudioFailure {
                catalog = .failed(SkyStudioJobError.request(failure).message)
            } catch {
                catalog = .failed(error.localizedDescription)
            }
        }
    }

    /// 这一份报价（问过了就是记下的那个；还没问就去问）。`id` 是同一个请求的记号（档位、目标、宽高秒数帧率）。
    func quote(_ request: SkyStudioJobRequest) -> Quote {
        let id = Self.id(of: request)
        if let known = quotes[id] { return known }
        guard let key else { return .loading }
        quotes[id] = .loading
        let api = self.api
        Task { [weak self] in
            let answer: Quote
            do {
                answer = .ready(try await api.quote(request, key: key))
            } catch let failure as SkyStudioFailure {
                answer = .failed(SkyStudioJobError.request(failure).message)
            } catch {
                answer = .failed(error.localizedDescription)
            }
            self?.quotes[id] = answer
        }
        return .loading
    }

    /// 问过的报价里取一份（不去问：body 里只读不写）。
    func known(_ request: SkyStudioJobRequest) -> Quote? { quotes[Self.id(of: request)] }

    static func id(of request: SkyStudioJobRequest) -> String { request.model + "|" + request.quoteBody.encodedString() }
}
