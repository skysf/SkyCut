import AVFoundation
import CoreVideo
import Foundation

// MARK: - Writing the frames: ProRes 4444, premultiplied, tagged as premultiplied
//
// Owns: the movie. Frames are premultiplied BGRA (what WebKit's snapshot gives), so the file stores premultiplied alpha
// and every buffer carries `AlphaChannelMode = premultiplied`: AVFoundation then writes the `almo` box SkyCut reads
// (`SourceAlpha` in MediaProbe.swift; docs/architecture/freeze-frame.md 4a3 — premultiplied is what the preview's
// compositor wants, and the export un-premultiplies by the tag). Colors are tagged BT.709 like SkyCut's other made-up
// alpha sources (`AlphaSourceCopies`). HEVC with alpha waits until its quality loss is measured (user, 2026-11-16).
// After writing, the file is read back: no alpha, no premultiplied tag or the wrong length fail the render.
// Does not own: drawing frames (`PageWorker`, `FrameCapture`).

@MainActor
final class FrameEncoder {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure(description: "This Mac cannot write ProRes 4444 at \(width)×\(height).")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure(description: "The movie writer refused the video track.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure(description: "The movie could not be started: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: .zero)
        self.fps = Int32(fps)
    }

    func makeBuffer() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
              let buffer = made else { throw Failure(description: "No pixel buffer for the next frame.") }
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, frame index: Int) async throws {
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                              .shouldPropagate)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard writer.status == .writing,
              adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
            throw Failure(description: "Frame \(index) could not be written: \(writer.error?.localizedDescription ?? "unknown error").")
        }
    }

    /// The last frame lasts one frame: the track is exactly frames / fps long.
    func finish(frames: Int) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(description: "The movie could not be finished: \(writer.error?.localizedDescription ?? "unknown error").")
        }
    }

    /// Reads the written file back: one video track with alpha and the `almo` premultiplied tag, frames / fps long.
    /// When every frame was fully opaque the encoder leaves the alpha channel out (measured 2026-11-17): that movie is
    /// accepted without alpha (SkyCut reads it as opaque video); a translucent frame without alpha in the file fails.
    static func verify(_ url: URL, frames: Int, fps: Int, translucent: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw Failure(description: "The written movie has no video track.")
        }
        let alpha = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool
        let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        let mode = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_AlphaChannelMode) as? String
        let tagged = alpha == true && atoms?["almo"] != nil && mode == (kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String)
        guard tagged || (alpha != true && !translucent) else {
            throw Failure(description: "The written movie is not tagged as premultiplied alpha (alpha \(String(describing: alpha)), "
                + "almo \(atoms?["almo"] != nil), mode \(mode ?? "none"), translucent frames \(translucent)).")
        }
        let duration = try await track.load(.timeRange).duration
        let expected = CMTime(value: Int64(frames), timescale: Int32(fps))
        guard CMTimeCompare(duration, expected) == 0 else {
            throw Failure(description: "The written movie is \(duration.seconds) s long, expected \(expected.seconds) s.")
        }
    }
}
