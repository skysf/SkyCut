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

- Classic before (this branch's Part A commit `ad74a70c`, before any Part B commit, with one access line added only for
  rendering) and after (`72e5e2bd`, `8b66d79a`, `a1898af9` and the review round), rendered off-screen with an always-key
  window in system light and dark: the toolbar group, the flip row, both subtitle lists (selected, current and both), the
  timeline (a selected clip and shape, the selected transition cap), the library cards and the over-video marks are
  **pixel-identical**; only the workbench buttons differ (the Subtitles button's new chip).
- `scripts/check-app-theme.sh` measures on vs off on the palette's values: the old Forest pair fails (mark ΔE 13.4, area 0).
  Reverse-verified: the old look put back into the palette turns 4 cases red; the selected row without its outline, a
  Forest highlight equal to the macOS accent and a changed Classic chip each turn one red.
- `checks/app-theme-wiring.sh`: a raw button toggle, `Color.accentColor` in a view, the Subtitles button without its chip,
  the white shape outline, the cue row's old fill and the shared look's off colour swapped each turn it red.
- Not reachable by any check: a real window, Classic's teal on tint, the system's own accent. Manual items in
  [界面主题](../architecture/app-themes.md) "On / off at a glance".

## Review round 1

The first review found what the first pictures (four lines, no dark content) couldn't show, all in Forest's new look:

- The chip's padding came out of the numbers' fixed columns: from #10 the edit page's numbers wrapped, from 256 the Burn In
  table's truncated. Now the chip is drawn around the text and both columns fit the list's largest number
  (`SubtitleIndexColumn`; this also ends the edit page's older wrap from #100 on, in both themes).
- A counted ToggleStyle body and a counted modifier would have raised the preview-perf counts the bench gates on: the
  marks are now plain functions and `makeBody` counts nothing, so the bench's paths count what they counted before.
- VoiceOver read an image plus an unnamed switch per toggle (the accessibility representation): now one named toggle
  button with its value and the chip's frame.
- White marks over a bright picture were nearly invisible (1.07 : 1 on near-white); now they sit in a dark casing (also the
  clip transform box in Forest). The selected transition cap, a selected card on a dark thumbnail and a selected dark shape
  now carry the chip or a light inner line.
- get_status answered "up to date" after a newer release's download failed: it now stays `available`, with the reason and
  SkyCut's own retry in the hint, quoting the App's buttons in its language.

## Lessons

- A state that is only a colour needs a measured difference, and a regression sample of the colours that failed.
- `Color.accentColor` is the system's, whatever the theme root says: theme colours come from the palette only.
- Offscreen pictures show SwiftUI's drawing truthfully but AppKit's controls as inactive: judge AppKit's states in a real
  window. Rules: [界面主题](../architecture/app-themes.md) "On / off at a glance".
- Test a look on the content it will meet: ten-plus lines and four-digit numbers, white and black pictures, dark
  thumbnails and shapes. A new counted body on a bench path changes the ratchet's exact counts.
