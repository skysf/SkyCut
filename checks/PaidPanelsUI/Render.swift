import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Off-screen renders of the upscale and change-voice panels when their clip holds a paid result that did not come down
// (scripts/render-paid-panels.sh; 2026-11-26, backlog B47's UI half; SkyStudioPanelHeldDownload): the production panels with the
// line, Download again as the default button and "Make a new version (N credits)", in en / zh-Hans / es, for PR images and a look
// at the layout before a release. A fake Sky Studio answers the catalog and quotes (PanelsHTTP for the upscale panel,
// VoiceChangeHTTP for the change-voice panel); the held result is a stand-in (its Download again does nothing here). Only images, no
// verdicts: the behaviour is pinned by scripts/check-voice-recovery.sh (RepeatPanelChecks). No network, keychain or credits.

@main enum PaidPanelsRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.paidpanelsrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("The panels render requires the isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_PANELS_RENDER_OUT"]!)
        let work = URL(fileURLWithPath: environment["SRTFLOW_PANELS_RENDER_WORK"]!)
        URLProtocol.registerClass(PanelsHTTP.self)
        setenv(SkyStudioAPI.baseEnvironmentKey, "http://127.0.0.1/panels-render/api/skycut/v1", 1)
        await SkyStudioKey.cache.remember("sk-" + String(repeating: "P", count: 43))
        SkyStudioSpendStore.shared.setDailyLimit(1_000)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                try await renderUpscale(to: out.appendingPathComponent("upscale-held-\(language.rawValue).png"))
                try await renderVoiceChange(to: out.appendingPathComponent("change-voice-held-\(language.rawValue).png"),
                                            work: work.appendingPathComponent(language.rawValue))
            }
        } catch {
            print("FAIL: paid panels render: \(error)")
            exit(1)
        }
        print("PASS: rendered the upscale and change-voice panels with a held result in en, zh-Hans and es to \(out.path)")
        exit(0)
    }

    /// A 1280×720 clip of 12 s (no file is read: the panel works from the clip's probe), the fake catalog's one model and its quote.
    @MainActor
    private static func renderUpscale(to file: URL) async throws {
        let project = OpenProjects.shared.primary
        let info = MediaInfo(duration: 12, displaySize: CGSize(width: 1280, height: 720), frameRate: 24, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
        let clip = EditClip(sourceURL: URL(fileURLWithPath: "/Movies/Glacier walk.mp4"), sourceDuration: 8, timelineStart: 0, info: info)
        project.perform { $0 = TimelineState(); $0.mainClips = [clip] }
        SkyStudioCatalogCache.shared.forget()
        guard let model = UpscalePanelModel(project: project, clipID: clip.id) else { throw AIToolError("No upscale panel for the clip") }
        try await Snapshot.take(UpscalePanel(project: project, model: model, held: SkyStudioPanelHeldDownload(downloadAgain: {})), to: file)
    }

    /// The change-voice panel as scripts/render-voice-library.sh draws it (my voice picked, the quote back), with a held result.
    @MainActor
    private static func renderVoiceChange(to file: URL, work: URL) async throws {
        let fixture = try VoiceChangeFixture(folder: work)
        let sky = "voice_" + String(repeating: "1", count: 32)
        VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.voices = [sky: VoiceChangeHTTP.voice(sky, name: "Sky", languages: ["zh", "en"])] }
        let clip = fixture.placeClip(try fixture.stereoSource("interview-take-2.wav", seconds: 42), sourceStart: 0, sourceDuration: 42, assetSeconds: 42)
        fixture.detected = "en"
        VoiceChangeActivity.shared.lastVoiceID = sky
        let store = VoiceLibraryStore()
        store.readKey = { .success("local-voice-change-fixture") }
        store.api = fixture.api
        guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clip, store: store) else { throw AIToolError("No panel for the clip") }
        model.services = fixture.services
        model.held = SkyStudioPanelHeldDownload(downloadAgain: {})
        await model.open()
        for _ in 0..<300 where model.quote == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Snapshot.take(VoiceChangePanel(model: model, store: store), to: file)
        model.close()
        UserDefaults.standard.removeObject(forKey: VoiceChangeActivity.lastVoiceKey)
    }
}

/// The upscale panel's fake Sky Studio: one model (as Sky Studio's /models lists it) and a quote.
final class PanelsHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.hasPrefix("/panels-render/") ?? false)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        let body: String
        if path.hasSuffix("/models") {
            body = #"""
            {"models": [{"id": "topaz-starlight", "kind": "upscale", "title": "Topaz Starlight",
              "price": {"per": "second", "credits_by_target": {"1080p": 30, "4K": 65}}, "params": {"target": ["1080p", "4K"]},
              "limits": {"max_source_seconds": 30.5, "max_source_fps": 30, "max_output_pixels": 8294400, "max_upload_bytes": 209715200}}]}
            """#
        } else if path.hasSuffix("/quote") {
            body = #"{"credits": 75, "typical_seconds": 240}"#
        } else {
            body = "{}"
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: path.hasSuffix("/models") || path.hasSuffix("/quote") ? 200 : 404,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
