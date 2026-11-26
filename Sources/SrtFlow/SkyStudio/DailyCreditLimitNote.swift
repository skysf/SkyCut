import SwiftUI

// MARK: - A paid panel's line when SkyCut's daily credit limit stops it
//
// What it covers (MSG1, 2026-11-24): which limit stops the request (SkyCut's own setting, not the Sky Studio balance), the numbers
// (used, the limit, left, needed), where the setting is, and the reset time when waiting helps. Upscale, Design a Voice and Change
// Voice show it above their buttons, in place of the "Spent today" line, while the quote is over the limit. The words are
// SkyCutDailyLimit.userLine (the same numbers and path the AI is given).
// Change Limit… edits the limit in a popover right here, with the Settings row itself (SkyStudioCreditLimitRow). It never switches
// the Settings window's pane: Design a Voice is a sheet of that window's Editing pane, and leaving the pane would close the sheet
// and lose its draft (MSG1 review, 2026-11-25). Raising the limit enables the panel's button at once (the store is observed).
// What it does not cover: whether the request fits (the panels' overLimit, SkyStudioSpendStore.decide) or the limit's value.
// Sheets don't inherit the app's language: the panels are presented with `.appLanguage()`, the popover adds its own.

struct DailyCreditLimitNote: View {
    let needed: Double
    @ObservedObject var spend: SkyStudioSpendStore
    @Environment(\.locale) private var locale
    @State private var changing = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let numbers = SkyCutDailyLimit.Numbers(limit: spend.dailyLimit, spent: spend.spentToday(), needed: needed)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: SkyCutDailyLimit.userLine(numbers, localized: L10n, locale: locale))
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Change Limit…") { changing = true }
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("daily-limit-change")
                .instantHelp("Change SkyCut's daily limit for AI here; it is the same setting as in Settings")
                .popover(isPresented: $changing, arrowEdge: .bottom) {
                    DailyCreditLimitEditor().appLanguage()
                }
        }
    }
}

/// The popover: the Settings row itself (committed on Return and when the popover closes), and where the same setting lives.
private struct DailyCreditLimitEditor: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 8) {
            SkyStudioCreditLimitRow()
            Text(verbatim: String(format: L10n("The same setting as in %@."), SkyCutDailyLimit.settingsPath(L10n)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360)
    }
}
