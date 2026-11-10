import SwiftUI

// MARK: - 设置 → 剪辑与声音里的「声音库」一节
//
// 管什么（SkyCut 声音方案 5.1）：我的声音列表（试听、加另一种语言的录音、改名、删除）+「新建声音…」「设计声音…」「浏览预设声音…」。
// 几种样子：
// - 没有 Sky Studio 的 Key：写「接上 Sky Studio 才能用」，按钮去「设置 → Sky Studio」；钥匙串要授权：同样去那一页点「允许…」。
// - Sky Studio 回 `voice_library_unavailable`：写「声音库暂时用不了，稍后再试」，新建、设计灰着（列表本来就是空的），
//   预设照样能浏览、试听。
// - 别的毛病（断网…）：那一句 +「重试」。
// 删除先确认一句「删除『X』？」，不另加说明（决定第三节第 7 条）；删了立刻从列表消失。
// 只订阅 VoiceLibraryStore（一个小对象）；sheet 各套 `.appLanguage()`。不读工程、不订阅播放器的时钟。
// 不管什么：声音库怎么取、改名 / 删除怎么发（VoiceLibraryStore）、对话框里面（NewVoiceSheet / DesignVoiceSheet / VoicePickerView）。

struct VoiceLibrarySettingsSection: View {
    /// 去「设置 → Sky Studio」那一页（粘 Key、点「允许…」）。
    let openSkyStudioSettings: () -> Void
    @ObservedObject var store: VoiceLibraryStore = .shared
    @State private var sheet: VoiceLibrarySheet?
    @State private var deleting: SkyStudioVoice?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Voice library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if store.phase == .loading { ProgressView().controlSize(.small) }
            }
            Text("Your own voices for AI voiceovers: clone a voice from a recording of someone talking, or design one from a description. They are kept in your Sky Studio account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            ForEach(store.voices, id: \.id) { voice in
                VoiceLibraryRow(voice: voice, busy: store.working.contains(voice.id), canEdit: store.canEdit, store: store,
                                addRecording: { sheet = .addRecording(voice) }, rename: { sheet = .rename(voice) }, delete: { deleting = voice })
            }
            ForEach(Array(store.designing.enumerated()), id: \.offset) { entry in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(format: L10n("Designing “%@”… It appears here when it is ready."), entry.element))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let notice = store.notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            actions
        }
        .task { await store.refresh() }
        .onDisappear { VoiceAudition.shared.stop() }
        .sheet(item: $sheet) { item in
            VoiceLibrarySheetContent(item: item, store: store).appLanguage()
        }
        .confirmationDialog(
            String(format: L10n("Delete “%@”?"), deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
        ) {
            Button(L10n("Delete"), role: .destructive, action: confirmDelete)
            Button(L10n("Cancel"), role: .cancel) { deleting = nil }
        }
        // 冒烟驱动点不了这几个按钮（背后是 NSButton）：它发一声，这里照点按钮那样摆 sheet、按「删除」（SmokeVoiceSteps）。
        .smokeVoiceLibrary(store: store, sheet: $sheet, deleting: $deleting, confirmDelete: confirmDelete)
    }

    /// 「删除『X』？」里的「删除」。
    private func confirmDelete() {
        if let voice = deleting { Task { await store.delete(voice) } }
        deleting = nil
    }

    @ViewBuilder
    private var status: some View {
        switch store.phase {
        case .noKey:
            linkLine("Connect your Sky Studio account to use the voice library.", button: "Open Sky Studio Settings")
        case .needsPermission:
            linkLine("macOS needs your permission before SkyCut can read the key.", button: "Open Sky Studio Settings")
        case .unavailable:
            Text("The voice library is not available right now. Try again later.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Try Again") { Task { await store.refresh() } }
                    .controlSize(.small)
                    .instantHelp("Ask Sky Studio for your voices again")
            }
        case .ready where store.voices.isEmpty && store.designing.isEmpty:
            Text("No voices yet. A good sample is 30 seconds to 1 minute of one person talking, without background music.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .loading, .ready:
            EmptyView()
        }
    }

    private func linkLine(_ text: LocalizedStringKey, button: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: openSkyStudioSettings)
                .controlSize(.small)
                .accessibilityIdentifier("voice-library-open-sky-studio")
                .instantHelp("Go to Settings > Sky Studio to connect your account")
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("New Voice…") { sheet = .new }
                .disabled(!store.canEdit)
                .accessibilityIdentifier("voice-library-new")
                .instantHelp("Create a voice from a recording: record now or choose a file")
            Button("Design Voice…") { sheet = .design }
                .disabled(!store.canEdit)
                .accessibilityIdentifier("voice-library-design")
                .instantHelp("Design a new voice from a description; a one-time fee in Sky Studio credits")
            Spacer(minLength: 8)
            Button("Browse Preset Voices…") { sheet = .browse }
                .disabled(store.catalog == nil)
                .accessibilityIdentifier("voice-library-browse")
                .instantHelp("Listen to Sky Studio's preset voices in each language")
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}

