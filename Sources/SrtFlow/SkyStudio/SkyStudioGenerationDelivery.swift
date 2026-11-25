import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - A finished generation's delivery: the paid result into the user's folder, made usable here
//
// What it covers (moved out of SkyStudioGenerationRun on 2026-11-24, when Download again began to run it again): the result downloaded
// into the generation folder (SkyStudioAPI.download: resumed, retried, an expired address renewed from the original job), an image's
// extension fixed by its bytes, an editing copy of a WebM, the optional SRT, the official receipt told, generated music measured.
// A download that gives up, or is stopped, throws SkyStudioDownloadFailure before anything is saved, and so does an output folder that
// cannot be made (`notSaved`: a file where it should be once ended the job and lost the way back, CXD3 on PR #554): the run then holds
// the result for Download again. An SRT that did not come down leaves the video saved and is reported as missing, so the job's own key can fetch only
// it.
// What it does not cover: the job, its billing and ending, holding and Download again (SkyStudioGenerationRun).

@MainActor
struct SkyStudioGenerationDelivery {
    struct Delivered {
        /// The file to edit (an H.264 copy of a WebM, otherwise the original).
        var file: URL
        var original: URL
        var caption: URL?
        var captionIssue: CaptionIssue?
        var localImage: SkyStudioImageResult.Format?
        var music: JSONValue?
    }

    /// Why the optional SRT is not there (the video is saved either way).
    enum CaptionIssue {
        /// Its download gave up: the job's own idempotency_key fetches only it, from this address.
        case missing(URL)
        /// Larger than the catalog's `max_caption_bytes`: not kept.
        case tooLarge
    }

    let generation: SkyStudioGeneration
    let model: SkyStudioModel
    let folder: URL
    let stem: String
    let official: SkyStudioOfficialOperation?
    let project: VideoEditProject?
    let advance: (CloudJobPhase) -> Void
    /// The original job's current result, for a fresh address when one expired (nil: no renewal).
    let current: (@Sendable () async throws -> SkyStudioJobResult?)?

    /// 同时下载的几个任务别挑到同一个文件名（挑名字和写文件之间隔着一次下载）。
    private static var claimedPaths: Set<String> = []

    /// `saved`: the original's place as soon as it is there (get_job reports it even when a later step fails).
    func deliver(_ result: SkyStudioJobResult, api: SkyStudioAPI, saved: (URL) -> Void) async throws -> Delivered {
        let pathExtension = SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: generation.kind)
        var destination = claim(pathExtension)
        var claimed = [destination.path]
        defer { for path in claimed { Self.claimedPaths.remove(path) } }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw SkyStudioDownloadFailure.notSaved(error) }   // nothing came down yet: held for Download again
        advance(.downloading(fraction: nil))
        let current = current
        let advance = advance
        // Gave up or stopped: SkyStudioDownloadFailure (a stop with the GETs it sent), and nothing was saved.
        try await api.download(result.url, to: destination, renew: current.map { read in { try await read()?.url } }) { fraction in
            Task { @MainActor in advance(.downloading(fraction: CloudJobPhase.quantized(fraction))) }
        }
        saved(destination)
        var localImage: SkyStudioImageResult.Format?
        if generation.kind == .image {
            let downloaded = destination
            let measured = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioImageResult.format(at: downloaded) } }
            let format = try measured.get()
            destination = try SkyStudioImageResult.finalize(downloaded, format: format) {
                let corrected = claim($0)
                claimed.append(corrected.path)
                return corrected
            }
            saved(destination)
            localImage = format
        }
        advance(.finishing)
        var editable = destination
        if await SkyStudioGeneratedVideo.needsCopy(destination) {
            let ffmpeg = try await SkyStudioGeneratedVideo.engine()
            let copy = claim("mp4")
            defer { Self.claimedPaths.remove(copy.path) }
            try await SkyStudioGeneratedVideo.makeCopy(destination, to: copy, ffmpeg: ffmpeg)
            editable = copy
        }
        var delivered = Delivered(file: editable, original: destination, localImage: localImage)
        if let url = result.captionFile { (delivered.caption, delivered.captionIssue) = await caption(url, api: api) }
        try await official?.recovery.delivered(file: editable, original: destination)
        // Music: get_job carries what listen beats=true says about it (accents, stops, end; MCP-43).
        delivered.music = generation.kind == .music ? await AIGeneratedMusicReport.measure(editable, project: project) : nil
        return delivered
    }

    /// The optional SRT: its file, or why it is not there.
    func caption(_ url: URL, api: SkyStudioAPI) async -> (file: URL?, issue: CaptionIssue?) {
        let file = claim("srt")
        defer { Self.claimedPaths.remove(file.path) }
        let current = current
        do {
            try await api.download(url, to: file, renew: current.map { read in { try await read()?.captionFile } })
        } catch {
            return (nil, .missing(url))
        }
        if let max = model.limit("max_caption_bytes"),
           let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.doubleValue > max {
            try? FileManager.default.removeItem(at: file)
            return (nil, .tooLarge)
        }
        return (file, nil)
    }

    private func claim(_ pathExtension: String) -> URL {
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: pathExtension) {
            FileManager.default.fileExists(atPath: $0.path) || Self.claimedPaths.contains($0.path)
        }
        Self.claimedPaths.insert(url.path)
        return url
    }
}
