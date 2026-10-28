import Foundation
import SrtFlowMCPKit

// MARK: - `GET /models`：SkyCut 能请求的模型（纯值）
//
// 管什么：每个模型的 id（Sky Studio 自己的名字：`topaz-starlight`、`bytedance-upscaler-pro`、`seedream5-flash`、`minimax-h3`…）、
// kind（一个模型做两种事就列两次，比如 `minimax-h3` 的文生视频和图生视频）、给人看的名字、给人看的价、能收的参数和取值、上限。
// **SkyCut 不写死模型、价格和上限**（收费方案第 5、16、17 条）：面板和 AI 能选什么、upscale 一次最长几秒 / 最高几帧，都从这里读；
// 这里的价只给人看，**扣多少一律问 `/quote`**（宽于 16:9 按高一档收、4K 封顶、按 0.1 秒计这些规矩都在服务器上）。
// 读得宽：认不出的字段、认不出的 kind 都留着不管；少了 id 或 kind 的那一条跳过。
// 合同：Sky Studio 仓库 docs/agents/skycut-api.md「GET /models」。
// 不管什么：去问（SkyStudioAPI.models）、每种活怎么用这些数（各自的调用方）。

struct SkyStudioModel: Equatable, Sendable {
    var id: String
    var kind: String
    var title: String
    /// 给人看的价（`per`、`credits_by_target`…）。扣多少问 `/quote`。
    var price: [String: JSONValue]
    /// 能收的参数和取值（upscale 的 `target`、MiniMax H3 的 `duration` / `resolution`…）。
    var params: [String: JSONValue]
    /// 上限（upscale：`max_source_seconds`、`max_source_fps`、`max_output_pixels`、`max_upload_bytes`）。
    var limits: [String: JSONValue]

    init(id: String, kind: String, title: String, price: [String: JSONValue] = [:], params: [String: JSONValue] = [:], limits: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.price = price
        self.params = params
        self.limits = limits
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty, let kind = json["kind"]?.stringValue, !kind.isEmpty else { return nil }
        self.init(
            id: id, kind: kind, title: json["title"]?.stringValue ?? id, price: json["price"]?.objectValue ?? [:],
            params: json["params"]?.objectValue ?? [:], limits: json["limits"]?.objectValue ?? [:]
        )
    }

    /// 一个上限（数）；没写就是 nil。
    func limit(_ name: String) -> Double? { limits[name]?.doubleValue }

    /// 一个参数能取的那几个值（`params` 里写成数组的那种，比如 upscale 的 `target`）；不是数组就是空的。
    func choices(_ name: String) -> [String] { params[name]?.arrayValue?.compactMap(\.stringValue) ?? [] }
}

struct SkyStudioCatalog: Equatable, Sendable {
    var models: [SkyStudioModel]

    init(models: [SkyStudioModel]) { self.models = models }

    /// `{"models": [...]}`；没有 `models` 数组就不算回答。
    init?(json: JSONValue) {
        guard let entries = json["models"]?.arrayValue else { return nil }
        self.init(models: entries.compactMap(SkyStudioModel.init(json:)))
    }

    /// 某一种活能用的模型，顺序照服务器给的。
    func models(kind: String) -> [SkyStudioModel] { models.filter { $0.kind == kind } }

    func model(_ id: String, kind: String) -> SkyStudioModel? { models.first { $0.id == id && $0.kind == kind } }
}
