import SwiftUI

// MARK: - On / off, current and selected: the marks that tell states apart at a glance
//
// What it does: the one look for an icon toggle's on / off state, the current subtitle line, and the chip behind the
// workbench's shown panels. Forest (look A, the user's pick on 2026-11-27): on = the icon in the accent on the light green
// chip, off = the icon in the secondary grey with no chip; the current line = the accent on the same chip. Classic: exactly
// what each control drew before (AppKit's button toggle with the control's own tint, the macOS accent for the current line);
// the workbench chip is the one Classic always had.
// What it doesn't: what the toggles do (their bindings) or the colours themselves (AppThemePalette).
// Rules: docs/architecture/app-themes.md "On / off at a glance". checks/app-theme-wiring.sh keeps raw button toggles,
// on-state tints and `Color.accentColor` out of the views; scripts/check-app-theme.sh measures the colours.

/// Forest's icon toggle. The padding is there whether on or off, so turning it on never moves anything.
struct ForestStateToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let _ = PerfCounters.body(Self.self)
        let palette = AppThemePalette.current
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? palette.accent : palette.secondaryText)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background {
                    if configuration.isOn { RoundedRectangle(cornerRadius: 5).fill(palette.onChip) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver keeps a toggle with its on / off value (the drawn control is a plain button). The switch style stops the
        // representation from being styled by this style again.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private struct StateToggleModifier: ViewModifier {
    /// Classic's tint as the control had it (nil: the theme root's tint).
    let classicTint: Color?

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        if AppThemePalette.current.isForest {
            content.toggleStyle(ForestStateToggleStyle())
        } else if let classicTint {
            content.toggleStyle(.button).buttonStyle(.borderless).tint(classicTint)
        } else {
            content.toggleStyle(.button).buttonStyle(.borderless)
        }
    }
}

extension View {
    /// An icon toggle's on / off look (on a `Toggle`). `classicTint`: the tint the control had in Classic (nil: none).
    func stateToggle(classicTint: Color?) -> some View { modifier(StateToggleModifier(classicTint: classicTint)) }

    /// A workbench panel button's label (Library, Subtitles): the on chip behind it while its panel shows.
    @MainActor
    func workbenchChip(isOn: Bool) -> some View {
        padding(5)
            .background {
                if isOn { RoundedRectangle(cornerRadius: 5).fill(AppThemePalette.current.onChip) }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
