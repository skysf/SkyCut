# 2026-11-17 Static screen recordings reported as frozen pictures

## Symptom

An exported native screen recording showing an unchanged screen for six seconds appeared as
`frozen_picture` in `inspect_video`. Stills were exempt, but recordings of static screens were not.

## Root cause

The frame-scan adapter only recognized `isStillImage`. Native recording import discarded its
screen-capture provenance, so after saving there was no durable way to distinguish it from a camera shot.

## Fix

Native recording import and recovery set `EditClip.isScreenRecording`, with missing keys decoding
as false. The frame scan excludes a frozen run when every intersecting picture is a still or a known
screen recording. Other picture checks remain active. Project format v35 protects this provenance and
intentional review decisions from being discarded by older writers.

The delivery report and review contracts are in [finished video inspection](../architecture/finished-video-inspection.md).

## Verification

`DeliveryChecks` uses the actual frame scanner on a synthetic movie containing a seven-second static
run and a flash. The static run is absent for a screen-recording clip while the flash remains.
It checks the provenance's Codable round trip; the existing camera-film test still requires the freeze.
Reverse verification removed only the screen-recording exemption: the production scan assertion failed (one failure in nine assertions). Removing both native provenance assignments also failed the import/recovery wiring guard. Both controls were restored.

## Lessons

An unchanged image is a suspect only when movement is expected. Preserve known capture provenance
rather than inferring it from a filename or dropping every freeze check for a whole project.
