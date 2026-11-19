import AppKit
import Combine
import SwiftUI

// MARK: - 设置 → 剪辑与声音 里的「剪辑风格」
//
// 管什么：every style AI can follow, one row each with where it comes from (2026-11-19, SS5 plan 5.3): the presets, Sky Studio's
// (with their version, or "needs SkyCut Pro" when the licence leaves them out; no Show in Finder / Delete), the user's own
// (在访达中显示、删除（进废纸篓），as before), and the user's files a Sky Studio style of the same name hides (with a rename hint);
// 外加打开放用户自己风格的文件夹。Rows come from AIRecipeSettingsRow (pure).
// 中文叫「剪辑风格」，内置的叫「预设风格」（2026-09-28 用户：不叫「剪辑套路」，方案第 53 条）；代码和工具名里仍叫 recipe。
// 方案第 41 条：SrtFlow 里不做编辑界面 —— 想改就让 AI 改，或者用文本编辑器打开那个 .md。AI picks the style; the user says which
// one in words (MCP plan item 39), so there is no picker here.
// 不管什么：剪辑风格怎么读写（AIRecipeStore）、给 AI 的工具（AIRecipeTools）、Sky Studio's list and copies (SkyStudioStyleLibrary).

/// 设置页订阅的那一份剪辑风格。AI 存完一套由路由叫 `refresh`；设置页每次出现也刷一次（用户可能在访达里改过文件）；
/// Sky Studio's list changing (a new manifest, the licence) refreshes it too.
@MainActor
final class AIRecipeLibrary: ObservableObject {
    static let shared = AIRecipeLibrary()

    @Published private(set) var rows: [AIRecipeSettingsRow] = []
    private let store = AIRecipeStore.shared
    private var skyStudioWatch: AnyCancellable?

    private init() {
        refresh()
        skyStudioWatch = SkyStudioStyles.shared.$listing.dropFirst().sink { [weak self] listing in
            MainActor.assumeIsolated { self?.refresh(listing) }
        }
    }

    func refresh() { refresh(SkyStudioStyles.shared.listing) }

    private func refresh(_ listing: SkyStudioStyleLibrary.Listing) {
        let skyStudio = listing.styles.map {
            AIRecipe(id: $0.id, title: $0.title, useFor: $0.useFor, body: "", source: .skyStudio, version: $0.version)
        }
        let catalog = AIRecipeCatalog(builtIn: AIBuiltInRecipes.load(), user: store.userRecipes(), skyStudio: skyStudio)
        let next = AIRecipeSettingsRow.rows(catalog, skyStudioEntitled: SkyStudioAccount.shared.license.recipes)
        if next != rows { rows = next }
    }

    func reveal(_ recipe: AIRecipe) {
        guard let url = store.fileURL(for: recipe) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func remove(_ recipe: AIRecipe) {
        try? store.remove(recipe)
        refresh()
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }
}

struct AIRecipesList: View {
    @ObservedObject private var library = AIRecipeLibrary.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Editing styles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Open Folder") { library.openFolder() }
                    .controlSize(.small)
                    .instantHelp("Show the folder with your own editing styles in Finder")
            }
            Text("AI picks one of these when it edits a whole video, and follows the one you name. Ask it to save a style you like as your own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(library.rows) { row in
                AIRecipeRow(row: row, library: library)
            }
        }
        .onAppear {
            library.refresh()
            SkyStudioStyles.shared.refreshIfStale()
        }
    }
}

private struct AIRecipeRow: View {
    let row: AIRecipeSettingsRow
    let library: AIRecipeLibrary

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: row.recipe.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    AIRecipeSourceTag(kind: row.kind)
                }
                if row.kind == .hiddenBySkyStudio {
                    Text("A Sky Studio style has this name, so AI follows that one. Rename this file to use yours.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if row.hasFile {
                Button("Show in Finder") { library.reveal(row.recipe) }
                    .controlSize(.small)
                    .instantHelp("Open this style's file in Finder; any text editor can change it")
                Button("Delete") { library.remove(row.recipe) }
                    .controlSize(.small)
                    .instantHelp("Move this style to the Trash")
            }
        }
    }
}

/// Where a style comes from, in small grey text after its title.
private struct AIRecipeSourceTag: View {
    let kind: AIRecipeSettingsRow.Kind

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Group {
            switch kind {
            case .preset:
                Text("Preset style")
            case .skyStudio(_, true):
                Text("Sky Studio · needs SkyCut Pro")
                    .instantHelp("Sky Studio's editing styles come with SkyCut Pro or the SkyCut trial")
            case .skyStudio(let version, false):
                Text("Sky Studio · \(version)")
            case .yours(true):
                Text("Replaces the preset style")
            case .yours(false), .hiddenBySkyStudio:
                Text("Your style")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
