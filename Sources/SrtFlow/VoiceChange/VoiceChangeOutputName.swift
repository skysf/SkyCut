import Foundation
import SrtFlowCore

// MARK: - 变声出来的两个文件叫什么、放哪（纯值 + 一次文件系统探测）
//
// 管什么（SkyCut 声音方案 4.8 第 5 步）：`<原名> - <声音名>.wav`（变声后的人声）、`<原名> - 背景.wav`（分离出来的背景；「背景」
// 照界面语言写），放在原素材所在的文件夹；写不进去（只读盘、相机卡、没授权）退到工程的家、再退到下载（同 upscale，
// UpscaleOutputName.folder）；撞名加编号（ExportFileName.unoccupied，全 App 一个规矩，不覆盖）。扩展名照服务器报的类型
// （人声是 WAV；背景不是 WAV 时服务器另报 `background_content_type`），认不出来看成品地址的扩展名，再不行按 WAV。
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

    /// 不撞名的两个完整路径：都放在同一个文件夹（原素材的，写不进去照 `fallbacks` 退）。
    static func destinations(
        original: URL, voiceName: String, backgroundLabel: String, voiceExtension: String, backgroundExtension: String, fallbacks: [URL],
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> (voice: URL, background: URL) {
        let folder = UpscaleOutputName.folder(original: original, fallbacks: fallbacks, isWritable: isWritable)
        let names = stems(original: original, voiceName: voiceName, backgroundLabel: backgroundLabel)
        let voice = ExportFileName.unoccupied(in: folder, stem: names.voice, pathExtension: voiceExtension, exists: exists)
        // 声音名正好也叫「背景」时两个文件不撞：背景那个把人声的路径也当成占着的。
        let background = ExportFileName.unoccupied(in: folder, stem: names.background, pathExtension: backgroundExtension) {
            exists($0) || $0 == voice
        }
        return (voice, background)
    }
}
