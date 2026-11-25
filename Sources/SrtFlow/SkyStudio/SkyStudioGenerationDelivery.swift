import Foundation
import os
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - A finished generation's delivery: the paid result into the user's folder, made usable here
//
// What it covers (moved out of SkyStudioGenerationRun on 2026-11-24, when Download again began to run it again): the result downloaded
// into the generation folder (SkyStudioAPI.download: resumed, retried, an expired address renewed from the original job; it takes its
// name without replacing or removing anything, the next free number when the name is taken), an image checked by its bytes before it
// takes a name (and named by them), an editing copy of a WebM, the optional SRT, the official receipt told, generated music measured.
// A download that gives up, is stopped, or never brings an image that decodes throws SkyStudioDownloadFailure before anything is saved,
// and so does an output folder that cannot be made (`notSaved`: a file where it should be once ended the job and lost the way back,
// CXD3 on PR #554): the run then holds the result for Download again. An SRT that did not come down leaves the video saved and is
// reported as missing, so the job's own key can fetch only it.
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

    /// `saved`: the original's place once it is there and checked (get_job reports it even when a later step fails); until then the
    /// run keeps the result held for Download again.
    func deliver(_ result: SkyStudioJobResult, api: SkyStudioAPI, saved: (URL) -> Void) async throws -> Delivered {
        let pathExtension = SkyStudioGeneration.fileExtension(contentType: result.contentType, url: result.url, kind: generation.kind)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw SkyStudioDownloadFailure.notSaved(error) }   // nothing came down yet: held for Download again
        advance(.downloading(fraction: nil))
        let current = current
        let advance = advance
        let image = generation.kind == .image ? OSAllocatedUnfairLock<SkyStudioImageResult.Format?>(initialState: nil) : nil
        // Gave up, stopped, or never an image that decodes: SkyStudioDownloadFailure (a stop with the GETs it sent), nothing was saved.
        let place = CloudResultPlace(folder: folder, stem: stem, pathExtension: pathExtension)
        let renew = current.map { read in { @Sendable in try await read()?.url } }
        let downloaded = try await api.download(result.url, into: place, renew: renew, check: image.map(SkyStudioImageResult.downloadCheck)) { fraction in
            Task { @MainActor in advance(.downloading(fraction: CloudJobPhase.quantized(fraction))) }
        }
        let destination = downloaded.url
        saved(destination)
        let localImage = image?.withLock { $0 }
        advance(.finishing)
        var editable = destination
        if await SkyStudioGeneratedVideo.needsCopy(destination) {
            let ffmpeg = try await SkyStudioGeneratedVideo.engine()
            editable = try await SkyStudioGeneratedVideo.makeCopy(destination, in: folder, stem: stem, ffmpeg: ffmpeg)
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
        let current = current
        let downloaded: CloudResultFile
        do {
            let place = CloudResultPlace(folder: folder, stem: stem, pathExtension: "srt")
            downloaded = try await api.download(url, into: place, renew: current.map { read in { @Sendable in try await read()?.captionFile } })
        } catch {
            return (nil, .missing(url))
        }
        if let max = model.limit("max_caption_bytes"),
           let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.url.path))?[.size] as? NSNumber, size.doubleValue > max {
            ExclusivePlacement.discard(downloaded.file)   // only while it is still the file this download placed
            return (nil, .tooLarge)
        }
        return (downloaded.url, nil)
    }
}
