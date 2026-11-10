import Foundation
import SrtFlowMCPKit

// MARK: - 全部权限下声音那几件事不再问：长期授权（`/voices/consent-grant`，接口在 SkyStudioVoiceAPI）
//
// 管什么（SkyCut 声音方案 4.5、5.6）：
// - **此刻照什么办**（`voiceAsk`）：请求批准模式照问（`.ask`）；全部权限下 GET 一次 —— 有效 = 不问（`.standing`：建声音带
//   `consent: "standing_grant"`，设计、建 MiniMax 版直接做，做完说），读不到 / 没有 / 文案过期 = 照请求批准模式问一次、问句后面接
//   打开全部权限时那段说明（`.once`，`missing`），点过头补记一条（`recordAfterApproval`），以后不再问；
// - **切模式**（`modeChanged`：设置窗口和 set_settings 切完都调它）：打开 = 记一条（POST，带用户看到的那一版），关掉 = 撤（DELETE）；
//   记不上照样打开（声音那几件事第一次还会问一次），设置里那一行看 `status`；
// - **升级前就开着全部权限**（`migrateIfNeeded`：SkyStudioAccount 读到 Key 时调）：这台 Mac 上只做一次，直接替用户记上、不问
//   （用户 2026-11-09 定：只有用户本人在用）；开着的是请求批准就什么都不做；记上了 / 不用记都不再来，没记上下次读到 Key 再试。
// `/voices/consent-grant` 的三个请求只经这里（设置里的新建声音对话框要知道有没有有效的长期授权，也问 `hasActiveGrant`）。
// 不管什么：问句和令牌（SkyStudioJobGate、SkyStudioVoiceApproval）、说明的文字（SkyStudioVoiceStandingNotice）、界面（FullAccessConsentSheet）。

@MainActor
final class SkyStudioVoiceStanding: ObservableObject {
    static let shared = SkyStudioVoiceStanding()
    /// 这台 Mac 上「升级前就开着全部权限 → 替用户记上」做过没有（身份类的键照旧用 SrtFlow 前缀，docs/architecture/product-name.md）。
    static let migratedKey = "SrtFlow.skystudio.voiceStandingConsentMigrated.v1"

    enum Status: Equatable {
        case unknown
        case recording
        case recorded(version: String)
        /// 记不上（没登录、读不到 Key、没连上、Sky Studio 不收）：原因是给 AI 的英文。
        case notRecorded(String)
        case revoked
        case notRevoked(String)

