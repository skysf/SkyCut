import AVFoundation
import SwiftUI
import SrtFlowCore

// Small posters come from the rendered movie, never a second page renderer. The bounded cache holds no players or full-size frames.
@MainActor
enum WebMotionMoviePoster {
    private struct Key: Hashable {
        var file: URL
        var time: Double
    }
    private static var cache: [Key: CGImage] = [:]
    private static let maximumCount = 24

    static func image(for movie: URL, record: WebMotionClipRecord) async -> CGImage? {
        let time = min(max(0, record.duration - FrameGrid(fps: record.fps).time(ofFrame: 1)),
                       max(record.hitTime, record.duration * 0.55))
        let key = Key(file: movie, time: time)
        if let image = cache[key] { return image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 272, height: 153)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
              !Task.isCancelled else { return nil }
        if cache.count >= maximumCount, let first = cache.keys.first { cache.removeValue(forKey: first) }
        cache[key] = image
        return image
    }
}

// An idle card is a poster. A player exists only while that card is hovered and is torn down as soon as it leaves the view tree.
struct WebMotionMoviePreview: View {
    var movie: URL
    var record: WebMotionClipRecord
    var isPlaying: Bool
    @State private var poster: CGImage?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack {
            Color.black
            if let poster {
                Image(decorative: poster, scale: 2).resizable().scaledToFit()
            }
            if isPlaying {
                WebMotionHoverPlayer(movie: movie)
            }
        }
        .allowsHitTesting(false)
        .task(id: movie) { poster = await WebMotionMoviePoster.image(for: movie, record: record) }
    }
}

private struct WebMotionHoverPlayer: NSViewRepresentable {
    let movie: URL

    func makeCoordinator() -> Playback { Playback() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        context.coordinator.play(movie, in: view)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        PerfCounters.update(Self.self)
        if context.coordinator.movie != movie { context.coordinator.play(movie, in: nsView) }
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Playback) {
        coordinator.stop()
        nsView.player = nil
    }

    @MainActor
    final class Playback {
        var movie: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func play(_ url: URL, in view: PlayerLayerView) {
            stop()
            movie = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player
            view.player = player
            player.play()
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player?.removeAllItems()
            player = nil
            movie = nil
        }
    }
}
