import Darwin
import Foundation
import os

// MARK: - At launch: rewrite the old every-frame transparent stills in the still cache into the one-frame layout
//
// What it does: until 2026-11-17 (#441) a transparent still was a ProRes 4444 that stored its one picture 120 times — 107–441 MB
// per image in ~/Library/Caches/SrtFlow/StillClips/ (a 96-frame PNG sequence about 10 GB). New ones store one frame that the 120
// samples share (`StillFrameSharing`), but the old files kept their space until macOS cleared the cache. At every launch this
// rewrites each old file in place into that layout: same name, same sample description and timing, the one stored frame. It
// decodes exactly as before (all 120 stored frames are byte for byte that frame — checked, not assumed), so nothing using it
// notices: an open project, its undo history, an export reading it right now (the old file stays readable to whoever has it
// open). Nothing is deleted and nothing has to be converted again; a rewritten file is the new layout and is skipped next time.
// It only touches files that are provably the old format: regular files directly in that folder (no subfolders, no links),
// named like a transparent still the factory made (`<32 hex>-alpha[-native]-v1.mov`), laid out as ffmpeg writes them (ftyp /
// wide, mdat, moov last; one video track; stsd / stts / stsc / stsz / stco), 120 samples stored separately, all identical.
// Anything else is left exactly as it was. Logs what it freed (subsystem com.srtflow.SrtFlow, category still-cache).
// What it does not do: look anywhere else, touch mattes, opaque stills, partial files or user media, convert anything.
// Long-term rule: docs/architecture/freeze-frame.md section 4a3.

enum StillCacheSweep {
    struct Report: Equatable {
        /// File names rewritten into the one-frame layout.
        var compacted: [String] = []
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0
        /// Files named like a transparent still that were left alone, with the reason (files already one frame are not listed).
        var skipped: [String: String] = [:]
        var freed: Int64 { bytesBefore - bytesAfter }
    }

    struct Refused: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "still-cache")

    /// At launch, once in the background: on the proxy queue like the optimized-media expiry (blocking file IO, never in the
    /// Swift concurrency pool), registered as a background read so the smoke runs' "settle" waits for it.
    static func startAtLaunch() {
        PerfCounters.backgroundReadBegan()
        MediaReadQueue.proxy.addOperation {
            let report = sweep(directory: StillImageClipFactory.cacheDirectoryURL)
            if !report.compacted.isEmpty || !report.skipped.isEmpty {
                log.notice("""
                    Old transparent stills rewritten to one frame: \(report.compacted.count, privacy: .public) files, \
                    \(report.bytesBefore, privacy: .public) → \(report.bytesAfter, privacy: .public) bytes, \
                    freed \(report.freed, privacy: .public) bytes; left alone: \(report.skipped.count, privacy: .public) \
                    \(report.skipped.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; "), privacy: .public)
                    """)
            }
            PerfCounters.backgroundReadEnded()
        }
    }

    /// Rewrites every old transparent still directly in `directory`. Production passes only the still cache folder.
    static func sweep(directory: URL, frameCount: Int = StillImageClipFactory.stillFrameCount) -> Report {
        var report = Report()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return report }
        for name in names.sorted() where isTransparentStillName(name) {
            do {
                guard let sizes = try compact(directory.appendingPathComponent(name, isDirectory: false), frameCount: frameCount)
                else { continue }
                report.compacted.append(name)
                report.bytesBefore += sizes.before
                report.bytesAfter += sizes.after
            } catch {
                report.skipped[name] = "\(error)"
            }
        }
        return report
    }

    /// The names the factory gives transparent stills (`StillAlphaNaming`): an MD5 key, then `-alpha-v1.mov` or `-alpha-native-v1.mov`.
    static func isTransparentStillName(_ name: String) -> Bool {
        let key = name.prefix(32)
        let rest = name.dropFirst(32)
        return key.count == 32 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && (rest == "-alpha-v1.mov" || rest == "-alpha-native-v1.mov")
    }

    /// Rewrites one old file in place; nil when it already is one frame. Throws `Refused` (file untouched) for anything else.
    static func compact(_ url: URL, frameCount: Int) throws -> (before: Int64, after: Int64)? {
        let identity = try FileIdentity(url)
        let file = try Data(contentsOf: url, options: .alwaysMapped)
        guard Int64(file.count) == identity.size else { throw Refused("changed while being read") }
        let movie = try StillMovieLayout(file: file)
        let samples = try movie.samples(count: frameCount)
        guard Set(samples.offsets).count > 1 else { return nil }
        let frame = file[samples.offsets[0]..<(samples.offsets[0] + samples.size)]
        // The last one first: a file whose frames differ is usually found without reading it all.
        for offset in [samples.offsets[samples.offsets.count - 1]] + samples.offsets.dropFirst()
        where file[offset..<(offset + samples.size)] != frame {
            throw Refused("its frames are not all the same picture")
        }
        let output = try movie.oneFrameCopy(frame: Data(frame), samples: samples)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("compact-\(UUID().uuidString).mov")
        do {
            try output.write(to: temporary, options: .withoutOverwriting)
            // Read back what was written: one frame, the same picture, shared by every sample, timing as before.
            let written = try Data(contentsOf: temporary)
            let check = try StillMovieLayout(file: written)
            let shared = try check.samples(count: frameCount)
            guard Set(shared.offsets).count == 1, shared.size == samples.size,
                  written[shared.offsets[0]..<(shared.offsets[0] + shared.size)] == frame,
                  check.timing == movie.timing else { throw Refused("the rewritten file did not read back the same") }
            guard try FileIdentity(url) == identity else { throw Refused("changed while being rewritten") }
            guard rename(temporary.path, url.path) == 0 else { throw Refused("rename failed (errno \(errno))") }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return (Int64(file.count), Int64(output.count))
    }

    /// A regular file (not a link), and enough to tell whether it changed.
    private struct FileIdentity: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Refused("cannot be read (errno \(errno))") }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw Refused("not a regular file") }
            device = info.st_dev
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }
}
