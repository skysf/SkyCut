import Foundation

// MARK: - 一次配旁白的输入快照
// 管什么：调用刚到时核对全部参数、决定声音和落点；云端任务等几分钟时不再读后来变掉的文件夹 / 选项。
// 不管什么：生成、报价、入轨。声音分档仍由 AIVoiceChoice 负责。

struct VoiceoverLine {
    var text: String
    var start: Double?
}

struct AIVoiceoverInput {
    struct Clone {
        let url: URL
        let start: Double
        let seconds: Double
    }

    let lines: [VoiceoverLine]
    let speed: Double
    let language: String
    let requestedVoice: String?
    var choice: AIVoiceChoice
    let clone: Clone?
    let target: TrackDropTarget
    let subtitles: Bool
    let maxLines: Int?
    let generation: Int
    let folder: URL

    @MainActor
    static func read(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIVoiceoverInput {
        guard let values = try args.array("lines"), !values.isEmpty, values.count <= 50 else {
            throw AIToolError("lines is required: give 1–50 voiceover lines.")
        }
        let lines = try values.enumerated().map { index, value in
            let entry = AIToolArguments(value)
            let text = try entry.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 1_000 else { throw AIToolError("lines[\(index)]: give 1–1000 characters.") }
            return VoiceoverLine(text: text, start: try entry.double("start").map { max(0, $0) })
        }
        let language = AITextLanguage.dominant(in: lines.map(\.text)).map(AIVoiceChoice.baseLanguage) ?? "en"
        let requested = try args.string("voice")
        let clone = try cloneSource(args)
        let choice: AIVoiceChoice
        if let clone {
            guard SkyStudioAccount.shared.hasKey else { throw AIToolError(SkyStudioJobKey.Problem.noKey.message) }
            choice = AIVoiceChoice(engine: .skyStudio(voice: "cloned voice"), note: "The voice is cloned from \(clone.url.lastPathComponent).")
        } else {
            let kokoro = KokoroVoicePack.shared.isInstalled ? KokoroVoiceSpeech.voiceNames(in: KokoroVoicePack.directory) : nil
            choice = try AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: kokoro,
                                              installed: AISpeechSynthesis.installedVoices(), skyStudioAvailable: SkyStudioAccount.shared.hasKey)
        }
        let target = try args.string("track").map { try AITrackName.target($0, in: project.state) } ?? .newAudioBottom
        switch target {
        case .audio, .newAudioBottom: break
        default: throw AIToolError("A voiceover goes on an audio track (A1, A2… or new_audio).")
        }
        let subtitles = try args.bool("subtitles") ?? false
        let maxLines = try AISubtitleLines.parse(args)
        if maxLines != nil, !subtitles { throw AIToolError("\(AISubtitleLines.key) only applies with subtitles=true.") }
        return AIVoiceoverInput(
            lines: lines, speed: min(max(try args.double("speed") ?? 1, 0.5), 2), language: language, requestedVoice: requested,
            choice: choice, clone: clone, target: target, subtitles: subtitles, maxLines: maxLines, generation: project.documentGeneration,
            folder: AIWorkspace.shared.outputFolder(.voiceovers, project: project)
        )
    }

    @MainActor
    static func cloneSource(_ args: AIToolArguments) throws -> Clone? {
        guard let path = try args.string("clone_from"), !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no file at \(path).") }
        return Clone(url: url, start: max(0, try args.double("clone_start") ?? 0), seconds: min(max(try args.double("clone_seconds") ?? 10, 5), 30))
    }

    @MainActor
    func localFallback(_ note: String) throws -> AIVoiceoverInput {
        guard clone == nil else { throw AIToolError(note) }
        var copy = self
        let kokoro = KokoroVoicePack.shared.isInstalled ? KokoroVoiceSpeech.voiceNames(in: KokoroVoicePack.directory) : nil
        // 点名云端预制音色但额度不够时也按既定规则退档；本机音色 / 角色照旧尊重点名。
        let local = requestedVoice.flatMap { SkyStudioVoices.named($0) != nil ? nil : $0 }
        copy.choice = try AIVoiceChoice.choose(local, textLanguage: language, kokoroVoices: kokoro,
                                              installed: AISpeechSynthesis.installedVoices(), skyStudioAvailable: false)
        copy.choice.note = [copy.choice.note, note].compactMap { $0 }.joined(separator: " ")
        return copy
    }
}
