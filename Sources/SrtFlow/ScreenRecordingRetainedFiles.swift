import Foundation
import SrtFlowCore

// 只核对本次 journal 点名且按提交阶段确属本次录制的文件；不清账、不迁移、不扫描目录。
enum ScreenRecordingRetainedFiles {
    static func inspect(_ manifest: ScreenRecordingManifest) async -> [ScreenRecordingReceipt.File] {
        var files: [ScreenRecordingReceipt.File] = []
        let main = observation(temporary: manifest.mainTemporaryPath, final: manifest.mainFinalPath)
        if main == .volumeUnavailable {
            files += unavailable(manifest, temporary: manifest.mainTemporaryPath, final: manifest.mainFinalPath, microphone: false)
        }
        if let file = candidate(manifest.mainResolution(main), temporary: manifest.mainTemporaryPath, final: manifest.mainFinalPath) {
            let info = await ScreenRecordingProbe.info(file.url)
            files.append(.init(url: file.url, usable: (info?.duration ?? 0) > 0, temporary: file.temporary))
        }
        if let temporary = manifest.micTemporaryPath, let final = manifest.micFinalPath {
            let observed = observation(temporary: temporary, final: final)
            if observed == .volumeUnavailable { files += unavailable(manifest, temporary: temporary, final: final, microphone: true) }
            if let resolution = manifest.microphoneResolution(observed),
               let file = candidate(resolution, temporary: temporary, final: final) {
                let duration = await ScreenRecordingProbe.audioDuration(file.url)
                files.append(.init(url: file.url, kind: "microphone", usable: (duration ?? 0) > 0, temporary: file.temporary))
            }
        }
        return files
    }

    private static func unavailable(
        _ manifest: ScreenRecordingManifest, temporary: String, final: String, microphone: Bool
    ) -> [ScreenRecordingReceipt.File] {
        // committing 阶段有两种可能，只报无法核对，绝不把“卷不可达”说成“没留下文件”。
        let committing = microphone
            ? manifest.stage == .committingMicrophone || manifest.stage == .microphoneOnlyCommitting
            : manifest.stage == .committingMain
        let committed = microphone
            ? manifest.stage == .allCommitted || manifest.stage == .microphoneOnlyCommitted
            : [.mainCommitted, .committingMicrophone, .allCommitted].contains(manifest.stage)
        let paths = committing ? [temporary, final] : [committed ? final : temporary]
        return paths.map {
            .init(url: URL(fileURLWithPath: $0), kind: microphone ? "microphone" : "video", usable: false,
                  temporary: $0 == temporary, unavailable: true)
        }
    }

    static func candidate(
        _ resolution: ScreenRecordingManifest.FileResolution, temporary: String, final: String
    ) -> (url: URL, temporary: Bool)? {
        switch resolution {
        case .committed: return (URL(fileURLWithPath: final), false)
        case .notCommitted(tempExists: true): return (URL(fileURLWithPath: temporary), true)
        case .notCommitted, .committedButMissing, .lost, .volumeUnavailable: return nil
        }
    }

    private static func observation(temporary: String, final: String) -> ScreenRecordingManifest.DirectoryObservation {
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: (final as NSString).deletingLastPathComponent, isDirectory: &directory), directory.boolValue else {
            return .volumeUnavailable
        }
        return .reachable(tempExists: manager.fileExists(atPath: temporary), finalExists: manager.fileExists(atPath: final))
    }
}
