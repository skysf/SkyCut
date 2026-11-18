# 2026-11-18 Clip listen meters raw peaks with a frame midpoint gain

## Symptom

A 24 fps, 48 kHz clip with a 0.8 impulse in its first sample and silence in the other 1,999 samples has a full-length
fade-in. The real listen entry reports -8 dBTP and a peak time even though the engine's gain is zero at the only nonzero
sample. Short transients during fades or fast automation can also select the wrong peak / loudest frame.

## Root cause

AIListenFrameGrid supplied one midpoint gain per frame. AIListenSampleFrames interpolated and measured raw PCM first;
AIListenPeaks multiplied those already reduced statistics by the midpoint gain. Multiplication after measuring cannot
recover the peak or energy of time-varying gained PCM. AIAudioLevels separately approximated gain at each coarse window.

## Fix

AIListenSampleGain reuses AudioGainRamps and GainTable.Sampler at each source sample's mapped timeline time, including the
track fader. AIListenAudioWindow applies that envelope after PTS trimming and before all accumulators. Clip levels, curve,
true peak and loudest frame now share the same gained samples; their statistics are only mapped to timeline seconds.
AIListenPeaks no longer accepts post-measurement gains. File reads retain their raw samples and the single bounded read,
cancellation and deadline lifecycle remain in place.

## Verification

- Reproduced on main 8a16cccb using actual statistics and the engine's sampler: -7.958800044 dBTP versus entirely zero
  gained samples. The real AIListenTool entry on a synthetic CAF also reports peak_db -8, level_db -41 and peak_at 0.
- ListenGainChecks calls the real tool on a registered isolated project: the faded impulse is silent without peak/loudest
  times; constant PCM with clip / track gain verifies each gain is applied once; raw file listen retains its source peak.
  The task-local read audit requires one bounded reader and no waveform read, and the project / undo / rebuild stay unchanged.
- ListenSampleGainChecks covers fade-in, fade-out, fast curves, stereo, trim, double speed and irregular decoded chunks,
  comparing the resulting PCM / measurements with the engine's actual gain table.
- Reverse verification removes the clip reader's sample gain while keeping the new regression. The real-entry silent-peak,
  level, times and constant-gain assertions turn red (187 assertions, five failures); the fix is restored before positive checks.
- Run scripts/check-local.sh parameter-limits mcp. Fixtures are synthetic; no sound device, installed App or cloud is used.
  This checks the clip envelope adaptation, not a new offline resampling or effects implementation.

## Lessons

Apply a varying envelope before peak interpolation and energy accumulation. Never multiply a raw frame maximum by a
representative gain and call it the heard peak. The lasting contract is in [the AI interface](../architecture/ai-control-mcp.md)
item 13 and [export audio](../architecture/export-audio-mixdown.md).
