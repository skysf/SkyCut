import CryptoKit
import Foundation
import SrtFlowMCPKit

// MARK: - What a paid request is, for counting identical ones (SkyStudioRepeatGuard)
//
// What it covers: the identity of a resolved request, the way Sky Studio's `/jobs` would receive it: the request body (kind, model,
// prompt and every param SkyCut worked out: the aspect and resolution from the canvas, the duration, the language, the voice, every
// option), a character's revision, the caller's extra parts of what is sent (an upscale's source range, a page address), and each
// local file SkyCut uploads for it by its bytes (SHA-256), in order and with its role. Left out: what changes for every job and is
// not the request (the `idempotency_key`, `max_credits`, upload addresses) and everything that never reaches Sky Studio (an output
// folder or name, where a result lands on the timeline). So two calls that send the same request are identical whatever their
// arguments were (another name, a path to a copy of the same file), and a changed canvas, language, voice, source or option is a
// different request.
// A file's bytes are read once per run while it is unchanged (its path, device, inode, size and modification time), on
// MediaReadQueue.analysis (blocking reads stay off Swift's thread pool: docs/architecture/blocking-media-reads.md). A file up to
// 256 MiB is hashed whole (every reference, voice source and photo is smaller); a larger one (an upscale's original can be many GB,
// whose full read could reach the AI client's one-minute wait on a slow disk) by its size and 48 MiB of its bytes: the first and last
// 16 MiB and 32 slices of 512 KiB spread between them. The same bytes always give the same identity; two large files of one size
// that differ only between the slices count as one request, which at worst asks the user once more.
// What it does not cover: counting (SkyStudioRepeatGuard); a confirm token's binding (SkyStudioApproval: the exact call with its
// price, folder and name).

enum SkyStudioRequestDigest {
    /// A local file a request uploads, and the part it plays (`first_frame`, `reference_image`, `source`…).
    struct File: Equatable, Sendable {
        let role: String
        let url: URL
    }

    /// Files up to this size are hashed whole; larger ones by their size and sampled slices.
    static let wholeFileLimit: UInt64 = 256 << 20

    /// The identity of `request` (its quote body: no key, price cap or upload addresses) with its files' bytes and `extra`.
    static func identity(_ request: SkyStudioJobRequest, files: [File], extra: [String: JSONValue] = [:]) async throws -> String {
        var hashed: [(role: String, sha256: String)] = []
        for file in files { hashed.append((file.role, try await content(of: file.url))) }
        return identity(request, hashed: hashed, extra: extra)
    }

    /// The same from file digests already read (pure; the checks build identities with it).
    static func identity(_ request: SkyStudioJobRequest, hashed: [(role: String, sha256: String)] = [],
                         extra: [String: JSONValue] = [:]) -> String {
        var fields: [String: JSONValue] = ["request": request.quoteBody]
        if let revision = request.character?.revision { fields["character_revision"] = .string(revision) }
        if !hashed.isEmpty {
            fields["files"] = .array(hashed.map { .object(["role": .string($0.role), "sha256": .string($0.sha256)]) })
        }
        if !extra.isEmpty { fields["extra"] = .object(extra) }
        return "request:" + hex(SHA256.hash(data: Data(JSONValue.object(fields).encodedString().utf8)))
    }

    /// SHA-256 of a file's bytes (lowercase hex), read on MediaReadQueue.analysis; an unchanged file is read once per run.
    static func content(of url: URL) async throws -> String {
        let path = url.standardizedFileURL.path
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try digest(path: path) } }.get()
    }

    private static let known = KnownDigests()

    private static func digest(path: String) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: path)
        var stamp = [path]
        for key in [FileAttributeKey.systemNumber, .systemFileNumber, .size] { stamp.append((values[key] as? NSNumber)?.stringValue ?? "") }
        stamp.append((values[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "")
        let key = stamp.joined(separator: "|")
        if let digest = known.digest(key) { return digest }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        if size <= wholeFileLimit {
            while try hashChunk(handle, upTo: 1 << 20, into: &hasher) > 0 {}
        } else {
            hasher.update(data: Data("sampled:\(size)".utf8))
            let edge: UInt64 = 16 << 20, slice: UInt64 = 512 << 10, slices: UInt64 = 32
            var offsets: [(UInt64, UInt64)] = [(0, edge)]
            for index in 1...slices { offsets.append(((size - slice) * index / (slices + 1), slice)) }
            offsets.append((size - edge, edge))
            for (offset, count) in offsets {
                try handle.seek(toOffset: offset)
                var left = count
                while left > 0 {
                    let read = try hashChunk(handle, upTo: Int(min(left, 1 << 20)), into: &hasher)
                    guard read > 0 else { break }
                    left -= UInt64(read)
                }
            }
        }
        let digest = hex(hasher.finalize())
        known.remember(digest, for: key)
        return digest
    }

    /// One chunk of at most `count` bytes into the hash; returns how many were read (0 at the end of the file). FileHandle hands each
    /// chunk back autoreleased: without a pool around each one a whole read kept every chunk until it ended, and hashing a 250 MiB
    /// original took about 270 MB for a moment (FBR1 on PR #557).
    private static func hashChunk(_ handle: FileHandle, upTo count: Int, into hasher: inout SHA256) throws -> Int {
        try autoreleasepool {
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return 0 }
            hasher.update(data: chunk)
            return chunk.count
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The digests already read this run, by file stamp (read and written from the read queue's threads).
private final class KnownDigests: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: String] = [:]

    func digest(_ key: String) -> String? { lock.withLock { digests[key] } }
    func remember(_ digest: String, for key: String) { lock.withLock { digests[key] = digest } }
}
