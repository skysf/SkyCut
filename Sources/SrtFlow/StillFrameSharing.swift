import Foundation

// MARK: - One encoded frame, repeated in the sample table: a transparent still without 120 copies of the same frame
//
// What it does: the transparent-still conversion (`StillImageClipFactory.alphaConversionArguments`) encodes **one** ProRes 4444
// frame that lasts the whole still (60 s). `shareSingleFrame` rewrites that movie's sample table so the video track has `count`
// samples of equal length — 120 × 0.5 s, exactly the layout the old 120-frame file had — and every sample points at the bytes of
// that one frame. Every reader sees the same samples at the same times as before (AVFoundation in the preview, the AI's look and
// the keyframe prerender; ffmpeg in the export: identical frame counts, timestamps and pixels, checked in
// `checks/StillClipEncode/SharedFrame.swift`), but the file holds one frame (~0.5–0.9 MB at 1080p) instead of 120 (60–107 MB).
// ProRes has no inter-frame compression, so writing the same picture 120 times really stored it 120 times (MCP-76).
// What it does not do: encode anything, or accept any layout other than the one ffmpeg writes for a single intra frame (one video
// track, `moov` after `mdat`, a sample table of exactly stsd / stts / stsc / stsz / stco holding one sample). Anything else throws
// `Unsupported` and leaves the file untouched; the factory then writes every frame (the old, big file — still correct).
// Pure Foundation: any check can compile it. Long-term rules: docs/architecture/freeze-frame.md section 4a3.

enum StillFrameSharing {
    struct Unsupported: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// Rewrites the one-sample movie at `url` in place: `count` samples of equal length (the sample's duration ÷ `count`),
    /// all pointing at the same bytes. Only the `moov` box changes; it sits after `mdat`, so the frame's offset stays valid.
    static func shareSingleFrame(in url: URL, count: Int) throws {
        guard count >= 1 else { throw Unsupported("sample count \(count)") }
        let file = try Data(contentsOf: url)
        let top = try boxes(in: file, from: 0, to: file.count)
        let movies = top.filter { $0.type == "moov" }, media = top.filter { $0.type == "mdat" }
        guard movies.count == 1, media.count == 1, let movie = movies.first, let data = media.first else {
            throw Unsupported("expected one moov and one mdat, found \(top.map(\.type))")
        }
        // A moov in front of mdat (fast start) would push the frame's bytes back when it grows.
        guard movie.start > data.start else { throw Unsupported("moov comes before mdat") }
        var rewriter = Rewriter(file: file, count: count, frameArea: data.payload)
        let rebuilt = try rewriter.rebuild(movie)
        guard rewriter.rewritten == Rewriter.sampleTable else {
            throw Unsupported("sample table incomplete: rewrote \(rewriter.rewritten.sorted())")
        }
        var output = Data(file[..<movie.start])
        output.append(rebuilt)
        output.append(file[movie.end...])
        try output.write(to: url, options: .atomic)
    }

    /// One box: where it starts, where its payload starts, where it ends (byte offsets in the file).
    struct Box {
        var type: String
        var start: Int
        var payloadStart: Int
        var end: Int
        var payload: Range<Int> { payloadStart..<end }
    }

    /// The boxes laid end to end in `[from, to)`. 64-bit sizes (`size == 1`) and "to the end" (`size == 0`) are read too.
    static func boxes(in file: Data, from: Int, to: Int) throws -> [Box] {
        var result: [Box] = []
        var position = from
        while position < to {
            guard to - position >= 8 else { throw Unsupported("truncated box header at \(position)") }
            var size = Int(file.bigEndian32(at: position))
            var header = 8
            if size == 1 {
                guard to - position >= 16 else { throw Unsupported("truncated 64-bit box header at \(position)") }
                size = Int(clamping: file.bigEndian64(at: position + 8))
                header = 16
            } else if size == 0 {
                size = to - position
            }
            guard size >= header, position + size <= to else { throw Unsupported("box size \(size) out of range at \(position)") }
            let type = String(decoding: file[(file.startIndex + position + 4)..<(file.startIndex + position + 8)], as: UTF8.self)
            result.append(Box(type: type, start: position, payloadStart: position + header, end: position + size))
            position += size
        }
        return result
    }

    /// Walks the movie box, copying every box but the four sample-table boxes, which it writes anew for `count` samples.
    private struct Rewriter {
        static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        static let sampleTable: Set<String> = ["stts", "stsc", "stsz", "stco"]
        let file: Data
        let count: Int
        /// Where the frame's bytes may lie (the mdat payload).
        let frameArea: Range<Int>
        private(set) var rewritten: Set<String> = []
        /// The frame's size, once stsz has been read (ffmpeg writes it before stco).
        private var frameSize: Int?

