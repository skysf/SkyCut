import AppKit
import Foundation
import SrtFlowMCPKit

// MARK: - SkyCut 这一头的 Sky Studio 账号：Key 存没存、上一次 /me 问到了什么、什么时候再问
//
// 管什么：设置里存 / 删 Key（存的时候马上问一次，Sky Studio 不认就不留）；拿 Key 问 /me —— 启动时、回到 SkyCut 时、
// 每小时看一眼，按 SkyStudioRefresh 的规矩到时候了才真去问；回答存进 UserDefaults，断网时照它用到 valid_until；
// 此刻作数的授权（`license`，规则在 SkyCutLicense）；照授权拦的那几处从这里问（AI 的调用、导出带不带水印，规矩在 SkyCutGates）。
// 订阅它的只有设置那一节和导出面板上「会带水印」那一行（一个小对象，不读工程）。
// 不管什么：HTTP（SkyStudioAPI）、钥匙串（SkyStudioKey / KeychainSecret）、拦在哪（AIToolRouter、VideoEditExporter）。
//
// **后台问的时候从不弹钥匙串的授权框**（用户没在看，弹出来的框没人懂）：读不到就记下「要授权」，设置里点一下才弹。

@MainActor
final class SkyStudioAccount: ObservableObject {
    static let shared = SkyStudioAccount()

    /// 上一次问到的 /me 存在这里（UserDefaults，身份类的名字照旧用 SrtFlow 前缀，docs/architecture/product-name.md）。
    static let storedAnswerKey = "SrtFlow.skystudio.me.v1"

    /// 有没有存 Key。变了：记着的 /models 作废、同步「配了哪些提供方」的小文件（upscale_clip 跟着 Sky Studio 的 Key 列不列）。
    @Published private(set) var hasKey: Bool {
        didSet {
            guard hasKey != oldValue else { return }
            SkyStudioCatalogCache.shared.forget()
            syncProviders()
        }
    }
    @Published private(set) var stored: SkyStudioStoredAnswer?
    @Published private(set) var checking = false
    /// 设置那一节下面要说的一件事（AI 被挡住时回给它的话也照它说）。
    @Published private(set) var problem: SkyStudioProblem?

