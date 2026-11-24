import SwiftUI

// MARK: - A paid panel's line when SkyCut's daily credit limit stops it
//
// What it covers (MSG1, 2026-11-24): which limit stops the request (SkyCut's own setting, not the Sky Studio balance), the numbers,
// where to change it, and a button that opens Settings at the Sky Studio pane, where the limit's row is. Upscale, Design a Voice and
// Change Voice show it above their buttons, in place of the "Spent today" line, while the quote is over the limit. The words are
// SkyCutDailyLimit.userLine (the same numbers and path the AI is given).
// What it does not cover: whether the request fits (the panels' overLimit, SkyStudioSpendStore.decide) or the limit's value.
// Sheets don't inherit the app's language: the panels are presented with `.appLanguage()`, and the line is read with L10n.

struct DailyCreditLimitNote: View {
    let needed: Double
    @ObservedObject var spend: SkyStudioSpendStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let numbers = SkyCutDailyLimit.Numbers(limit: spend.dailyLimit, spent: spend.spentToday(), needed: needed)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: SkyCutDailyLimit.userLine(numbers, localized: L10n))
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Change Limit…") { SettingsNavigator.shared.show(.skyStudio, open: openSettings) }
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("daily-limit-open-settings")
                .instantHelp("Open Settings at Sky Studio, where the daily limit for AI is set")
        }
    }
}
