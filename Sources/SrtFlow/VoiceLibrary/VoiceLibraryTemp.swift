import Foundation

// MARK: - 声音库用的临时文件夹：名字只在这里起，上次崩溃留下的在启动时清
//
// 管什么：新建声音对话框（现录的文件、做好的参考录音）、AI 的 manage_voices（做好的参考录音）、检测录音语言（抽出来的探针）各用一个
// 临时文件夹，正常收尾时各自删掉；崩溃 / 强退留下的会把用户的录音留在临时目录里（审查 #367 第 7 条），所以启动时清一遍。
// 只清**一天以前**建的：临时目录是这台 Mac 上几个 SkyCut（正式版、测试版）共用的，另一个 SkyCut 正开着对话框时不能把它手里的删掉。
// 转写抽出来的音频窗口（`SrtFlow-ASR-*`）是另一摊，每次转写开头清（AudioWindowReader.sweepTempResidue）——那一处不能加这几个前缀：
// 生成字幕开跑时新建声音的对话框可能正开着。
// 不管什么：参考录音怎么做（VoiceReferenceSample）、录音（VoiceSampleRecorder）。

enum VoiceLibraryTemp {
    enum Kind: String, CaseIterable {
        /// 新建声音 / 加录音的对话框：现录的文件、做好的参考录音。
        case dialog = "SkyCut-new-voice-"
        /// AI 的 manage_voices create / add_reference：做好的参考录音。
        case reference = "SkyCut-voice-reference-"
        /// 检测录音的语言：抽出来的 16 kHz 探针。
        case language = "SkyCut-voice-language-"
    }

    /// 留多久才算残留（秒）。
    static let residueAge: TimeInterval = 24 * 3600

    /// 一个新的临时文件夹的地址（调用方自己建、用完自己删）。
    static func folder(_ kind: Kind, in root: URL = FileManager.default.temporaryDirectory) -> URL {
        root.appendingPathComponent(kind.rawValue + UUID().uuidString, isDirectory: true)
    }

    /// 删掉一天以前留下的那几种文件夹，回删了几个。阻塞的文件操作：启动时放在后台队列上跑。
    @discardableResult
    static func sweepResidue(in root: URL = FileManager.default.temporaryDirectory, now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return 0 }
        var removed = 0
        for item in items where Kind.allCases.contains(where: { item.lastPathComponent.hasPrefix($0.rawValue) }) {
            guard let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  now.timeIntervalSince(created) > residueAge else { continue }
            if (try? manager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}
