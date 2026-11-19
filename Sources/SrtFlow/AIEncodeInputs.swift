import Foundation
import SrtFlowCore

// MARK: - The files compress_videos / burn_subtitles / convert_subtitles name: found, read and written off the main thread
//
// What it does: the input side of the three AI encode tools, as AIEncodeFolder does their output folder. What the AI named is
// read on the main thread without touching a drive (the paths, and the folders a relative one is tried against,
// AIPathResolution). Which file each path is, whether it is there, whether a video is a video (its content type, then its
// name), the subtitle files burn_subtitles reads, and convert_subtitles' reads and writes all run through
// ExportDestinationProbe: off the main thread, with export_video's 15 s deadline, at most three checks left waiting on one
// drive. A drive that does not answer is refused with the export panel's sentence before anything is queued; a conversion
// the deadline cuts off may still write its files when the drive answers, and the refusal says so.
// What it doesn't: the output folder (AIEncodeFolder), the queue and its names (EncodeQueue), asking before reading a file
// outside the opened folder (AIWorkspace.confirmReading: on the main thread, after the look and before any read), the
// sentences for a missing file or a file of the wrong kind (AIEncodeTools, as before).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-ai-encode-inputs-on-main-thread.md): the tools asked `fileExists` and the content
// type of every file the AI named, read burn_subtitles' subtitle files and did convert_subtitles' reads and writes on the main
// thread, the class of the export panel's freeze on a sleeping or stuck drive
// (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md).
@MainActor
enum AIEncodeInputs {
    /// One named file as found off the main thread.
    struct Found: Sendable {
        var url: URL
        var exists: Bool
        /// Asked only of the files that must be videos (`MediaFileTypes.isVideo`); false for the others.
        var isVideo: Bool
    }

    /// Why a file could not be read or written (the system's reason).
    struct Failure: Error, Sendable {
        var message: String
    }

    /// One convert_subtitles file: where it is read and the new file it becomes.
    struct Conversion: Sendable {
        var input: URL
        var output: URL
    }

    /// Resolves and looks at every path, in order; `videos` are the indices of the paths that must be videos.
    static func find(
        _ paths: [String], videos: Set<Int> = [], refusing ending: String,
        probe: ExportDestinationProbe, deadline: TimeInterval
    ) async throws -> [Found] {
        let (preferred, fallback) = AIWorkspace.shared.resolutionFolders()
        let near = AIFormat.url(fromPath: paths.first ?? ".", relativeTo: preferred).deletingLastPathComponent()
        let found: [Found]? = await probe.run(on: near, deadline: deadline, timedOut: nil) { fileSystem in
            paths.enumerated().map { index, path in
                let url = AIPathResolution.resolve(path, preferred: preferred, fallback: fallback) { fileSystem.kind($0) != .missing }
                let exists = fileSystem.kind(url) != .missing
                return Found(url: url, exists: exists, isVideo: exists && videos.contains(index) && MediaFileTypes.isVideo(url))
            }
        }
        guard let found else { throw notResponding(near, ending) }
        return found
    }

    /// burn_subtitles' subtitle files, each read and parsed off the main thread, in order (after the person allowed reading).
    static func subtitles(
        _ urls: [URL], refusing ending: String, probe: ExportDestinationProbe, deadline: TimeInterval
    ) async throws -> [Result<SubtitleDocumentModel, Failure>] {
        let near = urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        let read: [Result<SubtitleDocumentModel, Failure>]? = await probe.run(on: near, deadline: deadline, timedOut: nil) { fileSystem in
            urls.map { url in
                Result {
                    try SubtitleLoader.document(from: try fileSystem.read(url), named: url.lastPathComponent)
                }.mapError { Failure(message: $0.localizedDescription) }
            }
        }
        guard let read else { throw notResponding(near, ending) }
        return read
    }

    /// convert_subtitles: each file read, converted (`SubtitleConverter`, text only through `TextDecoding`) and written as a
    /// new file that never replaces one (`.withoutOverwriting`), off the main thread, in order. nil = converted.
    static func convert(
        _ conversions: [Conversion], to target: SubtitleFormat, folder: URL,
        probe: ExportDestinationProbe, deadline: TimeInterval
    ) async throws -> [Failure?] {
        let done: [Failure?]? = await probe.run(on: folder, deadline: deadline, timedOut: nil) { fileSystem in
            conversions.map { conversion in
                do {
                    let data = try fileSystem.read(conversion.input)
                    let text = try SubtitleConverter.convertedContents(of: data, named: conversion.input.lastPathComponent, to: target)
                    try fileSystem.writeNew(Data(text.utf8), conversion.output)
                    return nil
                } catch {
                    return Failure(message: error.localizedDescription)
                }
            }
        }
        guard let done else {
            throw notResponding(folder, "Files it has not written yet may still appear when the drive answers; "
                + "look in \(AIWorkspace.shared.display(folder)) before converting them again.")
        }
        return done
    }

    /// The export panel's sentence for a drive that did not answer within the deadline, and what that meant for the call.
    private static func notResponding(_ folder: URL, _ ending: String) -> AIToolError {
        let sentence = ExportDestinationText.message(.noResponse, folder: folder, L10n: { $0 })
        return AIToolError("\(sentence) \(ending)")
    }
}
