# 2026-11-17 Source description needed the reader and model contracts at its adapters

## Symptom

During integration of `listen describe=true`, describing a whole video clip could reject an audio track that ended just
before the picture, despite ordinary listen already accepting it. A model removed after language screening could cause
the supposedly read-only word check to download it. Cancellation during word recognition could still publish success.

## Root cause

The prepared description branch preceded PR 1's distinction between exact named ranges and a clip's actual sound edges.
Passing explicit start/end values without `edges` selected exact coverage. The speech adapter called `ensureModel`, whose
installation fallback remains appropriate for subtitle generation but violates description's installed-only rule. The
description checked its stop flag before word recognition but had no check after that final asynchronous stage.

## Fix

Keep both `edges` and `keepsSamples` through `AIListenAudioWindow`. Clip and whole-file description use sound edges; named
file ranges stay exact. Retained mono samples and report windows share the first sample's real `sourceStart`.

`SpeechTranscriptionService.reserveInstalledModel` reserves a locale, verifies it is still installed, and releases before
failure; it cannot request installation. `AIListenSourceWords` releases successful leases on both transcription outcomes.
The job checks cancellation again after recognizing words. The existing download-capable subtitle path is unchanged.

The lasting contracts are in [the listening engine](../architecture/listening-engine.md), section 2 item 4a.

## Verification

The real reader checks use synthetic float PCM with different left/right patterns and audit the measured call itself:
one bounded read, exact mono averaging and source timing, and no sample retention for ordinary reads. Existing native
edit-list fixtures also retain samples with sound shorter than the picture or starting late. The source report checks
cover windows, traits, label scores/caps and the 120-character recognition quote budget; the native classifier has its own check.

Reverse wiring verification: substituting `ensureModel` for installed-only reservation, forcing exact edges on a clip, or
removing the final cancellation check each made `checks/MCP/listen-wiring.sh` exit 1 with the corresponding assertion.
Every mutation was restored. Real speech recognition and user-driven model removal are not exercised by these checks.

Implementation reverse checks also ran the normal compiled suites: raising the label cap from 5 to 8 and the recognition
quote cap from 120 to 200 produced two failures out of 213 mix-layer checks. Summing stereo channels without averaging
produced one failure out of 8,367 MCP checks (maximum sample error 0.3046875). Both implementations were restored.

## Lessons

An installed-language lookup is a snapshot, not a guarantee that a later download-capable helper will remain read-only.
Enforce that policy at the model-reservation boundary. Preserve source-time and coverage contracts when adding another
consumer to a shared reader, and check cancellation after the final asynchronous stage before publishing success.
