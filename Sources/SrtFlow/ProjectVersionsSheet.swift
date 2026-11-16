import SwiftUI

// MARK: - The Versions sheet: a project's saved versions, and going back to one in one step
//
// What it covers: the list (newest first: id, what the version was saved for, when), "Go Back" on each, the empty state.
// It reads only the project's ProjectVersionStore, never the project's timeline, so editing does not recompute it.
// What it doesn't: saving or restoring a version (ProjectVersionStore), when versions are saved (AIRound).
// Opened from the project menu (VideoEditProjectMenu). Rules: docs/architecture/project-versions.md.

struct ProjectVersionsSheet: View {
    let project: VideoEditProject
    @ObservedObject private var store: ProjectVersionStore
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss

    init(project: VideoEditProject) {
        self.project = project
        _store = ObservedObject(wrappedValue: ProjectVersionStore.for(project))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 14) {
            Text("Versions")
                .font(.title3.weight(.semibold))
            Text("SkyCut saves a version before and after each round of AI edits, when the project changed. Going back is one step: ⌘Z returns.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.versions.isEmpty {
                Text("No saved versions yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.versions) { version in
                            ProjectVersionRow(version: version) { goBack(to: version) }
                            if version.id != store.versions.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(store.versions.count) * ProjectVersionRow.height, 320))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { store.refresh() }
    }

    /// The sheet closes at once; the project changes when the version is read (a moment), as one undo step.
    private func goBack(to version: ProjectVersion) {
        dismiss()
        let project = project
        let store = store
        Task { @MainActor in
            do {
                _ = try await store.goBack(to: version.id)
            } catch {
                project.notice = String(format: L10n("Could not go back to %@."), version.id)
            }
        }
    }
}

/// One saved version in the sheet.
private struct ProjectVersionRow: View {
    static let height: CGFloat = 50
    let version: ProjectVersion
    let goBack: () -> Void

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 12) {
            Text(verbatim: version.id)
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let kind = version.kind {
                    Text(LocalizedStringKey(kind.title))
                } else {
                    Text("Saved version")
                }
                Text(version.savedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Go Back", action: goBack)
                .instantHelp("Put the whole project back to this version in one step; ⌘Z returns")
        }
        .frame(minHeight: Self.height - 1)
    }
}
