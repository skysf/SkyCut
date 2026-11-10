import AVFoundation
import Foundation

// MARK: - 新建声音对话框里的「现在录」
//
// 管什么（SkyCut 声音方案 5.3）：用麦克风录一段声音样本：第一次按「录」时才请求麦克风授权（和录屏同一个请求口
// `ScreenRecordingPermissions.requestMicrophoneAccess`，没按过就不弹）；被拒了说去系统设置哪里开。录成 44.1 kHz 单声道 16-bit WAV
// （和参考录音同一个规格，后面照样过 VoiceReferenceSample 那一遍：有效人声、挑段都在那里，这里不另算）；
// 电平条和已录的时间一秒十次；到 3 分钟自己停（参考录音最长 3 分钟）。录完把文件交给对话框（NewVoiceModel）。
// 只有录音那一小块视图订阅它（一秒十次的电平不叫醒整个对话框）。
// 不管什么：录下来的东西够不够格（VoiceReferenceSample）、建声音（NewVoiceModel）。

@MainActor
final class VoiceSampleRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        /// 在等用户回答系统的麦克风授权框。
        case asking
        /// 麦克风没授权。
        case denied
        case recording
        /// 录不了（没有输入设备、文件写不了）：系统给的那一句。
        case failed(String)
    }

    /// 最长录多久：参考录音的上限（3 分钟），到了自己停。
    nonisolated static var maximumSeconds: Double { VoiceReferenceWindow.maximumSeconds }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    /// 0…1 的电平。
    @Published private(set) var level: Double = 0

    /// 录完（用户按了停、或到了 3 分钟）：录下来的文件。
    var onFinish: (@MainActor (URL) -> Void)?
    /// 回归换成假的：请求麦克风授权。
    var requestAccess: @MainActor () async -> Bool = { await ScreenRecordingPermissions.requestMicrophoneAccess() }

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    /// 录音文件的规格：和参考录音一样（44.1 kHz 单声道 16-bit PCM）。
    nonisolated static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VoiceReferenceSample.sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// 电平条的 0…1：−50 dB 以下是 0，0 dB 是 1。
    nonisolated static func level(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        return Double(max(0, min(1, (decibels + 50) / 50)))
    }

    /// 开始录（先要到麦克风授权）。文件写进 `folder`。
    func start(in folder: URL) async {
        guard state != .recording, state != .asking else { return }
        state = .asking
        guard await requestAccess() else { return state = .denied }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("recording-" + UUID().uuidString.prefix(8) + ".wav")
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maximumSeconds) else {
                return state = .failed(L10n("The microphone could not start recording. Check the input device in System Settings > Sound."))
            }
            self.recorder = recorder
            elapsed = 0
            level = 0
            state = .recording
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 用户按了停：把录下来的交出去。
    func stop() {
        recorder?.stop()
    }

    /// 不要正在录的这一段了（对话框关了、换成选文件）：停下、删掉文件，不交出去。
    func discard() {
        let old = recorder
        cleanUp()
        old?.stop()
        old?.deleteRecording()
        if state == .recording || state == .asking { state = .idle }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let next = Self.level(decibels: recorder.averagePower(forChannel: 0))
        if abs(next - level) > 0.01 { level = next }
        elapsed = recorder.currentTime
    }

    private func cleanUp() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        level = 0
    }

    fileprivate func finished(_ url: URL, successfully: Bool) {
        guard recorder?.url == url else { return }
        cleanUp()
        state = successfully ? .idle : .failed(L10n("The recording could not be saved."))
        if successfully { onFinish?(url) }
    }
}

extension VoiceSampleRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in self.finished(url, successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor in self.finished(url, successfully: false) }
    }
}
