import Foundation

// MARK: - 新建声音 / 给声音加一段录音：对话框背后的那一份
//
// 管什么（SkyCut 声音方案 5.3）：名字、录音从哪来（现在录 / 选文件）、做好的参考录音（用了哪一段、有效人声多少）、语言（本机检测
// 预选、用户可改）、授权那一勾、交。**和 AI 的 manage_voices 同一条路**：
// - 参考录音只经 VoiceReferenceSample.prepare（44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟、超过自动挑一段）；现录的那个文件
//   同样过这一遍；
// - 交只经 SkyStudioVoiceRecordingSubmission（传 `voice_reference`、`POST /voices` / `…/references`、用了哪一段、稳定的 key）。
// 授权：这是用户自己在操作，不是 AI 在问，所以是对话框里的一勾（两种权限模式都有）。**只有勾上了才造 `consent: true`**
// （带 `/models` 那一句的版本，checks/sky-studio-wiring.sh 第 11 节钉着）。开了全部权限、这个账号有有效的长期授权时默认勾上。
// 新建免费；建 MiniMax 版不在这里花，第一次用到时再说。
// 不管什么：界面（NewVoiceSheet）、录音（VoiceSampleRecorder）、为什么还灰着（NewVoiceGate）、话怎么说（VoiceLibraryText）。

@MainActor
final class NewVoiceModel: ObservableObject {
    enum Mode: Equatable {
        case create
        /// 给已有的声音加一种语言的录音。
        case addReference(SkyStudioVoice)
    }

    enum Source: String, CaseIterable, Identifiable {
        case record, file
        var id: String { rawValue }
    }

    enum SampleState: Equatable {
        case none
        case preparing
        case ready(VoiceReferenceSample.Sample)
        /// 做不成参考录音（人声不够、读不了…）：那一句。
        case failed(String)
    }

    let mode: Mode
    let recorder = VoiceSampleRecorder()
    private let store: VoiceLibraryStore

    @Published var name: String
    @Published var source: Source = .record
    @Published private(set) var sample: SampleState = .none
    /// 录音来自哪个文件的名字（现录的没有）。
    @Published private(set) var fileName: String?
    /// 录音的语言（ISO 639-1）；nil = 还没选。
    @Published private(set) var language: String?
    @Published private(set) var detectingLanguage = false
    @Published var agreed = false
    @Published private(set) var submitting = false
    /// 交的时候出的错（照界面语言）。
    @Published private(set) var problem: String?

    /// 回归换成假的：检测语言。
    var detectLanguage: @MainActor (URL, Double) async -> String? = { await VoiceSampleLanguage.detect(sample: $0, seconds: $1) }

    private let folder: URL
    private var sourceFile: URL?
    private var languageChosenByUser = false
    private var agreementTouched = false
    private var preparing: Task<Void, Never>?

    init(mode: Mode, store: VoiceLibraryStore? = nil) {
        self.mode = mode
        self.store = store ?? VoiceLibraryStore.shared
        name = ""
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut-new-voice-" + UUID().uuidString, isDirectory: true)
        recorder.onFinish = { [weak self] url in self?.use(file: url, recorded: true) }
    }

    // MARK: 读

    /// 加录音时那个声音已经有的语言（这些不列出来）。
    var takenLanguages: [String]? {
        if case .addReference(let voice) = mode { return voice.languages.map(\.language) }
        return nil
    }

    /// 语言那一行能选的：常用名单去掉已经有的；检测出名单外的也加进去。
    var languageChoices: [String] {
        var choices = VoiceSampleLanguage.choices
        if let language, !choices.contains(language) { choices.append(language) }
        return choices.filter { !(takenLanguages ?? []).contains($0) || $0 == language }
    }

    var blocker: NewVoiceGate.Blocker? {
        var hasSample = false
        if case .ready = sample { hasSample = true }
        return NewVoiceGate.blocker(
            available: store.canEdit && store.consentStatement != nil, name: name, voiceCount: store.voices.count, addingTo: takenLanguages,
            hasSample: hasSample, language: language, agreed: agreed, busy: submitting)
    }

    var consentStatement: SkyStudioVoiceConsentStatement? { store.consentStatement }

    var recordingFolder: URL { folder }

    // MARK: 改

    func choose(language code: String?) {
        languageChosenByUser = true
        language = code
    }

    func setAgreed(_ value: Bool) {
        agreementTouched = true
        agreed = value
    }

    /// 用这个文件做参考录音（选的文件，或刚录下来的那个）。
    func use(file: URL, recorded: Bool = false) {
        preparing?.cancel()
        VoiceAudition.shared.stop()
        sourceFile = file
        fileName = recorded ? nil : file.lastPathComponent
        problem = nil
        sample = .preparing
        preparing = Task { [weak self] in await self?.prepare(file) }
    }

    /// 开了全部权限、这个账号有有效的长期授权：那一勾默认勾上（用户动过就不替他改）。
    func presetAgreementFromStandingGrant(access: AIAccessStore? = nil) async {
        guard (access ?? AIAccessStore.shared).mode == .full, !agreementTouched, case .success(let key) = await store.currentKey(),
              await SkyStudioVoiceStanding.shared.hasActiveGrant(key: key, api: store.api), !agreementTouched else { return }
        agreed = true
    }

    /// 交：传参考录音、建 / 加。成了回那个声音。
    func submit() async -> SkyStudioVoice? {
        guard blocker == nil, case .ready(let sample) = sample, let language, let sourceFile, let statement = store.consentStatement else { return nil }
        // 没勾那一句就不造授权、什么都不传。
        guard agreed else { return nil }
        submitting = true
        defer { submitting = false }
        problem = nil
        let key: String
        switch await store.currentKey() {
        case .success(let found): key = found
        case .failure(let issue):
            problem = VoiceLibraryText.keyProblem(issue)
            return nil
        }
        do {
            let target: SkyStudioVoiceRecordingSubmission.Target
            switch mode {
            case .create: target = .create(name: name)
            case .addReference(let voice): target = .addReference(voice: voice.id)
            }
            let submission = try SkyStudioVoiceRecordingSubmission(file: sourceFile, sample: sample, language: language, target: target, statement: statement)
            let consent = SkyStudioVoiceConsent.thisRecording(statementVersion: statement.version)
            let voice = try await submission.send(consent: consent, key: key, api: store.api)
            store.adopt(voice)
            return voice
        } catch {
            problem = VoiceLibraryText.message(error)
            return nil
        }
    }

    /// 对话框关了：停录音、停试听、删掉临时文件。
    func close() {
        preparing?.cancel()
        recorder.discard()
        VoiceAudition.shared.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: 内部

    private func prepare(_ file: URL) async {
        do {
            let made = try await VoiceReferenceSample.prepare(from: file, folder: folder.appendingPathComponent("sample-" + UUID().uuidString.prefix(8)))
            guard !Task.isCancelled, sourceFile == file else { return }
            sample = .ready(made)
            await detect(made)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, sourceFile == file else { return }
            sample = .failed(VoiceLibraryText.message(error))
        }
    }

    private func detect(_ made: VoiceReferenceSample.Sample) async {
        guard !languageChosenByUser else { return }
        detectingLanguage = true
        let found = await detectLanguage(made.url, made.seconds)
        detectingLanguage = false
        guard !Task.isCancelled, !languageChosenByUser, case .ready(let current) = sample, current == made else { return }
        // 加录音时检测出这个声音已经有的语言：不替用户选（那一行空着，界面说要选一种还没有的）。
        if let found, takenLanguages?.contains(found) != true { language = found }
    }
}
