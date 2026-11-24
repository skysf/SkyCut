import Combine
import SwiftUI

// MARK: - Open the Settings window at one pane
//
// What it covers: a button outside Settings (a paid panel's "Change Limit…", MSG1) asks for a pane and opens the one Settings
// window; SettingsWindowView takes the request when it appears (the window was closed) or right away (it was open).
// What it does not cover: the window itself (SwiftUI's Settings scene, SettingsWindowView) or any setting's value.

@MainActor
final class SettingsNavigator {
    static let shared = SettingsNavigator()

    /// Requests while the window is open.
    let requests = PassthroughSubject<SettingsCategory, Never>()
    /// The last request, until a window takes it: a closed window is not subscribed when the button is pressed.
    private var pending: SettingsCategory?

    /// Shows `category` in the Settings window, opening it (SwiftUI's own action, the same window as the gear and Command-comma).
    func show(_ category: SettingsCategory, open: OpenSettingsAction) {
        pending = category
        requests.send(category)
        open()
    }

    /// The pane a window that just appeared should show (and forgets it).
    func takePending() -> SettingsCategory? {
        defer { pending = nil }
        return pending
    }
}

extension View {
    /// SettingsWindowView: follow SettingsNavigator's requests into `selection`.
    func settingsNavigation(selection: Binding<SettingsCategory>) -> some View {
        modifier(SettingsNavigationModifier(selection: selection))
    }
}

private struct SettingsNavigationModifier: ViewModifier {
    let selection: Binding<SettingsCategory>

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content
            .onAppear { if let pane = SettingsNavigator.shared.takePending() { selection.wrappedValue = pane } }
            .onReceive(SettingsNavigator.shared.requests) { pane in
                _ = SettingsNavigator.shared.takePending()
                selection.wrappedValue = pane
            }
    }
}
