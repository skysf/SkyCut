import AVFoundation
import Foundation

// MARK: - 声音的试听：一个播放器，同一时间只放一个
//
// 管什么（SkyCut 声音方案 5.2）：选择器、设置里的声音库、新建声音对话框里的 ▶ 都经这里：点一下放这一个（别的停掉），再点一下停；
// 放完自己停；面板关掉时调用方 `stop()`。预设的样音是公开地址、直接流播；我的声音的试听是 1 小时的临时链接，要放的时候现取
// （调用方给一个取链接的闭包），取不到就不放。本机的文件（刚做好的参考录音）同样放。
// 不订阅播放器的时间、不读工程；只发「正在放哪一个」。不压时间线的音量（设置窗口里的事，和音频库的试听不是一回事）。

@MainActor
final class VoiceAudition: ObservableObject {
    static let shared = VoiceAudition()

    /// 正在放（或正在取链接）的那一个；没有就是 nil。
    @Published private(set) var playingID: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var loading: Task<Void, Never>?

    init() {}

    /// 点一下：正在放这个就停，否则换成这个。`url` 现取（临时链接），取不到就不放。
    func toggle(_ id: String, url: @escaping @MainActor () async -> URL?) {
        if playingID == id { return stop() }
        stop()
        playingID = id
        loading = Task { [weak self] in
            let found = await url()
            guard let self, !Task.isCancelled, self.playingID == id else { return }
            guard let found else { return self.stop() }
            self.play(found, id: id)
        }
    }

    func toggle(_ id: String, url: URL) {
        toggle(id) { url }
    }

    func stop() {
        loading?.cancel()
        loading = nil
        for observer in [endObserver, failObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        failObserver = nil
        player?.pause()
        player = nil
        if playingID != nil { playingID = nil }
    }

    private func play(_ url: URL, id: String) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = ProcessInfo.processInfo.environment["SRTFLOW_SMOKE_MUTE"] == nil ? 1 : 0
        self.player = player
        let finish: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in if self?.playingID == id { self?.stop() } }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main, using: finish)
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main, using: finish)
        player.play()
    }
}
