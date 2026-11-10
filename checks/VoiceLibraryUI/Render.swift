import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库界面的离屏渲染（scripts/render-voice-library.sh）：生产的视图 + 假 Sky Studio（VoiceLibraryHTTP：目录快照、`/voices`、`/quote`），
// 三种界面语言各出一套 PNG，给 PR 附图、发版前看排版（截字、漏翻、撑破）。不碰网络、不碰钥匙串、不录音、不花钱，窗口摆在屏幕外。
// 出的是：设置 → 剪辑与声音（有声音 / 没接 Sky Studio / 声音库用不了）、浏览预设、新建声音（刚打开 / 填好）、给声音加录音、设计声音（带报价）。
// 只是出图，不判对错；规矩由 scripts/check-voice-recovery.sh 的 LibraryUIChecks 和 scripts/check-sky-studio.sh 的 VoiceLibraryUIChecks 钉着。

@main enum VoiceLibraryRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.voicelibraryrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Voice library render requires the isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_VOICE_RENDER_OUT"]!)
        let work = URL(fileURLWithPath: environment["SRTFLOW_VOICE_RENDER_WORK"]!)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                try await render(language.rawValue, out: out, work: work)
            }
        } catch {
            print("FAIL: voice library render: \(error)")
            exit(1)
        }
        print("PASS: rendered the voice library UI in en, zh-Hans and es to \(out.path)")
        exit(0)
    }

    @MainActor
    private static func render(_ language: String, out: URL, work: URL) async throws {
        func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language).png") }
        let store = VoiceLibraryStore.shared
        store.api = SkyStudioAPI(session: VoiceLibraryHTTP.session, base: URL(string: "http://127.0.0.1/api/skycut/v1")!, machine: nil)
        store.readKey = { .success("local-library-fixture") }
        SkyStudioCatalogCache.shared.forget()
        SkyStudioSpendStore.shared.setDailyLimit(1_000)

        // 1. 设置 → 剪辑与声音：三个声音。
        seedVoices()
        await store.refresh()
        try await Snapshot.take(SettingsPane(), to: file("1-settings"))

        // 2. 浏览预设声音。
        try await Snapshot.take(VoiceLibrarySheetContent(item: .browse, store: store), to: file("2-browse"))

        // 3. 新建声音：刚打开。
        try await Snapshot.take(NewVoiceSheet(mode: .create, store: store), to: file("3-new-empty"))

        // 4. 新建声音：选了文件、检测出语言、勾了授权。
        let recording = work.appendingPathComponent("interview.wav")
        let samples = (0..<(44_100 * 42)).map { Int16(sin(Double($0) * 0.05) * 6_000) }
        try VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100).write(to: recording)
        let filled = NewVoiceModel(mode: .create, store: store)
        filled.detectLanguage = { _, _ in "zh" }
        filled.name = language == "zh-Hans" ? "我的声音" : (language == "es" ? "Mi voz" : "My voice")
        filled.source = .file
        filled.use(file: recording)
        try await wait("the sample") { if case .ready = filled.sample { return filled.language != nil } else { return false } }
        filled.setAgreed(true)
        try await Snapshot.take(NewVoiceSheet(model: filled, store: store), to: file("4-new-ready"))
        filled.close()

        // 5. 给声音加一段录音（已经有中文的那个）。
        if let voice = store.voices.first {
            try await Snapshot.take(NewVoiceSheet(mode: .addReference(voice), store: store), to: file("5-add-recording"))
        }

        // 6. 设计声音：填好、报价回来了。
        let design = DesignVoiceModel(store: store)
        design.quoteDelay = 0
        design.name = language == "zh-Hans" ? "沉稳旁白" : (language == "es" ? "Narrador sereno" : "Calm narrator")
        design.prompt = language == "zh-Hans" ? "三十多岁的男声，沉稳、语速偏慢，适合纪录片旁白。"
            : (language == "es" ? "Voz masculina de unos treinta años, serena y pausada, para narrar documentales."
               : "A calm male voice in his thirties, unhurried and warm, for documentary narration.")
        try await wait("the design quote") { design.quote != nil }
        try await Snapshot.take(DesignVoiceSheet(model: design), to: file("6-design"))
        design.close()

        // 7. 声音库暂时用不了：预设照常，新建 / 设计灰着。
        VoiceLibraryHTTP.listFailure = (503, ["error": ["code": "voice_library_unavailable", "message": "Not configured.", "reason": "not_configured"]])
        await store.refresh()
        try await Snapshot.take(SettingsPane(), to: file("7-settings-unavailable"))

        // 8. 没接 Sky Studio。
        store.readKey = { .failure(.noKey) }
        await store.refresh()
        try await Snapshot.take(SettingsPane(), to: file("8-settings-no-key"))
    }

    private static func seedVoices() {
        VoiceLibraryHTTP.reset()
        func voice(_ suffix: String, _ name: String, _ languages: [String], source: String = "recording") -> (String, JSONValue) {
            let id = "voice_" + String(repeating: suffix, count: 32)
            let entries: [JSONValue] = languages.map {
                ["language": .string($0), "kind": .string(source == "design" ? "design_sample" : "recording"), "seconds": 41.5, "minimax": false,
                 "preview_url": "https://assets.example/voices/preview.wav", "preview_expires_at": "2099-01-01T00:00:00Z"]
            }
            return (id, ["id": .string(id), "name": .string(name), "source": .string(source), "scope": "personal", "languages": .array(entries)])
        }
        VoiceLibraryHTTP.lock.lock()
        VoiceLibraryHTTP.voices = Dictionary(uniqueKeysWithValues: [
            voice("1", "Sky", ["zh", "en"]), voice("2", "María — podcast", ["es"]), voice("3", "Warm narrator", ["en"], source: "design")
        ])
        VoiceLibraryHTTP.lock.unlock()
    }

    @MainActor
    private static func wait(_ what: String, until done: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if done() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AIToolError("Timed out waiting for \(what)")
    }
}

