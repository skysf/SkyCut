#if DEBUG
import Foundation

// Writes a normal saved project over the synthetic files made by the check script.
// The preview opens the document without probing, importing or building anything in advance.
enum PlaybackStartFixture {
    static let cut = 4.0
    static let deepGOP = 14.5
    /// A rebuilt item placed three seconds into the 4K source's second GOP.
    static let freshItem = 10.0
    /// A far click into the 4K source's third GOP (source 19 s, keyframe at 16 s).
    static let farSeek = 18.0
    /// Where the pointer hovers (in the 1080p opening) while the playhead waits in the 4K source.
    static let peek = 6.0
    static let duration = 23.0
    private static let sourceDuration = 24.0

    struct Media: Encodable {
        let primaryBytes: Int64
        let width: Int
        let height: Int
        let keyframeInterval: Double
        let videoTracks: Int
        let audioTracks: Int
    }

    static func write(in directory: URL) throws -> (URL, Media) {
        let primary = directory.appendingPathComponent("primary.mp4")
        let opening = directory.appendingPathComponent("opening.mp4")
        let overlay = directory.appendingPathComponent("overlay.mp4")
        let audio = directory.appendingPathComponent("tone.wav")
        let primaryInfo = try info(primary, width: 3840, height: 2160, gop: 8)
        let openingInfo = try info(opening, width: 1920, height: 1080, gop: 1)
        let overlayInfo = try info(overlay, width: 640, height: 360, gop: 1)
        let project = directory.appendingPathComponent("Playback start.skycut")
        var state = TimelineState()
        state.frameRate = .fps30
        state.mainClips = [
            EditClip(sourceURL: opening, sourceDuration: cut, info: openingInfo),
            EditClip(sourceURL: opening, sourceStart: 8, sourceDuration: cut, timelineStart: cut, info: openingInfo),
            EditClip(sourceURL: primary, sourceStart: 9, sourceDuration: 15, timelineStart: 8, info: primaryInfo),
        ]
        state.overlayTracks = (1...3).map { index in
            EditLane(clips: [EditClip(
                sourceURL: overlay, sourceStart: Double(index), sourceDuration: duration,
                placement: ClipPlacement(centerX: 0.23 * Double(index), centerY: 0.3, width: 0.22, height: 0.22),
                info: overlayInfo
            )])
        }
        state.audioTracks = (0..<6).map { index in
            EditLane(clips: [EditClip(
                sourceURL: audio, isAudioOnly: true, sourceStart: Double(index) * 0.1, sourceDuration: duration,
                volume: 0.25, audioAssetDuration: sourceDuration
            )])
        }
        let request = ProjectFileWriteRequest(
            kind: .saveAs, state: state, url: project, knownRecords: [:], rowHeights: TimelineRowHeights(),
            documentBookmark: nil, revision: 0, generation: 0
        )
        switch ProjectFileWriter.write(request) {
        case .saved: break
        case .failed(let reason), .occupied(let reason):
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return (project, Media(
            primaryBytes: primaryInfo.fileBytes, width: primaryInfo.width, height: primaryInfo.height,
            keyframeInterval: 8, videoTracks: 1 + state.overlayTracks.count, audioTracks: state.audioTracks.count
        ))
    }

    private static func info(_ url: URL, width: Int, height: Int, gop: Double) throws -> MediaInfo {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return MediaInfo(
            duration: sourceDuration, displaySize: CGSize(width: width, height: height), frameRate: 30,
            videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false,
            fileBytes: Int64(size), keyframeInterval: gop, alpha: .opaque
        )
    }
}
#endif
