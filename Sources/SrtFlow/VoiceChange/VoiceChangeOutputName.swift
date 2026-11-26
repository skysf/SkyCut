import Foundation
import SrtFlowCore

// MARK: - 变声出来的两个文件叫什么、放哪（纯值 + 一次文件系统探测）
//
// 管什么（SkyCut 声音方案 4.8 第 5 步）：`<原名> - <声音名>.wav`（变声后的人声）、`<原名> - 背景.wav`（分离出来的背景；「背景」
// 照界面语言写），放在原素材所在的文件夹；写不进去（只读盘、相机卡、没授权）退到工程的家、再退到下载（同 upscale，
// UpscaleOutputName.folder）；撞名加编号（ExclusivePlacement，全 App 一个规矩，不覆盖）。扩展名照服务器报的类型
// （人声是 WAV；背景不是 WAV 时服务器另报 `background_content_type`），认不出来看成品地址的扩展名，再不行按 WAV。
// Each file takes its name on disk only when it is whole and never replaces anything (`places` → CloudResultPlace): two jobs for the
// same clip and voice once chose the same two paths, and cancelling one deleted the other's files on the timeline (CXD3); names claimed
// in memory then still let SkyCut and SkyCut Beta overwrite each other's file (CXD4, PR #554).
// 不管什么：文件内容（VoiceChangeJob 下载）。

enum VoiceChangeOutputName {
    /// 两个文件的名字（不带扩展名）。声音名里的 `/`、`:` 换掉（ExportFileName.stem）。
    static func stems(original: URL, voiceName: String, backgroundLabel: String) -> (voice: String, background: String) {
        let base = ExportFileName.stem(from: original.lastPathComponent, droppingExtension: original.pathExtension, fallback: "Clip")
        let voice = ExportFileName.stem(from: voiceName, droppingExtension: "", fallback: "voice")
        let background = ExportFileName.stem(from: backgroundLabel, droppingExtension: "", fallback: "background")
        return ("\(base) - \(voice)", "\(base) - \(background)")
    }

    /// `audio/wav` → `wav`，`audio/mpeg` → `mp3`，`audio/flac` → `flac`，`audio/mp4` → `m4a`；认不出来看地址，再不行 `wav`。
    static func pathExtension(contentType: String?, url: URL) -> String {
        switch contentType?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) {
        case "audio/wav"?, "audio/x-wav"?, "audio/wave"?: return "wav"
        case "audio/mpeg"?, "audio/mp3"?: return "mp3"
        case "audio/flac"?, "audio/x-flac"?: return "flac"
        case "audio/mp4"?, "audio/m4a"?, "audio/x-m4a"?, "audio/aac"?: return "m4a"
        default:
            let fromURL = url.pathExtension.lowercased()
            return ["wav", "mp3", "flac", "m4a"].contains(fromURL) ? fromURL : "wav"
        }
    }

    /// Where one change's two files go: the folder (the original's; when that cannot be written, the fallbacks), and each file's
    /// stem and extension. Each file takes its name only when it is whole, never replacing or removing anything: `stem.ext`, or the
    /// next free number of that series at that moment (CloudResultPlace, on disk, so SkyCut and SkyCut Beta never share a name
    /// either). The two never collide, not even in case only (a voice called "Background" and the background once became one file on
    /// a case-insensitive drive): the background then numbers from 2, and the placement moves on if a name still matches.
    static func places(
        original: URL, voiceName: String, backgroundLabel: String, voiceExtension: String, backgroundExtension: String, fallbacks: [URL],
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> (voice: CloudResultPlace, background: CloudResultPlace) {
        let folder = UpscaleOutputName.folder(original: original, fallbacks: fallbacks, isWritable: isWritable)
        let names = stems(original: original, voiceName: voiceName, backgroundLabel: backgroundLabel)
        var background = CloudResultPlace(folder: folder, stem: names.background, pathExtension: backgroundExtension)
        if "\(names.voice).\(voiceExtension)".caseInsensitiveCompare("\(names.background).\(backgroundExtension)") == .orderedSame {
            background.number = 2
        }
        return (CloudResultPlace(folder: folder, stem: names.voice, pathExtension: voiceExtension), background)
    }
}