/// 设置 → 剪辑与声音里声音的那两节，照设置窗口右边那一栏的宽度和样式摆（750 − 164 的导航栏 − 分隔线）。
/// 不渲整个设置窗口：上面「剪辑风格」那一节读的是这台 Mac 上用户自己的风格名，不该进截图。
private struct SettingsPane: View {
    var body: some View {
        Form {
            Section { KokoroVoiceSettingsRow() }
            Section { VoiceLibrarySettingsSection(openSkyStudioSettings: {}) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(AppThemePalette.current.isForest ? .hidden : .visible)
        .frame(width: 585, height: 400)
        .background(AppThemePalette.current.panel)
    }
}

/// 把一个视图放进屏幕外的窗口、等它排好、存成 PNG。
@MainActor
enum Snapshot {
    static func take<Content: View>(_ view: Content, to file: URL) async throws {
        let host = NSHostingView(rootView: view.appLanguage().background(AppThemePalette.current.window))
        // 系统截不到整个在屏幕外的窗口：摆在主屏左下角、排在所有窗口的最底下（不抢前台、不成为 key）。
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // 真 App 里 sheet 的浅 / 深外观由 `.preferredColorScheme` 给（森林色固定浅色）；自建的窗口够不着它，照同一条规矩自己设。
        window.appearance = AppThemePalette.current.isForest ? NSAppearance(named: .aqua) : nil
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        container.addSubview(host)
        window.orderBack(nil)
        // 等 `.task` 里的取数、布局各走完几轮（假服务当场回答）。
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            window.setContentSize(size)
            container.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        // AppKit 的控件（输入框、分段、下拉、勾选框）`cacheDisplay` 画不对（黑底、发白）：按窗口号用系统的 screencapture 拍，
        // 窗口在屏幕外也拍得到；它用的是起这个脚本的终端的录屏权限。
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-l", String(window.windowNumber), "-o", "-x", file.path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw AIToolError("screencapture could not capture \(file.lastPathComponent); the terminal needs Screen Recording permission")
        }
        window.orderOut(nil)
        window.close()
        print("rendered \(file.lastPathComponent) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
    }
}
