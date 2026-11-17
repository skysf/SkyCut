# 2026-11-17 Every made sound effect reported a fake gain_limits adjustment

## Symptom

A South Pole trailer team (A, 2026-11-13, feedback MCP-15): `add_clips` with `sound_effect` and `volume_db: -8` returned an
adjustment `{"parameter": "sound_effect", "reason": "gain_limits", "requested": {"preset": …, "volume_db": -8}, "applied":
{"volume_db": -7.999999999999999}}`. Exact values (-4, -3, -2) got one too; all seven effects had one. `edit_clips` with the same
`volume_db` did not. The guide tells the AI to read `adjustments` to see what was clamped, so a real clamp could no longer be told
apart.

Reproduced on main `97ca7431` with real App objects (`checks/ParameterLimits/AddClipsChecks.swift`): `volume_db` -8, -4, -3, -2
and 0 each returned the `gain_limits` adjustment; +20 returned it with `applied` 6.020599913279624.

## Root cause

`AIParameterReport.clip` compares each requested field with the value read back from the timeline. For a made sound the request
is the whole `sound_effect` object (`preset`, `duration`, `volume_db`…), while the applied value only holds `volume_db`. Objects
match only when every requested key is in the applied one, so `preset` alone made every made sound a mismatch, whatever the gain.

The `-7.999999999999999` was a red herring: the gain is stored linear and the dB round trip leaves float noise, but the comparison
already tolerated it (relative 1e-9). It only made the fake adjustment look like a clamp.

## Fix

`Sources/SrtFlow/AIParameterReport.swift`:

- `comparable`: of a `sound_effect` entry only `volume_db` is a clip value and only it is compared (`preset`, `duration`… shape
  the file, not the clip).
- `decibelTolerance` (0.001 dB): a requested and an applied dB value closer than that are the same; only a real limit is an
  adjustment (`gain_limits` for +20, which is clamped to the linear maximum).
- `decibels`: dB values are reported without the round trip's noise (-8.000000000000002 → -8): snapped to 0.01 only when within
  1e-9 of it. A real value is not rounded: the clamp at the linear maximum stays 6.020599913279624. The brief asked for "numbers
  rounded to 2 decimals"; that would have turned the limit into another number, which the 2026-11-02 rule forbids
  ([MCP edit parameters](../architecture/mcp-edit-parameters.md): "不能把 dB 四舍五入成另一个限制"), so only the noise goes.
- The same cleaning where the AI reads dB elsewhere: `get_timeline`'s clip `volume_db`, the track faders
  (`AITrackSettings.decibels`) and `set_track`'s `volume_db`.

## Verification

- Real App objects (`AddClipsChecks.cleanGain`): `volume_db` -8, -4, -3, -2, 0 → `adjustments` empty, `applied.sound_effect.volume_db`
  exactly the value asked for; +20 → exactly one adjustment, `gain_limits`, applied `AudioGain.maximumDB`.
- Pure (`checks/MCP/ParameterLimitChecks.swift`, `soundEffectGainChecks`): the same for -8 … +20 and -70, only `volume_db` of the
  entry is compared, the noise is cleaned, the limit is never rounded, faders read back clean. The existing checks that the
  applied gain is read from the model (not the request, not rounded to one decimal) still pass.
- Reverse: on main the real-App scenario was red for all five values. Comparing the whole object again turned 14 pure checks red;
  dropping the noise cleaning turned 1 red ("-8.000000000000002, expected -8.0"). Restored and green.

## Lessons

- When a report compares a request with what was applied, compare only the fields that map to applied values; a nested request
  object with extra fields is not "the same parameter".
- Tell noise from rounding: cleaning a float round trip is safe, rounding a real value is not (it can turn a limit into another
  limit).
