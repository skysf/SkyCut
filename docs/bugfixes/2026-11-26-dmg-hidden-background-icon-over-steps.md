# 2026-11-26 With hidden files shown, the DMG's background folder sat over the install steps

## Symptom

In the real-mount check of the simpler install window (PR #558, 2026-11-26), the test DMG's Finder window said "3 items":
besides `SkyCut.app` and the Applications link, a dimmed folder icon covered the start of the video guide line (the new
step 2). The folder was the volume's hidden `.background`. This Mac's Finder was showing hidden files at the time (Finder's
own toggle; `AppleShowAllFiles` is not in its preferences); on 2026-11-20 the same check on the same Mac said "2 items".
Anyone whose Finder shows hidden files saw it, also on the shipped 0.18.67 DMG, where the icon lands on the taller
window's steps.

## Root cause

- The Finder template (`scripts/dmg/make-layout.py` → `packaging/dmg/DS_Store`) gave positions only to `SkyCut.app` and
  `Applications`. The volume root also holds `.background/` (the artwork) and `.DS_Store`.
- Finder never shows `.DS_Store`. A Finder that shows hidden files does show `.background`, and with no recorded position
  it puts the icon on the first free spot: the left column under the arrow, over the steps.
- `scripts/dmg/check-layout.py` only looked at the two named icons, and the real-mount checklist never asked for a look with
  hidden files shown, so the default look ("2 items") was all anyone checked.

## Fix

- `make-layout.py` gives `.background` a position below the canvas, (380, 800). In the 598 pt window its icon's top (736)
  is out of sight even when hidden files are shown (the window then scrolls); default Finder settings don't show it at all.
- `check-layout.py` requires the seventh record and asserts the folder's icon top (centre y − 64) is below the window
  height it reads from `WindowBounds`, so growing the canvas without moving the folder goes red.
- The build doc ("DMG 安装窗口") names the folder in its "grow together" rule, and its checklist asks for one look with
  hidden files shown and one with them hidden ("2 items").

## Verification

- Real mount on this Mac with hidden files shown (a scratch copy with its own volume name, because another "SkyCut" volume
  was mounted): before the fix the folder's icon covered step 2; after it, nothing covers the steps ("3 items", the folder
  out of sight). Screenshots: the second is the picture the user approves.
- Guard, reverse-verified: the new `check-layout.py` on the old template is red ("expected exactly seven layout
  records"); a template whose window grew back to 776 pt (the 688 pt canvas) with the folder left at 800 is red
  (".background's icon top (736) is inside the 776 pt window"); the real template is green.
- Not seen yet: the new window with hidden files hidden. That is the user's look, checklist item 2.

## Lessons

- A DMG's Finder template must place every item in the volume root, hidden ones too: a Finder that shows hidden files lays
  out whatever has no position by itself, and it picks the free space the artwork uses for its text.
- Look at the install window once with hidden files shown. The rule lives in
  [构建与打包](../build/build-and-packaging.md) "DMG 安装窗口".
