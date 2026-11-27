# 2026-11-27 Forest: on and off look the same, the current line is the macOS accent

## Symptom

In the Forest theme (the default) the timeline toolbar's four toggles (magnet, snapping, linkage, follow playhead) looked
the same on and off; the user, 2026-11-27: 「这几个button，到底是选中了，还是没有，UI没有反应，都是一个样子」. So did the
inspector's Flip horizontal / vertical and both subtitle lists' "follow playback" toggles. The current subtitle line and a
selected row in the edit page's subtitle list were drawn in the macOS accent colour — yellow on the user's Mac, pale on the
warm panel — not in Forest green; the same accent marked selected filter / transition cards, the selected transition cap,
drop targets, the text frame box over the video and the Burn In margin guides. A selected light shape block on the timeline
was outlined in white, invisible on its white block. The workbench's Subtitles list button showed no on state at all, in
either theme, while the Library button next to it had a chip.

## Root cause

- The toggles were `.toggleStyle(.button)` + `.buttonStyle(.borderless)`: "on" only tints the icon. Forest's tint is its
  accent #123F32 and the theme root's foreground is #19221D: 1.38 : 1 (CIEDE2000 13.4), the same dark green-black. Classic
  tints teal against the label colour, which shows. `app-themes.md` said "colour shows the toggle state", but no check
  compared on with off.
- `Color.accentColor` is the macOS accent. The theme root's `.accentColor(palette.accent)` and `.tint(...)` reach native
  controls, not `Color.accentColor`, so every view that named it drew the system accent in Forest.
- The shape block's selection outline was a hard-coded `.white`, unlike the clip / text / filter blocks' `selectionStroke`.
- Offscreen renders can't judge AppKit's toggles: in a window of an app that isn't active, AppKit draws them inactive, so
  on and off look alike in both themes (phase-1 renders). Classic's teal "on" needs a real window.

## Fix

- One shared look (`Sources/SrtFlow/StateMarks.swift`), the user's pick "A, light chip": in Forest an icon toggle is the
  accent icon on the light green chip `onChip` #CFE0C8 when on and the secondary grey #676D62 with no chip when off
  (`ForestStateToggleStyle`, VoiceOver keeps a toggle); the current line is the accent on the same chip. Classic gets
  exactly the old modifiers (`.stateToggle(classicTint:)`, `.currentLine(_:normal:semibold:)`).
- The workbench's Library and Subtitles buttons share `.workbenchChip(isOn:)` (the one Classic change the user approved).
- `AppThemePalette` names every state colour: `onChip`, `highlight`, `rowSelectionFill` / `rowSelectionStroke`,
  `overVideo` / `overVideoGlow` / `overVideoHollow` / `overVideoLabel`. Their Classic values are what the views drew before
  (`Color.accentColor` itself, named only in the palette); Forest uses its own colours, white with the clip transform box's
  dark glow over the video. A selected cue row is outlined in Forest (a light fill would melt into the current chip).
- The selected shape block uses `selectionStroke` (Classic: white, as before).

## Verification

- Classic before (775cef18 + one access line) and after, rendered off-screen with an always-key window in system light and
  dark: the toolbar group, the flip row, both subtitle lists (selected, current and both), the timeline (a selected clip and
  shape, the selected transition cap), the library cards and the over-video marks are **pixel-identical**; only the
  workbench buttons differ (the Subtitles button's new chip). Forest's pictures: `impl-briefs/status/U2-final/` (local).
- `scripts/check-app-theme.sh` measures on vs off on the palette's values: the old Forest pair fails (mark ΔE 13.4, area 0).
  Reverse-verified: the old look put back into the palette turns 4 cases red; the selected row without its outline, a
  Forest highlight equal to the macOS accent and a changed Classic chip each turn one red.
- `checks/app-theme-wiring.sh`: a raw button toggle, `Color.accentColor` in a view, the Subtitles button without its chip,
  the white shape outline, the cue row's old fill and the shared look's off colour swapped each turn it red.
- Not reachable by any check: a real window, Classic's teal on tint, the system's own accent. Manual items in
  [界面主题](../architecture/app-themes.md) "On / off at a glance".

## Lessons

- A state that is only a colour needs a measured difference, and a regression sample of the colours that failed.
- `Color.accentColor` is the system's, whatever the theme root says: theme colours come from the palette only.
- Offscreen pictures show SwiftUI's drawing truthfully but AppKit's controls as inactive: judge AppKit's states in a real
  window. Rules: [界面主题](../architecture/app-themes.md) "On / off at a glance".
