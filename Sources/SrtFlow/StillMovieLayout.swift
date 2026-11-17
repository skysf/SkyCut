import Foundation

// MARK: - The layout of an ffmpeg-written transparent still: where its samples are, and the copy that stores one frame
//
// What it does: for `StillCacheSweep`. Checks that a movie is exactly what ffmpeg writes for a transparent still (top level
// ftyp, then wide / free, then mdat, then moov last; one video track; a sample table of stsd / stts / stsc / stsz / stco and
// nothing else, version 0 throughout), reads where every sample's bytes are (one size for all of them, any chunking), and builds
// the copy that stores one frame for all the samples: everything before mdat as it was, mdat holding that frame, the moov with
// stsd / stts and every other box byte for byte as they were, stsc one sample per chunk, stsz one constant size, stco every
// sample at the frame — the layout `StillFrameSharing.shareSingleFrame` gives a new still. Anything else throws
// `StillCacheSweep.Refused`.
// What it does not do: pick the files, compare the frames, or touch the disk (StillCacheSweep). Pure Foundation.

struct StillMovieLayout {
    typealias Box = StillFrameSharing.Box
    typealias Refused = StillCacheSweep.Refused

    /// Where every sample's bytes start (file offsets), their one size, and the sample description they use.
    struct Samples {
        var offsets: [Int]
        var size: Int
        var descriptionIndex: UInt32
    }

    let file: Data
    private let mdat: Box
    private let moov: Box
    private let table: [String: Box]

    /// The sample description and the timing (stsd + stts) as stored: a rewrite must leave them byte for byte as they were.
    var timing: Data { slice(table["stsd"]!) + slice(table["stts"]!) }

    init(file: Data) throws {
        self.file = file
        let top = try StillFrameSharing.boxes(in: file, from: 0, to: file.count)
        guard top.count >= 3, top.first?.type == "ftyp", top[top.count - 2].type == "mdat", top[top.count - 1].type == "moov",
              top.dropLast(2).allSatisfy({ ["ftyp", "wide", "free"].contains($0.type) })
        else { throw Refused("top-level boxes \(top.map(\.type))") }
        mdat = top[top.count - 2]
        moov = top[top.count - 1]
        let traks = try Self.children(of: moov, in: file).filter { $0.type == "trak" }
        guard traks.count == 1 else { throw Refused("\(traks.count) tracks") }
        let mdia = try Self.only("mdia", in: traks[0], file)
        let handler = try Self.only("hdlr", in: mdia, file)
        guard handler.payload.count >= 12, file.word(at: handler.payloadStart + 8) == 0x7669_6465 else {  // "vide"
            throw Refused("not a video track")
        }
        let stbl = try Self.only("stbl", in: try Self.only("minf", in: mdia, file), file)
        let boxes = try Self.children(of: stbl, in: file)
        let types = boxes.map(\.type)
        guard boxes.count == 5, Set(types) == ["stsd", "stts", "stsc", "stsz", "stco"] else {
            throw Refused("sample table holds \(types)")
        }
        table = Dictionary(uniqueKeysWithValues: boxes.map { ($0.type, $0) })
    }

