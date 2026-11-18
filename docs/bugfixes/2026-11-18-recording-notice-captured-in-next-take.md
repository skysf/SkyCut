# 2026-11-18 The last recording's result notice is recorded into the next take

## Symptom

B07 (2026-11-11, production feedback UI-2): recording SkyCut's own window for a lesson, take after take. The result notice of
the previous take ("Recording saved…") stayed on screen into the next take and covered the preview playback that take was
meant to show; the tester had to close it by hand before every re-take.

## Root cause

Since 2026-11-06 the result notice (`ScreenRecordingNotice`, mounted at the top of the main window and every project window)
stays until the user closes it — on purpose, so a background project's result is never missed. Nothing took it off screen when
the next take started: its visibility depended only on the list of results, not on whether a take was being captured. The
capture filter only leaves out the floating Stop panel; a notice inside the recorded window is part of that window.

## Fix

The notice is a projection of the recording state too: `ScreenRecordingNotice.isHidden(during:)` keeps all result notices off
screen from picking the source until the take is saved (`choosingSource` … `importing`). They are hidden, not dismissed: when
the take ends they come back with the new result on top, so "close the newest, the earlier one is still there" holds. The setup
sheet (`.configuring`), a take waiting for a decision (`.partialRecovery`, whose notice holds the Add / Keep buttons) and the
resting states keep them on screen. The switch lists every state, so a new state has to choose.

## Verification

- `scripts/check-screen-recording-feedback.sh` (`checks/ScreenRecordingFeedback/NoticeVisibility.swift`): drives the real
  coordinator through a take with an earlier result published and lays out the real `ScreenRecordingNotice` off screen at
  every state — present while idle and configuring, zero height from `choosingSource` to `finishing` and while importing,
  back for a pending decision and after the take, with the same number of results. No capture, no window.
- `checks/screen-recording-ai-wiring.sh` section 16 pins the body's condition and that the coordinator never dismisses notices.
- Reverse verification: with the condition removed from the body, 10 of 81 feedback checks fail (every capture state and the
  import) and the wiring guard fails; restored, 81 pass.
- Not automated: a real take of SkyCut's own window with a notice up; added to the manual regression list of the
  [screen recording lifecycle](../architecture/screen-recording-lifecycle.md).

## Lessons

"Stays until the user closes it" and "never shows up in a recording" are both contracts of the same view; a persistent banner
inside a window that can be recorded needs a capture-time rule. Keep it a projection of the coordinator's state, as the setup
sheet is, rather than a second flag.
