import Foundation

// MARK: - 打开全部权限时的那段说明（SkyCut 声音方案 5.6、4.5）：纯值
//
// 管什么：从 /models 读的三样一次性费用（设计：MiniMax 中文描述 / Qwen3 英文描述；给声音建 MiniMax 版。各取 price 的
// typical_credits，没有就取 credits；SkyCut 不写死数）、每日额度、长期授权那句（版本 + 英文原文，SkyStudioVoiceCatalog.standingConsent）；
// 拼成给 AI 的英文：
// - `turnOnText`：set_settings 打开全部权限时接在问句后面（AISettingsApproval）；
// - `missingText`：全部权限下这个账号还没有有效的长期授权时，声音那几件事第一次照请求批准模式问一次，问句后面接它（SkyStudioJobGate）。
// 界面上那句授权怎么显示在 FullAccessConsentSheet（认识的版本显示译文，不认识的显示服务器给的英文原文）；这里不查表，纯值。
// 读不到价：AI 那句写「Sky Studio quotes each fee」、界面只写「以报价为准」；读不到授权那句：用 SkyCut 认识的那一版（照它的版本记）。
// 不管什么：读 /models、记 / 撤长期授权（SkyStudioVoiceStanding）、界面怎么摆（FullAccessConsentSheet）。

struct SkyStudioVoiceStandingNotice: Equatable, Sendable {
    struct Fee: Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable { case designChinese, designEnglish, minimaxVersion }
        var kind: Kind
        var credits: Double
    }

    /// 方案 5.6 点名的三个模型：价目从它们的 price 读。
    static let models: [Fee.Kind: String] = [
        .designChinese: "minimax-voice-design", .designEnglish: "qwen3-voice-design", .minimaxVersion: "minimax-voice-clone"
    ]
    /// SkyCut 认识的那一版长期授权（界面有它的译文；读不到 /models 时照它显示、照它的版本记）。
    static let knownStatement = SkyStudioVoiceConsentStatement(
        version: "voice-standing-consent-v1",
        statement: "For every recording I later use to create a voice in SkyCut, I am the person speaking or I have their permission "
            + "to create and use an AI copy of their voice."
    )

    var fees: [Fee]
    var dailyLimit: Double
    var statement: SkyStudioVoiceConsentStatement

    init(catalog: SkyStudioCatalog?, dailyLimit: Double) {
        fees = Fee.Kind.allCases.compactMap { kind in
            guard let id = Self.models[kind], let model = catalog?.models.first(where: { $0.id == id }) else { return nil }
            let credits = model.price["typical_credits"]?.doubleValue ?? model.price["credits"]?.doubleValue
            return credits.flatMap { $0.isFinite && $0 >= 0 ? Fee(kind: kind, credits: $0) : nil }
        }
        self.dailyLimit = dailyLimit
        statement = catalog?.voices?.standingConsent ?? Self.knownStatement
    }

    func credits(_ kind: Fee.Kind) -> Double? { fees.first { $0.kind == kind }?.credits }

    /// set_settings 打开全部权限：做什么不再先问、价目、额度、打开即记下的那句。
    var turnOnText: String {
        "Full access lets AI do these without asking first and report afterwards: read files outside the opened folders and move "
            + "files to the Trash; generate beyond the default specifications; create voices from recordings, build voices' MiniMax "
            + "versions, design and delete voices. " + feeText + " Turning it on also records the user's standing voice consent on Sky "
            + "Studio (\(statement.version)): \"\(statement.statement)\" Show this to the user in their language before they agree."
    }

    /// 全部权限下还没有有效的长期授权：这一次照请求批准模式问，点过头补记，以后不再问。
    var missingText: String {
        "Full access is on, but this Sky Studio account has no standing voice consent on record (it was never recorded, was "
            + "revoked on another Mac, or its statement changed), so SkyCut asks this once. If the user agrees, SkyCut also records "
            + "their standing voice consent (\(statement.version)): \"\(statement.statement)\" and stops asking for voice "
            + "recordings, voice design and MiniMax versions. " + feeText
    }

    private var feeText: String {
        var parts: [String] = []
        if let credits = credits(.designChinese) {
            parts.append("design a voice from a Chinese description (MiniMax) about \(SkyStudioCredits.text(credits)) credits")
        }
        if let credits = credits(.designEnglish) {
            parts.append("from an English description (Qwen3) about \(SkyStudioCredits.text(credits)) credits")
        }
        if let credits = credits(.minimaxVersion) {
            parts.append("build a voice's MiniMax version (once per language) about \(SkyStudioCredits.text(credits)) credits")
        }
        let fees = parts.isEmpty ? "One-time voice fees: Sky Studio quotes each one." :
            "One-time voice fees (Sky Studio's quote decides): " + parts.joined(separator: "; ") + "."
        return fees + " The daily credit limit stays a hard cap (now \(SkyStudioCredits.text(dailyLimit)) credits a day)."
    }
}

extension SkyStudioVoiceConsentStatement {
    init(version: String, statement: String) {
        self.version = version
        self.statement = statement
    }
}