        var json: JSONValue {
            switch self {
            case .unknown: return ["status": "unknown"]
            case .recording: return ["status": "recording"]
            case .recorded(let version): return ["status": "recorded", "statement_version": .string(version)]
            case .notRecorded(let reason):
                return ["status": "not_recorded", "reason": .string(reason),
                        "next_step": "Full access is on, but the standing voice consent is not on record: the first voice recording, voice design or MiniMax version asks once, and agreeing records it."]
            case .revoked: return ["status": "revoked"]
            case .notRevoked(let reason): return ["status": "not_revoked", "reason": .string(reason)]
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    /// 设置窗口、set_settings、升级补记用的 Key 和接口（生产是钥匙串静默读 + 真接口；回归换成假的）。
    var services = SkyStudioVoiceServices()
    private let defaults: UserDefaults
    private let access: AIAccessStore
    private var migration: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, access: AIAccessStore? = nil) {
        self.defaults = defaults
        self.access = access ?? .shared
    }

    // MARK: 声音那几件事此刻照什么办

    func voiceAsk(key: String, api: SkyStudioAPI) async -> SkyStudioJobGate.VoiceAsk {
        guard access.mode == .full else { return .ask }
        if await readGrant(key: key, api: api) == true { return .standing }
        return await missing(key: key, api: api)
    }

    /// 这个账号此刻有没有有效的长期授权（设置里的新建声音对话框照它预先勾上那一句，NewVoiceModel）。读不到当没有。
    func hasActiveGrant(key: String, api: SkyStudioAPI) async -> Bool {
        await readGrant(key: key, api: api) == true
    }

    /// GET 一次：有效 = true，明说没有 / 文案过期 = false（状态跟着改），读不到 = nil（状态不动）。
    private func readGrant(key: String, api: SkyStudioAPI) async -> Bool? {
        guard let state = try? await api.voiceConsentGrant(key: key) else { return nil }
        if let grant = state.grant, grant.active {
            status = .recorded(version: grant.statementVersion)
            return true
        }
        status = .notRecorded("This Sky Studio account has no standing voice consent on record.")
        return false
    }

    /// 全部权限下还没有有效的长期授权（或者 Sky Studio 刚拒了 standing_grant）：问一次，问句后面接那段说明，点过头补记它说的那一版。
    func missing(key: String, api: SkyStudioAPI) async -> SkyStudioJobGate.VoiceAsk {
        let notice = await notice(key: key, api: api)
        return .once(explanation: notice.missingText, statementVersion: notice.statement.version)
    }

    /// 打开全部权限时那段说明要的价、额度、授权那句（读不到 /models 就只有额度和 SkyCut 认识的那一版）。
    func notice(key: String?, api: SkyStudioAPI) async -> SkyStudioVoiceStandingNotice {
        var catalog: SkyStudioCatalog?
        if let key { catalog = try? await SkyStudioCatalogCache.shared.catalog(key: key, api: api) }
        return SkyStudioVoiceStandingNotice(catalog: catalog, dailyLimit: SkyStudioSpendStore.shared.dailyLimit)
    }

    /// 设置窗口和 set_settings 用：Key 照 services 读（不弹框），读不到也给一份。
    func notice() async -> SkyStudioVoiceStandingNotice {
        await notice(key: try? await services.key(), api: services.api)
    }

    /// 全部权限下第一次问、用户点过头：补记一条。记不上不挡这一次（这一次已经问过），下一次还会问一次。
    func recordAfterApproval(_ ask: SkyStudioJobGate.VoiceAsk, key: String, api: SkyStudioAPI) async {
        guard case .once(_, let version) = ask else { return }
        _ = await record(statementVersion: version, key: key, api: api)
    }

    /// 全部权限下没问就做了的：工程的提示条上也说一句（结果里另有给 AI 的话，方案 4.5「事后通知」）。
    func notify(_ text: String, project: VideoEditProject?) {
        project?.notice = text
    }

    // MARK: 切模式

    /// 设置窗口、set_settings 切完模式之后调：打开记一条（用户看到的那一版）、关掉撤掉。
    @discardableResult
    func modeChanged(to mode: AIAccessMode, statementVersion: String) async -> Status {
        let key: String
        do { key = try await services.key() }
        catch {
            let reason = (error as? AIToolError)?.message ?? error.localizedDescription
            status = mode == .full ? .notRecorded(reason) : .notRevoked(reason)
            return status
        }
        switch mode {
        case .full: return await record(statementVersion: statementVersion, key: key, api: services.api)
        case .ask: return await revoke(key: key, api: services.api)
        }
    }

    private func record(statementVersion: String, key: String, api: SkyStudioAPI) async -> Status {
        status = .recording
        do {
            let state = try await api.recordVoiceConsentGrant(statementVersion: statementVersion, key: key)
            status = .recorded(version: state.grant?.statementVersion ?? statementVersion)
            defaults.set(true, forKey: Self.migratedKey)
        } catch {
            status = .notRecorded(SkyStudioVoiceLibraryErrors.message(error))
        }
        return status
    }

    private func revoke(key: String, api: SkyStudioAPI) async -> Status {
        do {
            try await api.revokeVoiceConsentGrant(key: key)
            status = .revoked
        } catch {
            status = .notRevoked(SkyStudioVoiceLibraryErrors.message(error))
        }
        return status
    }

    // MARK: 升级前就开着全部权限

    /// 换了 Key：上一个账号记没记过不算这一个的。
    func accountChanged() {
        status = .unknown
    }

    /// 读到 Key 时调（SkyStudioAccount）：这台 Mac 上第一次、开着全部权限、这个账号还没有有效的长期授权，就替用户记上。
    @discardableResult
    func migrateIfNeeded(key: String) -> Task<Void, Never>? {
        guard migration == nil, !defaults.bool(forKey: Self.migratedKey) else { return migration }
        guard access.mode == .full else {
            defaults.set(true, forKey: Self.migratedKey)
            return nil
        }
        let api = services.api
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.migration = nil }
            if let grant = (try? await api.voiceConsentGrant(key: key))?.grant, grant.active {
                self.status = .recorded(version: grant.statementVersion)
                self.defaults.set(true, forKey: Self.migratedKey)
                return
            }
            let notice = await self.notice(key: key, api: api)
            _ = await self.record(statementVersion: notice.statement.version, key: key, api: api)
        }
        migration = task
        return task
    }
}
