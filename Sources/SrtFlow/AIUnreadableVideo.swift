import AVFoundation
import Foundation

// MARK: - 读不出画面的视频：说为什么、怎么办（给 AI 的一句话）
//
// 管什么：look 从一个视频文件里一帧都取不出来时，查一下为什么，换成 AI 能照做的话。最常见的是 HEVC 存成「hev1」
// （ffmpeg 封 HEVC 不点名时的默认写法）：macOS 的视频框架只开「hvc1」，`isDecodable` 为假，取帧报 Cannot Open。
// 2026-10-06 盲测：upscale 实测那天留下的几个 topaz 文件就是这样，look 只回一句「could not read pictures」，
// AI 不知道是文件坏了、格式不认还是自己用错了（docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 3 条）。
// 不管什么：取帧本身（AIFrameSampler）；把文件转成能读的（compress_videos，用的是自带的 ffmpeg，hev1 照读）。

enum AIUnreadableVideo {
    /// 查到的事实：文件在不在、视频轨的编码（四个字符，如 hev1 / avc1）、这台 Mac 解不解得开。
    struct Facts: Equatable {
        var exists: Bool
        var codec: String?
        var decodable: Bool?
    }

    /// 读不出画面时调：查一遍，给一句话。
    static func reason(for url: URL) async -> String {
        message(name: url.lastPathComponent, facts: await facts(for: url))
    }

    /// 文件本身有说得出的毛病（不在了、这台 Mac 解不开）才有这句话；别的失败（比如分镜头扫描没跑完）是 nil，调用方照旧说。
    static func problem(for url: URL) async -> String? {
        let facts = await facts(for: url)
        guard !facts.exists || facts.codec == "hev1" || facts.decodable == false else { return nil }
        return message(name: url.lastPathComponent, facts: facts)
    }

    static func facts(for url: URL) async -> Facts {
        guard FileManager.default.fileExists(atPath: url.path) else { return Facts(exists: false) }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return Facts(exists: true) }
        let codec = (try? await track.load(.formatDescriptions))?.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        return Facts(exists: true, codec: codec, decodable: try? await track.load(.isDecodable))
    }

    /// 纯值：照查到的事实说。
    static func message(name: String, facts: Facts) -> String {
        guard facts.exists else { return "\(name) is not there any more (moved or deleted?)." }
        let fix = "compress_videos makes an H.264 copy SrtFlow can read; use that copy instead (add_clips, look)."
        if facts.codec == "hev1" {
            return "SrtFlow could not read pictures from \(name): it is HEVC stored as 'hev1', which macOS's video framework "
                + "does not open (it opens HEVC stored as 'hvc1'). " + fix
        }
        if facts.decodable == false {
            return "SrtFlow could not read pictures from \(name): this Mac cannot decode its video"
                + (facts.codec.map { " ('\($0)')" } ?? "") + ". " + fix
        }
        return "SrtFlow could not read pictures from \(name): macOS opened it but gave no picture (the file may be damaged "
            + "or still being written)."
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }
}
