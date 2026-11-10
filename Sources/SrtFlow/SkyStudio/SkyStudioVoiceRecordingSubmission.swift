import Foundation
import SrtFlowMCPKit

// MARK: - 把一段做好的参考录音交给 Sky Studio：建声音 / 给声音加一种语言（AI 的工具和设置里的对话框共用）
//
// 管什么（SkyCut 声音方案 4.6、5.3）：做好的那段参考录音（VoiceReferenceSample）是谁——文件身份、内容哈希、用的那一段、语言、
// 建成什么名字 / 加到哪个声音、授权那句的版本（SkyStudioVoiceApproval.Recording）；交的时候传 `voice_reference`、`POST /voices` 或
// `POST /voices/{id}/references`，带调用方给的授权、`source`（用了哪一段）和从同一个身份算的 idempotency_key（同一件事重发回同一个声音）。
// 两个入口同一条路：AI 的 manage_voices（SkyStudioVoiceRecordingTool：过了确认码才造授权）和设置里的新建声音对话框
// （NewVoiceModel：用户自己勾了那一句才造授权）。**授权由调用方造、这里不造**（checks/sky-studio-wiring.sh 第 11 节钉着谁能造）。
// 不管什么：参考录音怎么做（VoiceReferenceSample）、问不问用户、错误怎么说（SkyStudioVoiceLibraryErrors / VoiceLibraryText）。

struct SkyStudioVoiceRecordingSubmission {
    /// 建一个新声音，还是给已有的声音加一种语言的录音。
    enum Target: Equatable, Sendable {
        case create(name: String)
        case addReference(voice: String)

        /// 写进令牌身份的样子：`create:<名字>` / `add_reference:<voice_…>`。
        var identity: String {
            switch self {
            case .create(let name): return "create:" + name
            case .addReference(let voice): return "add_reference:" + voice
            }
        }
    }

    let file: URL
    let sample: VoiceReferenceSample.Sample
    let language: String
    let target: Target
    let statement: SkyStudioVoiceConsentStatement
    /// 授权的令牌、idempotency_key 都从它算。
    let recording: SkyStudioVoiceApproval.Recording

    /// `file`：用户点名的那个源文件（界面上现录的就是录下来的那个文件）；`sample`：从它做好的参考录音。
    /// 名字、语言在这里核对（`SkyStudioVoiceRequestProblem`）；做好的 WAV 超过上传上限（35 MB）也在这里拒，什么都不传。
    init(file: URL, sample: VoiceReferenceSample.Sample, language: String, target: Target, statement: SkyStudioVoiceConsentStatement) throws {
        let language = try SkyStudioVoiceNaming.checkedLanguage(language)
        let checked: Target
        switch target {
        case .create(let name): checked = .create(name: try SkyStudioVoiceNaming.checked(name))
        case .addReference(let voice):
            guard SkyStudioVoice.isVoiceID(voice) else { throw SkyStudioVoiceRequestProblem(message: "voice must be a voice_… id from list_voices.") }
            checked = .addReference(voice: voice)
        }
        let data = try Data(contentsOf: sample.url)
        guard SkyStudioVoiceUpload.fits(bytes: data.count) else {
            throw AIToolError("The voice sample came out larger than Sky Studio accepts (35 MB); pick a shorter part. Nothing was sent.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        self.file = file
        self.sample = sample
        self.language = language
        self.target = checked
        self.statement = statement
        recording = SkyStudioVoiceApproval.Recording(
            path: file.standardizedFileURL.resolvingSymlinksInPath().path, bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            sampleSHA256: SkyStudioVoiceApproval.sha256(data), start: sample.sourceStart, end: sample.sourceEnd,
            language: language, target: checked.identity, statementVersion: statement.version
        )
    }

    /// 这件事的记号（确认码绑它；换文件、换一段、换语言 / 名字 / 账户都不一样）。
    func consentAction(account: String) -> String {
        SkyStudioVoiceApproval.consentAction(recording, account: account)
    }

    /// 传参考录音、建 / 加。`consent` 是调用方问到之后造的那一个。成了叫一声「声音库变了」。
    @MainActor
    func send(consent: SkyStudioVoiceConsent, key: String, api: SkyStudioAPI) async throws -> SkyStudioVoice {
        let source = SkyStudioVoiceReferenceSource(fileName: file.lastPathComponent, startSeconds: sample.sourceStart,
                                                   endSeconds: sample.sourceEnd, autoSelected: sample.autoSelected)
        let link = try await api.upload(fileURL: sample.url, contentType: VoiceReferenceSample.contentType,
                                        purpose: VoiceReferenceSample.uploadPurpose, key: key)
        let voice: SkyStudioVoice
        switch target {
        case .create(let name):
            let creation = try SkyStudioVoiceCreation(
                name: name, language: language, referenceURL: link, source: source, consent: consent,
                idempotencyKey: SkyStudioVoiceApproval.idempotencyKey(for: consentAction(account: SkyStudioCharacterAccess.stamp(key))))
            voice = try await api.createVoice(creation, key: key)
        case .addReference(let id):
            let reference = try SkyStudioVoiceReference(language: language, referenceURL: link, source: source, consent: consent)
            voice = try await api.addVoiceReference(reference, to: id, key: key)
        }
        SkyStudioVoiceLibraryChange.post()
        return voice
    }
}

/// 「声音库变了」：建了、加了录音、改了名、删了、设计好了。设置里的声音库那一节听它刷新（AI 改的也看得见）。
enum SkyStudioVoiceLibraryChange {
    static let name = Notification.Name("SrtFlow.voiceLibrary.changed")

    static func post() { NotificationCenter.default.post(name: name, object: nil) }
}

/// 删一个声音（立刻全删）：存储一时不可用（503 `voice_library_unavailable` + `reason: storage_unavailable`）时声音已经看不见了，
/// 再发一次 DELETE 接着删（Sky Studio 声音方案 3.3）；还不行原样抛出去。
enum SkyStudioVoiceDeletion {
    @MainActor
    static func run(_ id: String, key: String, api: SkyStudioAPI) async throws {
        defer { SkyStudioVoiceLibraryChange.post() }
        do {
            try await api.deleteVoice(id, key: key)
        } catch where SkyStudioVoiceLibraryErrors.isStorageRetry(error) {
            try await api.deleteVoice(id, key: key)
        }
    }
}