    /// Where the `count` samples are. Refuses another sample count, differing sizes, or a sample outside mdat.
    func samples(count: Int) throws -> Samples {
        let stts = try words(table["stts"]!), stsc = try words(table["stsc"]!)
        let stsz = try words(table["stsz"]!), stco = try words(table["stco"]!)
        guard [stts, stsc, stsz, stco].allSatisfy({ $0.first == 0 }) else { throw Refused("a sample table version/flags") }
        // stts: entries, then (sample count, delta) pairs.
        guard stts.count == 2 + 2 * Int(stts[1]) else { throw Refused("stts length") }
        let timed = stride(from: 2, to: stts.count, by: 2).reduce(0) { $0 + Int(stts[$1]) }
        // stsz: constant size (0 = sizes follow), sample count, [sizes].
        guard stsz.count >= 3, Int(stsz[2]) == count, timed == count else { throw Refused("\(timed) samples, not \(count)") }
        let sizes = stsz[1] != 0 ? [stsz[1]] : Array(stsz.dropFirst(3))
        guard stsz[1] != 0 || sizes.count == count, let size = sizes.first, size > 0, sizes.allSatisfy({ $0 == size })
        else { throw Refused("samples of different sizes") }
        // stsc: entries, then (first chunk, samples per chunk, sample description) triples, first chunks rising from 1.
        guard stsc.count == 2 + 3 * Int(stsc[1]), stsc[1] >= 1, stsc[2] == 1 else { throw Refused("stsc layout") }
        let runs = stride(from: 2, to: stsc.count, by: 3).map { (first: stsc[$0], perChunk: stsc[$0 + 1], description: stsc[$0 + 2]) }
        guard zip(runs, runs.dropFirst()).allSatisfy({ $0.first < $1.first }), runs.allSatisfy({ $0.perChunk > 0 }),
              Set(runs.map(\.description)).count == 1 else { throw Refused("stsc runs") }
        // stco: entries, then chunk offsets. Samples in a chunk are back to back.
        guard stco.count == 2 + Int(stco[1]) else { throw Refused("stco length") }
        var offsets: [Int] = []
        for (index, chunkOffset) in stco.dropFirst(2).enumerated() {
            let run = runs.last { $0.first <= UInt32(index + 1) }!
            for sample in 0..<Int(run.perChunk) {
                guard offsets.count < count else { throw Refused("the chunks hold more than \(count) samples") }
                offsets.append(Int(chunkOffset) + sample * Int(size))
            }
        }
        guard offsets.count == count, offsets.allSatisfy({ $0 >= mdat.payloadStart && $0 + Int(size) <= mdat.end }) else {
            throw Refused("the chunks do not hold the \(count) samples inside mdat")
        }
        return Samples(offsets: offsets, size: Int(size), descriptionIndex: runs[0].description)
    }

    /// The same movie storing `frame` once for all the samples (see the header).
    func oneFrameCopy(frame: Data, samples: Samples) throws -> Data {
        var output = Data(file[file.startIndex..<(file.startIndex + mdat.start)])
        let offset = output.count + 8
        output.append(Self.box("mdat", frame))
        output.append(try rebuilt(moov, frameOffset: offset, samples: samples))
        return output
    }

    private func rebuilt(_ box: Box, frameOffset: Int, samples: Samples) throws -> Data {
        let count = UInt32(samples.offsets.count)
        switch box.type {
        case "moov", "trak", "mdia", "minf", "stbl":
            var body = Data()
            for child in try Self.children(of: box, in: file) {
                body.append(try rebuilt(child, frameOffset: frameOffset, samples: samples))
            }
            return Self.box(box.type, body)
        case "stsc": return Self.box("stsc", Self.words([0, 1, 1, 1, samples.descriptionIndex]))
        case "stsz": return Self.box("stsz", Self.words([0, UInt32(samples.size), count]))
        case "stco": return Self.box("stco", Self.words([0, count] + Array(repeating: UInt32(frameOffset), count: Int(count))))
        default: return slice(box)
        }
    }

    // MARK: Reading and writing boxes

    private func slice(_ box: Box) -> Data { Data(file[(file.startIndex + box.start)..<(file.startIndex + box.end)]) }

    /// A sample-table box's payload as 32-bit words.
    private func words(_ box: Box) throws -> [UInt32] {
        guard box.payload.count % 4 == 0 else { throw Refused("\(box.type) is not whole words") }
        return stride(from: box.payloadStart, to: box.end, by: 4).map { file.word(at: $0) }
    }

    private static func children(of box: Box, in file: Data) throws -> [Box] {
        try StillFrameSharing.boxes(in: file, from: box.payloadStart, to: box.end)
    }

    private static func only(_ type: String, in box: Box, _ file: Data) throws -> Box {
        let found = try children(of: box, in: file).filter { $0.type == type }
        guard found.count == 1 else { throw Refused("\(found.count) \(type) boxes in \(box.type)") }
        return found[0]
    }

    private static func words(_ values: [UInt32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        var box = words([UInt32(8 + body.count)])
        box.append(Data(type.utf8))
        box.append(body)
        return box
    }
}

private extension Data {
    /// The big-endian 32-bit word at `offset` (from the start of the data).
    func word(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
