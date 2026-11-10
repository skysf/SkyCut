import Foundation

// MARK: - 新建声音对话框：「新建」为什么还灰着（纯值）
//
// 管什么（SkyCut 声音方案 5.3）：按下「新建」之前还差什么，一次只说最要紧的那一样：声音满了（每个账号最多 50 个，服务器另外再卡
// `voice_limit`）、没起名字、还没有能用的录音（没录 / 没选文件 / 有效人声不到 10 秒：那句具体的话由做参考录音的那一步给）、
// 没选语言、这个声音在这种语言里已经有录音了（加录音时；服务器另外再卡 `reference_exists`）、没勾授权那一句。
// 不管什么：文字怎么写（VoiceLibraryText）、参考录音怎么做（VoiceReferenceSample）、交（SkyStudioVoiceRecordingSubmission）。

enum NewVoiceGate {
    enum Blocker: Equatable, Sendable {
        /// 声音库暂时用不了 / 还没读到 Sky Studio 的授权那一句：现在建不了。
        case unavailable
        case tooManyVoices(limit: Int)
        case name
        /// 还没有能用的录音。
        case recording
        case language
        /// 加录音：这个声音在这种语言里已经有一段了。
        case languageTaken(String)
        /// 没勾「我有权使用这个声音」。
        case consent
        /// 正在交。
        case busy
    }

    /// 每个账号最多多少个声音（Sky Studio 的 `voice_limit`；服务器说了算，这里只为了早一步灰掉按钮）。
    static let voiceLimit = 50

    /// `addingTo`：给已有的声音加录音时那个声音已有的语言；新建是 nil。
    static func blocker(available: Bool, name: String, voiceCount: Int, addingTo taken: [String]?, hasSample: Bool, language: String?,
                        agreed: Bool, busy: Bool) -> Blocker? {
        if busy { return .busy }
        if !available { return .unavailable }
        if taken == nil {
            if voiceCount >= voiceLimit { return .tooManyVoices(limit: voiceLimit) }
            if (try? SkyStudioVoiceNaming.checked(name)) == nil { return .name }
        }
        if !hasSample { return .recording }
        guard let language, (try? SkyStudioVoiceNaming.checkedLanguage(language)) != nil else { return .language }
        if let taken, taken.contains(language) { return .languageTaken(language) }
        if !agreed { return .consent }
        return nil
    }
}
