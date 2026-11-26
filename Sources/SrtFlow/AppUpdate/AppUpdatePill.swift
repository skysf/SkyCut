import SwiftUI

// MARK: - The toolbar's update pill
//
// What it does: the small button in the right toolbar group of every workbench window (the editor's, between the AI badge
// and the cloud tasks; the other tools' pages, before Settings): Update once a new version is downloaded and verified,
// New Version (outlined) when SkyCut only tells (auto install off, or a copy that can't update itself), Updated on the
// first launch after an update. Nothing while checking or downloading in the background. It never opens by itself:
// clicking opens its popover, and so does the app menu's "Restart and Update to …" (the focused project's window). Updated goes
// away once its notes were looked at. Subscribes only to AppUpdater, never to a project or the player clock.
// What it doesn't: the popover's content (AppUpdatePopover), the updater (AppUpdater).
// Rules: docs/architecture/app-updates.md "What the person sees".

struct AppUpdatePill: View, Equatable {
    /// The window's project (nil on the tools' pages: the main window's).
    let project: VideoEditProject?
    @ObservedObject private var updater = AppUpdater.shared
    @State private var showsPopover = false

    /// The toolbar redrawing (a selection, an edit) doesn't redraw the pill: only the updater does (preview-perf-ratchet.md).
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.project === rhs.project }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if let pill = updater.state.pill {
            Button { showsPopover.toggle() } label: { AppUpdatePillLabel(pill: pill) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("app-update-pill")
                .accessibilityLabel(Text(verbatim: help(pill)))
                .instantHelp(verbatim: help(pill))
                .popover(isPresented: $showsPopover, arrowEdge: .top) {
                    AppUpdatePopover(project: project ?? OpenProjects.shared.primary) { showsPopover = false }.appLanguage()
                }
                .onChange(of: showsPopover) { _, shown in
                    if !shown, updater.state.pill == .updated { updater.notesViewed() }
                }
                .onChange(of: updater.popoverRequest) { _, _ in presentIfRequested() }
                .onAppear { presentIfRequested() }
        }
    }

    /// The app menu asked for the popover in this window: its project is the one asked for (the main window's pill stands
    /// for the main window's project on every page).
    private func presentIfRequested() {
        guard let request = updater.popoverRequest, request == ObjectIdentifier(project ?? OpenProjects.shared.primary) else { return }
        updater.popoverPresented()
        showsPopover = true
    }

    private func help(_ pill: AppUpdateState.Pill) -> String {
        let version = updater.offerVersion ?? updater.state.updated?.to.description ?? ""
        switch pill {
        case .ready: return String(format: L10n("SkyCut %@ is ready"), version)
        case .newVersion: return String(format: L10n("New version: SkyCut %@"), version)
        case .updated: return String(format: L10n("Updated to SkyCut %@"), version)
        }
    }
}

/// The pill itself: the mockup's three looks in the theme's colours (forest: light green / outlined / dark green).
struct AppUpdatePillLabel: View {
    let pill: AppUpdateState.Pill

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let palette = AppThemePalette.current
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(LocalizedStringKey(title))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(pill == .updated ? Color.white : palette.accent)
        .padding(.leading, 8)
        .padding(.trailing, 11)
        .frame(height: 26)
        .background {
            // An opaque base first (the toolbar's divider may run behind it, as AIActivityBadgeBackground notes).
            Capsule().fill(palette.window)
            switch pill {
            case .ready: Capsule().fill(palette.selectionFill)
            case .newVersion: Capsule().strokeBorder(palette.accent, lineWidth: 1)
            case .updated: Capsule().fill(palette.accent)
            }
        }
        .contentShape(Capsule())
    }

    private var title: String {
        switch pill {
        case .ready: return "Update"
        case .newVersion: return "New Version"
        case .updated: return "Updated"
        }
    }

    private var icon: String {
        switch pill {
        case .ready: return "arrow.clockwise"
        case .newVersion: return "arrow.down.to.line"
        case .updated: return "checkmark"
        }
    }
}