    private let defaults: UserDefaults
    private var lastFailure: Date?
    private var started = false
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasKey = SkyStudioKey.secret.exists()
        stored = Self.load(defaults)
    }

    /// 此刻作数的授权。
    var license: SkyCutLicense { SkyCutLicense.evaluate(stored, hasKey: hasKey, now: Date()) }

    // MARK: 照授权拦（收费方案第 5 刀第二步，规矩在 SkyCutGates）

    /// 导出要不要因为授权带水印：导出器和导出面板那一行都问它（测试开关另算，在 WatermarkPolicy）。
    var exportsWithWatermark: Bool { SkyCutGates.watermark(license: license, enforced: SkyCutGates.enforced()) }

    /// AI 的这个调用让不让做；不让做回给 AI 的话（AIToolRouter 在排队之前问）。照授权拦关着时什么都不问、都让做。
    func aiRefusal(for tool: MCPToolName) async -> String? {
        guard SkyCutGates.enforced() else { return nil }
        let settled = await settledLicense(waitingUpTo: SkyStudioAPI.requestTimeout)
        if SkyCutGates.aiAllows(tool, license: settled, enforced: true) { return nil }
        return SkyCutGates.aiRefusal(license: settled, problem: problem, now: Date())
    }

    /// 此刻的授权不作数（没问到过、过期了）又有 Key 时，先问一次再算：刚启动、离线好几天之后的第一个调用，不该因为还没问完就被挡。
    /// 正在问就等它；该问了就问（没问成过不到 5 分钟的不再问，照 SkyStudioRefresh）。最多等 `limit` 秒，到了按那时的算。
    func settledLicense(waitingUpTo limit: TimeInterval) async -> SkyCutLicense {
        guard hasKey, license.basis != .server else { return license }
        refreshIfDue(after: 0)
        let deadline = Date().addingTimeInterval(limit)
        // 先睡一下再看：refreshIfDue 起的那一次要在主线程上轮到它才把 checking 设上。
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
        } while checking && Date() < deadline
        return license
    }

    // MARK: 什么时候问

    /// 启动时调一次：到时候了就问；之后回到 SkyCut 时、每小时各看一眼。
    func start() {
        guard !started else { return }
        started = true
        syncProviders()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfDue(after: SkyStudioRefresh.onActivation) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfDue(after: SkyStudioRefresh.inBackground) }
        }
        // 独立冒烟 App 只对回环假服务装入假 Key；正式 / Beta 的身份和生产地址都不认这个钩子。
        let environment = ProcessInfo.processInfo.environment
        if Bundle.main.bundleIdentifier?.hasSuffix(".skystudiosmoke") == true,
           let host = SkyStudioAPI.configuredBase(environment).host, SkyStudioAPI.isLoopback(host),
           let key = environment["SRTFLOW_SMOKE_SKYSTUDIO_KEY"] {
            Task { await saveKey(key) }
        } else {
            refreshIfDue(after: SkyStudioRefresh.onActivation)
        }
    }

    /// 启动与 Key 变化时同步工具提供方标记：只有名字，没有密钥；保持既有目录与文件身份。
    private func syncProviders() {
        let url = MCPProviderMarker.url(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow")
        do { try MCPProviderMarker.write(hasKey ? [.skystudio] : [], to: url) }
        catch { FileHandle.standardError.write(Data("SkyCut: could not update provider marker.\n".utf8)) }
    }

    func refreshIfDue(after interval: TimeInterval) {
        guard hasKey, !checking,
              SkyStudioRefresh.isDue(stored: stored, lastFailure: lastFailure, now: Date(), after: interval) else { return }
        Task { await refresh() }
    }

    /// 问一次 /me。`promptKeychain`：钥匙串要授权时弹不弹框 —— 只有用户在设置里点了按钮才传 true。
    func refresh(promptKeychain: Bool = false) async {
        guard hasKey, !checking else { return }
        checking = true
        defer { checking = false }
        let read = promptKeychain ? await SkyStudioKey.cache.key() : await SkyStudioKey.cache.keyWithoutPrompt()
        switch read {
        case .key(let key):
            await ask(with: key)
        case .missing:
            // 在「钥匙串访问」里被删掉了：当没有 Key。
            forget()
        case .needsPermission:
            problem = .needsKeychainPermission
        case .failed(let status):
            problem = .keychain(KeychainSecret.StoreError(status: status).message)
        }
    }

    // MARK: 存 / 删 Key

    /// 存一把新 Key：整理、存进钥匙串、马上问一次 /me。Sky Studio 不认（`invalid_key`）就不留着它；没连上就先留着，之后再问。
    func saveKey(_ raw: String) async {
        guard !checking else { return }
        guard let key = SkyStudioKey.normalized(raw) else {
            problem = .notAKey
            return
        }
        do {
            try SkyStudioKey.secret.save(key)
        } catch {
            problem = .keychain((error as? KeychainSecret.StoreError)?.message ?? error.localizedDescription)
            return
        }
        await SkyStudioKey.cache.remember(key)
        hasKey = true
        SkyStudioCatalogCache.shared.forget()
        // 上一把 Key 问到的那份不算这一把的。
        replaceStored(nil)
        lastFailure = nil
        problem = nil
        checking = true
        await ask(with: key)
        checking = false
        if case .keyRejected? = problem {
            try? SkyStudioKey.secret.delete()
            await SkyStudioKey.cache.remember(nil)
            hasKey = false
        }
    }

    func removeKey() {
        do {
            try SkyStudioKey.secret.delete()
        } catch {
            problem = .keychain((error as? KeychainSecret.StoreError)?.message ?? error.localizedDescription)
            return
        }
        Task { await SkyStudioKey.cache.remember(nil) }
        forget()
    }

    // MARK: 问

    private func ask(with key: String) async {
        do {
            let me = try await SkyStudioAPI().me(key: key)
            replaceStored(SkyStudioStoredAnswer(me: me, receivedAt: Date()))
            problem = nil
            lastFailure = nil
        } catch is CancellationError {
            return
        } catch let failure as SkyStudioFailure {
            lastFailure = Date()
            problem = Self.problem(for: failure)
            // Key 作废了：这把 Key 以前问到的授权不再作数（不然一直用到 valid_until）。
            if case .keyRejected = problem { replaceStored(nil) }
        } catch {
            lastFailure = Date()
            problem = .unreachable(String(format: L10n("Could not reach Sky Studio (%@)."), error.localizedDescription))
        }
    }

    static func problem(for failure: SkyStudioFailure) -> SkyStudioProblem {
        switch failure {
        case .server(let error) where error.code == SkyStudioServerError.invalidKey:
            return .keyRejected(error.message)
        case .server(let error) where error.code == SkyStudioServerError.upgradeRequired:
            return .updateRequired(error.message, error.downloadURL)
        case .server(let error):
            return .unreachable(error.message)
        case .network(let detail):
            return .unreachable(String(format: L10n("Could not reach Sky Studio (%@)."), detail))
        case .badAnswer(let status):
            return .unreachable(String(format: L10n("Sky Studio sent an answer SkyCut does not understand (HTTP %d)."), status))
        }
    }

    // MARK: 存下来的回答

    private func forget() {
        hasKey = false
        replaceStored(nil)
        problem = nil
        lastFailure = nil
    }

    private func replaceStored(_ answer: SkyStudioStoredAnswer?) {
        stored = answer
        if let answer, let data = try? SkyStudioJSON.encoder().encode(answer) {
            defaults.set(data, forKey: Self.storedAnswerKey)
        } else {
            defaults.removeObject(forKey: Self.storedAnswerKey)
        }
    }

    private static func load(_ defaults: UserDefaults) -> SkyStudioStoredAnswer? {
        guard let data = defaults.data(forKey: storedAnswerKey) else { return nil }
        return try? SkyStudioJSON.decoder().decode(SkyStudioStoredAnswer.self, from: data)
    }
}
