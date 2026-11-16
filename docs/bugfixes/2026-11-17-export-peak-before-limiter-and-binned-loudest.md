# 2026-11-17 get_job said the film peaked at +5.6 dBFS; listen put an 80 s track's loudest moment in the middle of a 5 s step

## Symptom

Found by a session walking the editing knowledge cards in SkyCut 0.18.66 over MCP (walkthrough to-dos 6 and 7):

- With the master and the music pushed +6 dB, `export_video preset=quick_review` then `get_job` returned
  `"audio_peak_dbfs":5.6`, `"audio_limited_seconds":0.4`, `"audio_max_reduction_db":6.7` — while `listen file=<that export>` read
  `peak_db` −0.5. A peak of +5.6 dBFS reads like a clipped file; the AI had no number for what was actually delivered.
- `listen clip_id=<an 80 s library track>` returned `"curve":{"step":5,…}`, `"loudest_at":27.5`: the middle of the 25–30 s curve
  step. Narrower listens put the loudest moment elsewhere, and card 601 ("peak on the peak": slide the music so its hit lands on
  the video's peak) computes `source_in` from `loudest_at`.
- Underneath both: every "peak" SkyCut reported was a sample peak, though the limiter was documented as a true-peak limiter. A peak
  between samples can be 3 dB above every sample (a 12 kHz tone read 45° off its crest), and the AAC encoder reproduces it.

## Root cause

1. `AIExportTools.finishedDetail` reported `Levels.peakDBFS` = the limiter's *input* peak. The limiter's output peak (`outputPeak`)
   was measured but only shown in the export panel, and nobody measured the encoded file — so the only peak the AI saw was the one
   the limiter had just removed.
2. `AIAudioLevels.loudest(curve)` returned the middle of the loudest curve step. The curve has at most 40 points, so its step grows
   with the clip (0.5 s for 3 s, 5 s for 80 s); the "loudest moment" was never finer than that step.
3. `ExportPeakLimiter` computed each frame's requirement from its samples (`max |x|`), and the waveform listen reads from keeps
   bucket minima / maxima. Neither sees between samples, so neither could report a true peak.

## Fix

- `TruePeak` (new, pure): ITU-R BS.1770-4 Annex 2 — 4× oversampling with the Recommendation's 48-tap filter, absolute values; a
  sample's span = its own magnitude and the four points after it; spans are bit-identical however the stream is chunked.
- `ExportPeakLimiter` limits on that scale (a frame's samples and the points on both sides; +6 frames latency), so the ceiling is
  −1 dBTP and every reported peak is one measure: the limiter's input peak, the f32's peak (`FrameSink` meters what it writes),
  each frame and layer of `listen mix=true` (`MixBusMeter`, `MixBandMeter`).
- `ExportDeliveredPeak` (new): after ffmpeg, `VideoEditExporter` decodes the exported file (the decode listen uses,
  `AudioDecodeSettings`) and stores its true peak in `Levels.deliveredPeak`. `ExportAudioReport` (new) writes get_job's sound:
  `audio_peak_dbtp` = that delivered peak; the limiter's work only when it worked, under its own names
  (`audio_peak_before_limiter_dbtp`, `audio_limited_seconds`, `audio_max_reduction_db`, `note`). `audio_peak_dbfs` is gone. The
  export panel shows the delivered true peak in dBTP.
- `listen` for a clip or a file reads exactly its window once (`AIListenAudioWindow`, also for whole files and the timeline
  listing) and measures each project frame there (`AIListenFrameGrid` → `AIListenSampleFrames` → `AIListenPeaks`): `peak_db` is the
  heard true peak, `loudest_at` the start of the loudest frame, `peak_at` when the true peak is. `AIAudioLevels.loudest` is gone.

## Verification

- Pure values: `check-audio-fade` group 10c (the meter on sines 100 Hz–20 kHz at 24 phases within −0.4 … +0.25 dB; the limiter
  holds a 12 kHz 45° tone, 19 kHz, white noise ×8 and a spike at −1 dBTP within 0.01 dB; a crest that only exists between samples is
  pulled down). `check-mcp` `ListenPeakChecks`: an 80 s bed with a 40 ms hit at 41.3 s reports `loudest_at` 41.292 (the hit's frame
  at 24 fps), a 12 kHz tone 45° off its crest reports its crest, a clip's gains and double speed pick the right frame on the timeline,
  a window cut mid-wave reads no edge overshoot.
- Real paths: `check-audio-fade` 10b exports a mix two tracks +6 dB hot through `plan()` + ffmpeg: the f32's true peak ≤ −1 dBTP and
  equals the reported `outputPeak`; the delivered peak (AVFoundation decode) equals ffmpeg's decode within 0.1 dB and sits far under
  the pre-limiter peak. `check-mix-layers` 2a: whole-timeline measurement = export, bit for bit, and get_job's fields from those
  levels. `ListenRangeChecks`: a whole-file listen is one bounded reader from 0 and asks for no shared waveform.
- Reverse verification: see the table below (each broken on purpose, run, restored).

| Broken on purpose | What went red |
| --- | --- |
| The limiter's requirement back to the samples alone (`span.sample`) | `check-audio-fade` 10c: the 12 kHz 45° tone comes out at +2.1 dBTP, 19 kHz at −0.83, white noise ×8 at +3.7, the crest between samples stays over; 10b: the real export's f32 at −0.99 dBTP; `check-mix-layers` 2b (pressed frames over −1 dBTP); `checks/export-audio-single-pipeline.sh` |
| get_job's peak back to the pre-limiter one (`audio_peak_dbfs = peakDBTP`) | `check-mix-layers` 2a: `audio_peak_dbtp` missing, `audio_peak_dbfs` present (2 lines); `checks/export-audio-single-pipeline.sh` |
| `loudest_at` back to the middle of the loudest curve step | `check-mcp` ListenChecks: "loudest_at is the measured frame start" (got 0.25, the step's middle, for 0.167) |

All restored, all green again.

## Lessons

- A number handed to an AI needs its measure in its name and must be the thing it will be judged against: "peak" after an export
  means what the file holds, so measure the file; what the limiter did is a separate fact under its own name.
- A "loudest moment" read off a display curve inherits the curve's step. Anything reported "at" a time should come from data at the
  resolution it claims (here: the project frame).
- The long-term rules are in [the export's sound](../architecture/export-audio-mixdown.md) section 2 item 3 (true peak, delivered
  peak) and [the AI interface](../architecture/ai-control-mcp.md) section 4 item 13 (listen reads its window once per call).
