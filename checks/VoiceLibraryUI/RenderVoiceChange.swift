import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 变声面板的离屏渲染（scripts/render-voice-library.sh 的后两张，声音 PR 9）：生产的 VoiceChangePanel + 面板背后的那一份 + 假 Sky Studio
// （VoiceChangeHTTP：目录快照、`/voices`、变声的 `/quote`）。出的是：选了自己的声音、报价回来了（带「用哪种语言的录音」那一句）；
// 还没有自己的声音（顶上有「新建声音…」、什么都没选）。只是出图，不判对错；规矩由 scripts/check-voice-recovery.sh 的 VoiceChangeChecks 钉着。

@MainActor
func renderVoiceChange(_ language: String, file: (String) -> URL, work: URL) async throws {
    func voice(_ suffix: String, _ name: String, _ languages: [String], source: String = "recording") -> (String, JSONValue) {
        let id = "voice_" + String(repeating: suffix, count: 32)
        return (id, VoiceChangeHTTP.voice(id, name: name, languages: languages, source: source))
    }
    func store(_ fixture: VoiceChangeFixture) -> VoiceLibraryStore {
        let store = VoiceLibraryStore()
        store.readKey = { .success("local-voice-change-fixture") }
        store.api = fixture.api
        return store
    }
    func wait(_ what: String, until done: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if done() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AIToolError("Timed out waiting for \(what)")
    }

    // 9. 选了自己的声音（上次用过的那个）、报价回来了。
    let fixture = try VoiceChangeFixture(folder: work.appendingPathComponent("change-\(language)"))
    let sky = voice("1", "Sky", ["zh", "en"])
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.voices = Dictionary(uniqueKeysWithValues: [sky, voice("2", "María — podcast", ["es"]), voice("3", "Warm narrator", ["en"], source: "design")])
    }
    let clip = fixture.placeClip(try fixture.stereoSource("interview-take-2.wav", seconds: 42), sourceStart: 0, sourceDuration: 42, assetSeconds: 42)
    fixture.detected = "en"
    VoiceChangeActivity.shared.lastVoiceID = sky.0
    let library = store(fixture)
    guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clip, store: library) else { throw AIToolError("No panel for the clip") }
    model.services = fixture.services
    await model.open()
    try await wait("the voice change quote") { model.quote != nil }
    try await Snapshot.take(VoiceChangePanel(model: model, store: library), to: file("9-change-voice"))
    model.close()

    // 10. 还没有自己的声音：顶上「新建声音…」，设计的声音和预设照样能选。
    let empty = try VoiceChangeFixture(folder: work.appendingPathComponent("change-empty-\(language)"))
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.voices = Dictionary(uniqueKeysWithValues: [voice("3", "Warm narrator", ["en"], source: "design")]) }
    let other = empty.placeClip(try empty.stereoSource("interview-take-2.wav", seconds: 42), sourceStart: 0, sourceDuration: 42, assetSeconds: 42)
    let emptyLibrary = store(empty)
    guard let blank = VoiceChangePanelModel(project: empty.project, clipID: other, store: emptyLibrary) else { throw AIToolError("No panel for the clip") }
    blank.services = empty.services
    await blank.open()
    try await Snapshot.take(VoiceChangePanel(model: blank, store: emptyLibrary), to: file("10-change-voice-no-voice"))
    blank.close()
    UserDefaults.standard.removeObject(forKey: VoiceChangeActivity.lastVoiceKey)
}
