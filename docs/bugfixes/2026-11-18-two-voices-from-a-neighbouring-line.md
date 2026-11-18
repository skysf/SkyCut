# 2026-11-18 A narration line next to another one on a second track is called "two voices"

## Symptom

`listen voice=…` (and, from 2026-11-18, the delivery report's voice check) marked two perfectly clear narration lines
`two_voices`. Found while running the new second-tier delivery checks on the South Pole second draft rebuilt as a project:
"your own car, still a box." (11.45–13.36 s) and "Even the elevator is a box." (13.30–14.76 s) sat on two audio tracks because
they overlap by 60 ms; both came back `two_voices` with ESTOI 0.85 and 0.78. The same happens without any overlap whenever the
next line on another voice track starts within 0.2 s of this one ending — the checkerboard of A1 / A2 that set_transition
sound produces is exactly that.

## Root cause

A line counts as two voices when another voice layer's level in the line's window reaches −45 dBFS
(`AIListenVoiceReport.line`). That window is the line padded by `VoiceLines.margin` (0.2 s) on each side — the padding exists
for ESTOI — so a neighbouring line on another track that only reaches into the padding raises the other layer's level over the
whole window above −45 dBFS (a −20 dBFS voice for 0.25 s of a 2 s window is about −29 dBFS). Nothing asked whether the two
voices actually speak at the same time. The preview board the check was taken from has that question: two voice stretches
overlapping for at least 0.5 s (`overlap_s`).

## Fix

A second voice must also overlap the line itself (without padding) for at least `VoiceClarity.overlapSeconds` (0.5 s, the
board's line): `AIListenVoicePlan.Layer.voiceOverlap` sums how long that layer's voice clips sound inside the line, and
`AIListenVoiceReport` asks for both the level and the overlap. Two voices really talking over each other are still
`two_voices`; a hand-over between tracks is judged by ESTOI like any other line.

## Verification

- `scripts/check-mix-layers.sh` group 3: a new case puts the next line on A2 0.05 s into the end of A1's second line; all three
  lines are judged by ESTOI (none `two_voices`), and the existing case of two voices speaking at once is still `two_voices`.
  Reverse check: with the overlap condition removed the new case fails (two of the three lines come back `two_voices`); restored.
- On the rebuilt South Pole second draft (local only, not in the repo) the two lines are no longer `two_voices`; the last line
  stays `may_be_hard`.

## Lessons

- A window padded for one measurement (ESTOI needs context) is the wrong window for a different question (is someone else
  talking now). Ask each question over its own span.
- The rule lives in [the listening engine](../architecture/listening-engine.md) section 2 item 3a.
