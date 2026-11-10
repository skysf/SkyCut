import SwiftUI
import UniformTypeIdentifiers

// MARK: - 新建声音 / 给声音加一段录音（sheet）
//
// 管什么（SkyCut 声音方案 5.3）：名字、录音（现在录 / 选文件，音频视频都行）、语言（自动识别、可改）、用了哪一段和有效人声多少（能试听
// 那一段）、授权那一勾、费用一行（新建免费）、「新建」。还差什么写在按钮旁边（NewVoiceGate：没录够、没选语言、没勾授权、声音满了）。
// 同一个框也给已有的声音加一种语言的录音（标题换成「给『X』加一段录音」，不问名字，已经有的语言不列出来）。
// 数和规矩都在 NewVoiceModel（和 AI 的 manage_voices 同一条路）；这里只画。录音那一小块自己订阅录音机（一秒十次的电平不叫醒整个框）。
// 本地化：sheet 不继承应用内语言，调用处套 `.appLanguage()`。不读工程、不订阅播放器的时钟。

struct NewVoiceSheet: View {
    @StateObject private var model: NewVoiceModel
    @ObservedObject private var store: VoiceLibraryStore
    @ObservedObject private var audition = VoiceAudition.shared
    @Environment(\.dismiss) private var dismiss

    private static let labelWidth: CGFloat = 78

    init(mode: NewVoiceModel.Mode, store: VoiceLibraryStore) {
        self.init(model: NewVoiceModel(mode: mode, store: store), store: store)
    }

    /// 给一份现成的（回归和离屏渲染先把它摆到某个样子）。
    init(model: NewVoiceModel, store: VoiceLibraryStore) {
        _model = StateObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let blocker = model.blocker
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(.title3).fontWeight(.semibold)
            if case .create = model.mode {
                row("Name") {
                    TextField("My voice", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityIdentifier("new-voice-name")
                }
            }
            row("Recording") { recording }
            row("Recording language") { languageRow }
            row("Used") { sampleRow }
            consentRow
            row("Cost") {
                Text("Creating a voice is free. Its MiniMax version, a one-time fee, is only built if a later voiceover needs it, and SkyCut asks first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.problem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                if model.submitting {
                    ProgressView().controlSize(.small)
                } else if let hint = VoiceLibraryText.blocker(blocker, voiceName: voiceName) {
                    Text(verbatim: hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                Button(submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil)
                    .accessibilityIdentifier("new-voice-submit")
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await model.presetAgreementFromStandingGrant() }
        // 换成「选文件」时正在录的那一段不要了（不然它在后台接着录、录完还会顶掉刚选的文件）。
        .onChange(of: model.source) { _, source in
            if source == .file { model.recorder.discard() }
        }
        .onDisappear { model.close() }
    }

    private var voiceName: String? {
        if case .addReference(let voice) = model.mode { return voice.name }
        return nil
    }

    private var title: String {
        voiceName.map { String(format: L10n("Add a Recording to “%@”"), $0) } ?? L10n("New Voice")
    }

    private var submitTitle: LocalizedStringKey {
        voiceName == nil ? "Create" : "Add Recording"
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 录音从哪来

    private var recording: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Recording", selection: $model.source) {
                Text("Record Now").tag(NewVoiceModel.Source.record)
                Text("Choose a File").tag(NewVoiceModel.Source.file)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("new-voice-source")
            switch model.source {
            case .record:
                VoiceRecordingControls(recorder: model.recorder, folder: model.recordingFolder)
            case .file:
                HStack(spacing: 8) {
                    Button("Choose File…", action: chooseFile)
                        .accessibilityIdentifier("new-voice-choose-file")
                        .instantHelp("Pick an audio or video file of the person talking; longer than 3 minutes is fine, SkyCut picks the best part")
                    if let name = model.fileName {
                        Text(verbatim: name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Text("30 seconds to 1 minute works best; at least 10 seconds, at most 3 minutes. One person talking, no background music.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFile() {
        guard let file = FilePicker.chooseFiles(types: [.audio, .movie], allowsMultiple: false).first else { return }
        model.use(file: file)
    }

    // MARK: 语言

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Recording language", selection: Binding(get: { model.language ?? "" }, set: { model.choose(language: $0.isEmpty ? nil : $0) })) {
                    if model.language == nil { Text("Choose…").tag("") }
                    ForEach(model.languageChoices, id: \.self) { code in
                        Text(verbatim: VoiceLibraryText.languageName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("new-voice-language")
                if model.detectingLanguage {
                    ProgressView().controlSize(.small)
                    Text("Detecting…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("The language spoken in the recording. SkyCut detects it when this Mac can; change it if it is wrong.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 用了哪一段

    @ViewBuilder
    private var sampleRow: some View {
        switch model.sample {
        case .none:
            Text("Nothing yet").font(.callout).foregroundStyle(.secondary)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the recording…").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .ready(let sample):
            let playing = audition.playingID == Self.sampleAuditionID
            HStack(spacing: 8) {
                Text(verbatim: VoiceLibraryText.sampleSummary(sample))
                    .font(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    VoiceAudition.shared.toggle(Self.sampleAuditionID, url: sample.url)
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(playing ? LocalizedStringKey("Stop") : LocalizedStringKey("Play the part SkyCut will use")))
                .instantHelp(playing ? LocalizedStringKey("Stop") : LocalizedStringKey("Play the part SkyCut will use"))
            }
        }
    }

    private static let sampleAuditionID = "new-voice-sample"

    // MARK: 授权

    @ViewBuilder
    private var consentRow: some View {
        if let statement = model.consentStatement {
            Toggle(isOn: Binding(get: { model.agreed }, set: { model.setAgreed($0) })) {
                Text(verbatim: VoiceLibraryText.consent(statement))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("new-voice-consent")
        }
    }

    private func submit() {
        Task {
            if await model.submit() != nil { dismiss() }
        }
    }
}

/// 「现在录」那一小块：录 / 停、电平条、已录的时间；麦克风没授权时说去哪里开。只有它订阅录音机。
private struct VoiceRecordingControls: View {
    @ObservedObject var recorder: VoiceSampleRecorder
    let folder: URL

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if recorder.state == .recording {
                    Button { recorder.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .accessibilityIdentifier("new-voice-stop")
                        .instantHelp("Stop recording and use this take")
                } else {
                    Button { Task { await recorder.start(in: folder) } } label: { Label("Record sample", systemImage: "record.circle") }
                        .disabled(recorder.state == .asking)
                        .accessibilityIdentifier("new-voice-record")
                        .instantHelp("Record with this Mac's microphone; recording stops by itself at 3 minutes")
                }
                ProgressView(value: recorder.state == .recording ? recorder.level : 0)
                    .frame(width: 120)
                    .accessibilityLabel(Text("Input level"))
                Text(verbatim: VoiceReferenceSample.clock(recorder.elapsed))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(recorder.state == .recording ? .primary : .secondary)
            }
            switch recorder.state {
            case .denied:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("SkyCut is not allowed to use the microphone. Turn it on in System Settings > Privacy & Security > Microphone, then record again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Open System Settings", destination: ScreenRecordingPermissions.microphoneSettingsURL)
                        .font(.caption)
                }
            case .failed(let message):
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .asking, .recording:
                EmptyView()
            }
        }
    }
}