        init(file: Data, count: Int, frameArea: Range<Int>) {
            self.file = file
            self.count = count
            self.frameArea = frameArea
        }

        mutating func rebuild(_ box: Box) throws -> Data {
            guard Self.containers.contains(box.type) else {
                guard Self.sampleTable.contains(box.type) else { return Data(file[box.start..<box.end]) }
                return Self.wrap(box.type, try sampleTableBox(box))
            }
            let children = try StillFrameSharing.boxes(in: file, from: box.payloadStart, to: box.end)
            try requireLayout(of: box, children: children)
            var body = Data()
            for child in children { body.append(try rebuild(child)) }
            return Self.wrap(box.type, body)
        }

        /// One video track; a sample table with nothing we would have to keep in step (sync samples, composition offsets,
        /// 64-bit chunk offsets, sample groups…).
        private func requireLayout(of box: Box, children: [Box]) throws {
            switch box.type {
            case "moov":
                guard children.filter({ $0.type == "trak" }).count == 1 else { throw Unsupported("expected one track") }
            case "mdia":
                guard let handler = children.first(where: { $0.type == "hdlr" }), handler.payload.count >= 12,
                      file.fourCC(at: handler.payloadStart + 8) == "vide" else { throw Unsupported("not a video track") }
            case "stbl":
                let types = Set(children.map(\.type))
                guard children.count == 5, types == Self.sampleTable.union(["stsd"]) else {
                    throw Unsupported("sample table holds \(children.map(\.type))")
                }
            default:
                break
            }
        }

        /// The new payload of stts / stsc / stsz / stco, after checking the old one describes exactly one sample.
        private mutating func sampleTableBox(_ box: Box) throws -> Data {
            let p = box.payloadStart
            func word(_ index: Int) throws -> UInt32 {
                guard p + 4 * (index + 1) <= box.end else { throw Unsupported("\(box.type) is too short") }
                return file.bigEndian32(at: p + 4 * index)
            }
            // Word 0 of each is version + flags; everything we read is version 0.
            guard try word(0) == 0 else { throw Unsupported("\(box.type) version/flags") }
            rewritten.insert(box.type)
            switch box.type {
            case "stts":  // entries, then (sample count, sample delta)
                guard try word(1) == 1, try word(2) == 1 else { throw Unsupported("stts holds more than one sample") }
                let duration = try word(3)
                guard duration > 0, duration % UInt32(count) == 0 else { throw Unsupported("duration \(duration) ÷ \(count)") }
                return Self.words([0, 1, UInt32(count), duration / UInt32(count)])
            case "stsc":  // entries, then (first chunk, samples per chunk, sample description)
                guard try word(1) == 1, try word(2) == 1, try word(3) == 1 else { throw Unsupported("stsc is not one chunk of one sample") }
                return Self.words([0, 1, 1, 1, try word(4)])
            case "stsz":  // constant size (0 = sizes follow), sample count, [sizes]
                guard try word(2) == 1 else { throw Unsupported("stsz holds more than one sample") }
                let constant = try word(1)
                let size = constant == 0 ? try word(3) : constant
                guard size > 0 else { throw Unsupported("empty sample") }
                frameSize = Int(size)
                return Self.words([0, size, UInt32(count)])
            default:  // stco: entries, then chunk offsets
                guard try word(1) == 1 else { throw Unsupported("stco holds more than one chunk") }
                let offset = Int(try word(2))
                guard frameArea.contains(offset), offset + (frameSize ?? 1) <= frameArea.upperBound else {
                    throw Unsupported("the frame at \(offset) is not inside mdat")
                }
                return Self.words([0, UInt32(count)] + Array(repeating: UInt32(offset), count: count))
            }
        }

        private static func words(_ values: [UInt32]) -> Data {
            var data = Data(capacity: values.count * 4)
            for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
            return data
        }

        private static func wrap(_ type: String, _ body: Data) -> Data {
            var box = words([UInt32(8 + body.count)])
            box.append(Data(type.utf8))
            box.append(body)
            return box
        }
    }
}

private extension Data {
    func bigEndian32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndian64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func fourCC(at offset: Int) -> String {
        String(decoding: self[(startIndex + offset)..<(startIndex + offset + 4)], as: UTF8.self)
    }
}
