import SwiftUI

// MARK: - On / off, current and selected: the marks that tell states apart at a glance
//
// What it does: the one look for an icon toggle's on / off state, the text of a current or selected line or card, the chip
// behind the workbench's shown panels, and the dark casing that keeps white marks readable over the video. Forest (look A,
// the user's pick on 2026-11-27): on = the icon in the accent on the light green chip, off = the icon in the secondary grey
// with no chip; current / selected text = the accent on the same chip. Classic: exactly what each control drew before
// (AppKit's button toggle with the control's own tint, the macOS accent for the text); the workbench chip is the one
// Classic always had; Classic draws no casing.
// Count-neutral by construction (preview-perf-ratchet.md): plain functions, no ViewModifier types, and the toggle style's
// makeBody counts nothing, so the bench's paths record exactly what they recorded before (review FBG1, G1).
// What it doesn't: what the toggles do (their bindings) or the colours themselves (AppThemePalette).
// Rules: docs/architecture/app-themes.md "On / off at a glance". checks/app-theme-wiring.sh keeps raw button toggles,
// on-state tints and the macOS accent out of the views; scripts/check-app-theme.sh measures the colours, the numbers'
// widths and what VoiceOver gets.

/// Forest's icon toggle. The padding is there whether on or off, so turning it on never moves anything; the label is at least
/// 18 x 16 pt, so the chip (and the click target, which is the chip) is never smaller than 24 x 20 pt. VoiceOver gets the plain
/// button SwiftUI makes of a toggle style: one "toggle button" with its on / off value and the chip's frame; the control
/// gives the name (`.accessibilityLabel`).
struct ForestStateToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // No PerfCounters here on purpose: makeBody re-runs on every evaluation of the view holding the toggle (G1).
        let palette = AppThemePalette.current
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .frame(minWidth: 18, minHeight: 16)
                .foregroundStyle(configuration.isOn ? palette.accent : palette.secondaryText)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background {
                    if configuration.isOn { RoundedRectangle(cornerRadius: 5).fill(palette.onChip) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// An icon toggle's on / off look (on a `Toggle`). `classicTint`: the tint the control had in Classic (nil: none).
    @MainActor
    @ViewBuilder
    func stateToggle(classicTint: Color?) -> some View {
        if AppThemePalette.current.isForest {
            toggleStyle(ForestStateToggleStyle())
        } else if let classicTint {
            toggleStyle(.button).buttonStyle(.borderless).tint(classicTint)
        } else {
            toggleStyle(.button).buttonStyle(.borderless)
        }
    }

    /// The text of a current or selected thing (the current subtitle line and its number, a selected card's title).
    /// Forest: the accent on the on chip, drawn **around** the text (it takes no width from it: a number never wraps or
    /// truncates for it, review FBG1 U1). Classic: the macOS accent as before. `normal`: the colour when not marked.
    @MainActor
    @ViewBuilder
    func chipText(_ marked: Bool, normal: Color, semibold: Bool) -> some View {
        let palette = AppThemePalette.current
        if palette.isForest {
            fontWeight(semibold && marked ? .semibold : nil)
                .foregroundStyle(marked ? palette.accent : normal)
                .background {
                    if marked {
                        RoundedRectangle(cornerRadius: 4).fill(palette.onChip)
                            .padding(.horizontal, -SubtitleIndexColumn.chipOutset)
                    }
                }
        } else if semibold {
            // Classic: exactly what CurrentCueHighlight drew.
            fontWeight(marked ? .semibold : .regular).foregroundStyle(marked ? palette.highlight : normal)
        } else {
            // Classic: exactly what the cue index and the card titles drew.
            foregroundStyle(marked ? palette.highlight : normal)
        }
    }

    /// A workbench panel button's label (Library, Subtitles): the on chip behind it while its panel shows.
    @MainActor
    func workbenchChip(isOn: Bool) -> some View {
        padding(5)
            .background {
                if isOn { RoundedRectangle(cornerRadius: 5).fill(AppThemePalette.current.onChip) }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Over the video in Forest, a white line or handle gets a dark casing 1 pt beyond each side, so it reads on a white
    /// picture and on a black one (review FBG1 U2). `shape` is filled under it (lines, handles). Classic: nothing.
    @MainActor
    @ViewBuilder
    func overVideoCasing<S: Shape>(_ shape: S) -> some View {
        if let casing = AppThemePalette.current.overVideoCasing {
            background { shape.fill(casing).padding(-1) }
        } else {
            self
        }
    }

    /// The same for an outline drawn with `strokeBorder(lineWidth:)`: a dark band from 1 pt outside to 1 pt inside it.
    @MainActor
    @ViewBuilder
    func overVideoOutlineCasing<S: InsettableShape>(_ shape: S, lineWidth: CGFloat) -> some View {
        if let casing = AppThemePalette.current.overVideoCasing {
            background { shape.strokeBorder(casing, lineWidth: lineWidth + 2).padding(-1) }
        } else {
            self
        }
    }
}