/// 这一节能弹出的几张。
enum VoiceLibrarySheet: Identifiable {
    case new
    case addRecording(SkyStudioVoice)
    case design
    case browse
    case rename(SkyStudioVoice)

    var id: String {
        switch self {
        case .new: return "new"
        case .addRecording(let voice): return "add:" + voice.id
        case .design: return "design"
        case .browse: return "browse"
        case .rename(let voice): return "rename:" + voice.id
        }
    }
}

struct VoiceLibrarySheetContent: View {
    let item: VoiceLibrarySheet
    let store: VoiceLibraryStore

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        switch item {
        case .new: NewVoiceSheet(mode: .create, store: store)
        case .addRecording(let voice): NewVoiceSheet(mode: .addReference(voice), store: store)
        case .design: DesignVoiceSheet(store: store)
        case .browse: VoiceBrowserSheet(store: store)
        case .rename(let voice): VoiceRenameSheet(voice: voice, store: store)
        }
    }
}

/// 我的声音的一行：名字、来源、有哪几种语言，▶ 试听、加一种语言的录音、改名、删除。
private struct VoiceLibraryRow: View {
    let voice: SkyStudioVoice
    let busy: Bool
    let canEdit: Bool
    let store: VoiceLibraryStore
    let addRecording: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @ObservedObject private var audition = VoiceAudition.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let playing = audition.playingID == auditionID
        HStack(spacing: 6) {
            Image(systemName: voice.source == "design" ? "wand.and.stars" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(verbatim: voice.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            if let language = voice.languages.first?.language {
                iconButton(playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Play a sample") {
                    let store = store
                    let id = voice.id
                    VoiceAudition.shared.toggle(auditionID) { await store.previewURL(voice: id, language: language) }
                }
            }
            iconButton("plus", help: "Add a recording in another language", action: addRecording)
                .disabled(!canEdit || busy)
            iconButton("pencil", help: "Rename this voice", action: rename)
                .disabled(!canEdit || busy)
            iconButton("trash", help: "Delete this voice and its recordings for good", action: delete)
                .disabled(!canEdit || busy)
        }
        .accessibilityIdentifier("voice-library-row-\(voice.id)")
    }

    private var auditionID: String { "library|" + voice.id }

    /// 「录音 · 中文 · English」/「设计」。
    private var detail: String {
        let source = voice.source == "design" ? L10n("Designed") : L10n("Recorded")
        return ([source] + voice.languages.map { VoiceLibraryText.languageName($0.language) }).joined(separator: " · ")
    }

    private func iconButton(_ icon: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(help))
        .instantHelp(help)
    }
}

/// 「浏览预设声音…」：选择器只浏览、不选。
private struct VoiceBrowserSheet: View {
    let store: VoiceLibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 12) {
            Text("Voices").font(.title3).fontWeight(.semibold)
            Text("AI voiceovers use the default voice unless you ask for another one by name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VoicePickerView(selection: nil, store: store)
                .frame(minHeight: 320, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// 改名。
private struct VoiceRenameSheet: View {
    let voice: SkyStudioVoice
    let store: VoiceLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false

    init(voice: SkyStudioVoice, store: VoiceLibraryStore) {
        self.voice = voice
        self.store = store
        _name = State(initialValue: voice.name)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let valid = (try? SkyStudioVoiceNaming.checked(name)) != nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Voice").font(.title3).fontWeight(.semibold)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityIdentifier("voice-rename-field")
                .onSubmit(save)
            if !valid {
                Text("Give the voice a name (up to 80 characters).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || saving || name.trimmingCharacters(in: .whitespacesAndNewlines) == voice.name)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        guard !saving, (try? SkyStudioVoiceNaming.checked(name)) != nil else { return }
        saving = true
        Task {
            // 没改成那一句写在设置的那一节里（store.notice）；这里都收起来。
            _ = await store.rename(voice, to: name)
            dismiss()
        }
    }
}
