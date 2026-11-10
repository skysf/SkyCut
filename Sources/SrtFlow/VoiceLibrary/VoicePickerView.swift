import SwiftUI

// MARK: - 声音选择器（共用组件）
//
// 管什么（SkyCut 声音方案 5.2）：上面一排语言（中文 / English / 其他语言），下面三组：我的声音、设计的声音、预设声音；每行名字、
// 这种语言的说明（预设）或有哪几种语言的录音（我的声音）、▶ 试听，默认的那个标出来。给了 `selection` 就能点选（片段右键变声的面板用），
// 不给就只是浏览（设置里「浏览预设声音…」）。列什么、默认哪一排、说明用哪种语言在 VoicePickerRows（纯值）；试听只经 VoiceAudition
// （同一时间只放一个，这个视图消失就停）。
// 只订阅声音库（VoiceLibraryStore）、试听（VoiceAudition）和界面语言；不读工程、不订阅播放器的时钟。
// 挂在 sheet / popover 里时调用处套 `.appLanguage()`（checks/presented-views-app-language.sh）。
// 不管什么：声音库怎么取（VoiceLibraryStore）、选了之后做什么（调用方）。

struct VoicePickerView: View {
    /// 选中的那个（`voice_…` / `gemini:<名字>`）；nil = 只浏览、不能选。
    var selection: Binding<String?>?
    @ObservedObject var store: VoiceLibraryStore = .shared
    @ObservedObject private var audition = VoiceAudition.shared
    @ObservedObject private var language = AppLanguageStore.shared
    /// 用户点过的那一排；没点过就照界面语言的默认。
    @State private var chosenTab: VoicePickerTab?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let ui = language.language.resolvedCode
        let tab = chosenTab ?? .initial(uiLanguage: ui)
        let sections = VoicePickerRows.sections(catalog: store.catalog, voices: store.voices, tab: tab, uiLanguage: ui)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Voice list language", selection: Binding(get: { tab }, set: { chosenTab = $0; audition.stop() })) {
                Text(verbatim: "中文").tag(VoicePickerTab.chinese)
                Text(verbatim: "English").tag(VoicePickerTab.english)
                Text("Other languages").tag(VoicePickerTab.other)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("voice-picker-language")
            if tab == .other {
                Text("Other languages use the English list; any of these voices can read them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        VoicePickerSectionView(section: section, tab: tab, store: store, playingID: audition.playingID, selection: selection)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .task { if store.phase == .idle { await store.refresh() } }
        .onDisappear { audition.stop() }
    }
}

private struct VoicePickerSectionView: View {
    let section: VoicePickerSection
    let tab: VoicePickerTab
    let store: VoiceLibraryStore
    let playingID: String?
    let selection: Binding<String?>?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 设计的声音一个都没有时不占一栏；另外两组空着时说一句为什么。
        if !(section.kind == .designed && section.rows.isEmpty) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)
            if section.rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            ForEach(section.rows) { row in
                VoicePickerRowView(row: row, tab: tab, store: store, playing: playingID == Self.auditionID(row, tab),
                                   selected: selection?.wrappedValue == row.id, select: selection.map { binding in { binding.wrappedValue = row.id } })
            }
        }
    }

    /// 同一个预设中英文是两段样音：试听的记号带上这一排的语言。
    static func auditionID(_ row: VoicePickerRow, _ tab: VoicePickerTab) -> String { row.id + "|" + tab.rawValue }

    private var title: LocalizedStringKey {
        switch section.kind {
        case .mine: return "My voices"
        case .designed: return "Designed voices"
        case .preset: return "Preset voices"
        }
    }

    private var emptyText: LocalizedStringKey {
        section.kind == .preset
            ? "Preset voices could not be loaded. Check your Sky Studio connection."
            : "No voices of your own yet. Create one from a recording in Settings > Editing & Voices."
    }
}

private struct VoicePickerRowView: View {
    let row: VoicePickerRow
    let tab: VoicePickerTab
    let store: VoiceLibraryStore
    let playing: Bool
    let selected: Bool
    let select: (() -> Void)?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 8) {
            if select != nil {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppThemePalette.current.accent : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppThemePalette.current.selectionFill))
                    }
                }
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if canPlay {
                Button(action: play) {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(playing ? LocalizedStringKey("Stop") : LocalizedStringKey("Play a sample")))
                .instantHelp(playing ? LocalizedStringKey("Stop") : LocalizedStringKey("Play a sample"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if selected { RoundedRectangle(cornerRadius: 6).fill(AppThemePalette.current.selectionFill) }
        }
        .contentShape(Rectangle())
        .onTapGesture { select?() }
        .accessibilityIdentifier("voice-picker-row-\(row.id)")
    }

    /// 预设：这种语言的说明（没有就写性别）；我的声音：有哪几种语言的录音。
    private var detail: String? {
        switch row.kind {
        case .preset: return row.detail ?? VoiceLibraryText.gender(row.gender)
        case .mine, .designed: return row.languages.isEmpty ? nil : VoiceLibraryText.languageNames(row.languages)
        }
    }

    private var canPlay: Bool { row.kind == .preset ? row.sampleURL != nil : row.previewLanguage != nil }

    private func play() {
        let id = VoicePickerSectionView.auditionID(row, tab)
        if let url = row.sampleURL { return VoiceAudition.shared.toggle(id, url: url) }
        guard let language = row.previewLanguage else { return }
        let store = store
        let voice = row.id
        VoiceAudition.shared.toggle(id) { await store.previewURL(voice: voice, language: language) }
    }
}
