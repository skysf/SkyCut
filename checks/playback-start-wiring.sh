#!/bin/bash
# Startup's fast path stays independent of preview rebuilding, proxy work and blocking media reads.
# The graphical benchmark also counts real builds and item attachments around playback.
set -uo pipefail
cd "$(dirname "$0")/.."
clock=Sources/SrtFlow/VideoPreviewView.swift
sync=Sources/SrtFlow/PlaybackStartSync.swift
project=Sources/SrtFlow/VideoEditProject.swift
document=Sources/SrtFlow/VideoEditProjectDocument.swift
engine=Sources/SrtFlow/AudioEngine/TimelineAudioEngine.swift
feeder=Sources/SrtFlow/AudioEngine/AudioTrackFeeder.swift
surface=Sources/SrtFlow/VideoEditPlayheadFollowers.swift
layerHost=Sources/SrtFlow/PlayerViewRepresentable.swift
workflow=.github/workflows/checks.yml
failed=0

fail() {
  echo "✗ Playback start: $*" >&2
  failed=1
}

body() {
  awk -v signature="$2" 'index($0, signature) == 1 { found = 1 } found { print } found && /^    }/ { exit }' "$1"
}

fast_path() {
  local code
  code="$(body "$1" "$2")"
  if [ -z "${code}" ]; then
    fail "Missing scan target $2 in $1"
  elif sed 's,//.*,,' <<<"${code}" | grep -E \
    'scheduleRebuild|CompositionBuilder|optimizedMedia|MediaReadQueue|AV(URLAsset|AudioFile)|File(Manager|Handle)|Data\(contentsOf:|engine\.start\(|(^|[^[:alnum:]_])(startGraph|service|sleep|usleep)\(|\.(sync|wait|settle)\('; then
    fail "$2 in $1 schedules preview work or makes a blocking call"
  fi
}

fast_path "${clock}" '    func togglePlayback('
fast_path "${clock}" '    func play('
fast_path "${clock}" '    private func observeReadiness('
fast_path "${clock}" '    private func recoverAudioIfNeeded('
fast_path "${clock}" '    private func checkVideoDrift('
fast_path "${clock}" '    private func resetDrift('
fast_path "${clock}" '    private func holdForLanding('
fast_path "${clock}" '    private func startClocks('
fast_path "${sync}" '    static func begin('
fast_path "${clock}" '    func goToStart('
fast_path "${clock}" '    func seek(to'
fast_path "${clock}" '    private func positionPreview('
fast_path "${clock}" '    private func preparePositionedPreview('
fast_path "${clock}" '    func pause('
fast_path "${clock}" '    private func holdPausedPicture('
fast_path "${clock}" '    func endPeek('
fast_path "${engine}" '    func play(from'
fast_path "${feeder}" '    func seek(toFrame'

# The two synchronous recovery sites serve a suspended graph or a system-stopped graph.
# An active graph returns without either restart or a wait for the background starter.
recovery="$(body "${engine}" '    func recoverIfNeeded(')"
if ! awk '
  /if run.state == .starting [{] run.settle\(\) [}]/ { handoff = NR }
  /if run.state == .suspended/ { suspended = NR }
  /guard !engine.isRunning else [{] return false [}]/ { running = NR }
  /try startGraph\(engine\)/ { starts[++calls] = NR }
  END { exit !(calls == 2 && handoff && suspended > handoff &&
              starts[1] > suspended && running > starts[1] && starts[2] > running) }
' <<<"${recovery}"; then
  fail "Graph startup must be confined to the suspended and system-stopped recovery paths"
fi

open="$(body "${document}" '    func openProject(')"
if [ "$(grep -cF 'scheduleRebuild(immediately: true)' <<<"${open}")" -ne 1 ]; then
  fail "Opening a document must request its first preview once, without edit debounce"
fi

install="$(body "${project}" '    func scheduleRebuild(')"
if ! awk '
  /clock.attachItem\(item\)/ { attached = NR }
  /audioEngineHost.apply\(/ { audio = NR }
  /clock.seek\(/ { placed = NR }
  /clock.resumeAfterPreviewRebuild\(/ { resumed = NR; calls++ }
  END { exit !(calls == 1 && attached && audio > attached && placed > audio && resumed > placed) }
' <<<"${install}"; then
  fail "Resume Play only after installing the new item and audio source and placing the playhead"
fi

start="$(body "${clock}" '    func play(')"
if ! awk '
  /if audioSource != nil, item.status != .readyToPlay \|\| player.status != .readyToPlay [{]/ { ready = NR }
  /startClocks\(from: start, source: source\)/ { if (!rate) rate = NR }
  END { exit !(ready && rate > ready) }
' <<<"${start}"; then
  fail "The synchronized native start requires both the player and its current item to be ready"
fi
# Both clocks start back to back, the rate observation's subscribers after them; a start that stalled after the picture
# began to move pins the sound to the picture's own start.
if ! body "${clock}" '    private func startClocks(' | awk '
  /startingClocks = true/ { hold = NR }
  /PictureStart.begin\(player, with: source, from: start\)/ { begin = NR }
  /startingClocks = false/ { release = NR }
  /isPlaying = player.rate > 0/ { publish = NR }
  END { exit !(hold && begin > hold && release > begin && publish > release) }
' || ! body "${sync}" '    static func begin(' | awk '
  /player.playImmediately\(atRate: 1\)/ { picture = NR }
  /if let host = stalled\(player.currentItem, from: start\)/ { stalled = NR }
  /source.play\(from: start, alignedToHostTime: host\)/ { pinned = NR }
  /source.play\(from: start\)$/ { sound = NR }
  END { exit !(picture && stalled > picture && pinned > stalled && sound > pinned) }
'; then
  fail "Start the picture, then the sound on the next quantum or pinned to a stalled picture's start"
fi

# Nothing re-seeks the picture under running sound: no start, landing or drift correction uses
# setRate(_:time:atHostTime:), which seeks for any host time but the present and for any explicit time
# (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
if sed 's,//.*,,' "${clock}" | grep -n 'setRate(' >&2; then
  fail "PlayerClock must not call setRate(_:time:atHostTime:): it re-seeks the picture while the sound plays"
fi
drift="$(body "${clock}" '    private func checkVideoDrift(')"
if ! grep -qF 'case .rate(let rate): player.rate = rate' <<<"${drift}" || ! grep -qF 'case .replace: seek(to: audio)' <<<"${drift}"; then
  fail "Drift is corrected by the picture's rate, or by landing both again when too far apart"
fi
# A click while playing holds the sound with the picture; the placement that follows starts both together.
if ! body "${clock}" '    func seek(to' | awk '
  /if source.isPlaying [{]/ { playing = NR }
  /holdForLanding\(\)/ { hold = NR }
  /source.seek\(to: clamped\)/ { sound = NR }
  /positionPreview\(at: target, seconds: clamped\)/ { place = NR }
  /return/ { if (playing && !sound) early = 1 }
  END { exit !(playing && hold > playing && sound > hold && place > sound && !early) }
'; then
  fail "A seek while playing must hold the sound with the picture and land both together"
fi
# On an output that is not rendering (the idle stop) Play holds both until it renders, then starts them; a start that
# stalled inside the call pins the sound to the picture's own start. The engine fills a paused seek before Play.
if ! awk '
  /let cold = !outputStart.ended && !source.isRendering/ { cold = NR }
  /recoverAudioIfNeeded\(source\)/ { if (!recover) recover = NR }
  /^ *if cold [{]$/ { gate = NR }
  /outputStart.begin\(until: [{] \[weak source\] in source\?.isRendering \?\? true [}]\)/ { wait = NR }
  /startClocks\(from: start, source: source\)/ { if (wait && !started) started = NR }
  END { exit !(cold && recover > cold && gate > recover && wait > gate && wait - gate <= 2 && started > wait) }
' <<<"${start}"; then
  fail "After the idle stop Play must wait for the output before starting both"
fi
if ! grep -qF 'if renderer.syncWhilePaused() { feeder.poke() }' "${engine}"; then
  fail "The engine's paused render must take up a paused seek so the feeder fills it before Play"
fi

preroll="$(body "${clock}" '    private func preparePositionedPreview(')"
if ! awk '
  /guard previewSeek == request/ { current = NR }
  /!previewIsUnprimed \|\| playbackRequested/ { requested = NR }
  /guard player.status == .readyToPlay, item.status == .readyToPlay/ { ready = NR }
  /observeReadiness\(of: item\)/ { observe = NR }
  /player.preroll\(atRate: / { pre = NR }
  /self\?\.finishPreviewPosition\(/ { finish = NR }
  END { exit !(current && requested > current && ready > requested && observe > ready && pre > observe && finish > pre) }
' <<<"${preroll}"; then
  fail "Prime a positioned preview on the asynchronous preroll path before releasing Play"
fi
# Priming every installed composition while editing held the preview's playback buffers past the memory ratchet
# (docs/bugfixes/2026-11-19-preview-start-before-preroll.md); Play primes a new item.
if ! body "${clock}" '    func play(' | grep -F 'preparePositionedPreview(request, at: start, seekFinished: true)' >/dev/null; then
  fail "Defer a new item's full preroll until Play requests it"
fi

# The sound never starts ahead of the picture: Play starts the clocks only with a positioned, primed picture, never
# with a native seek (docs/bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md).
if ! awk '
  /guard positionedTime == start, !previewIsUnprimed else [{]/ { gate = NR }
  /preparePositionedPreview\(request, at: start, seekFinished: true\)/ { prime = NR }
  /positionPreview\(at: CMTime\(seconds: start/ { place = NR }
  /startClocks\(from: start, source: source\)/ { if (!first) first = NR }
  gate && /setRate\(/ { seeking = 1 }
  END { exit !(gate && prime > gate && place > gate && first > place && !seeking) }
' <<<"$(sed 's,//.*,,' <<<"${start}")"; then
  fail "Play must place and prime the picture before starting the sound, and never re-seek it while starting"
fi

# A pause leaves the picture positioned where it stopped; a hover that ends places it back on the playhead.
hold="$(body "${clock}" '    private func holdPausedPicture(')"
if ! body "${clock}" '    func pause(' | grep -F 'holdPausedPicture(stoppedAt: nil)' >/dev/null ||
  ! grep -F 'if clock.pausedPictureRequested, clock.player.rate == 0 { clock.holdPausedPicture(stoppedAt: cmTime) }' \
    "${clock}" >/dev/null || ! awk '
  /CMTimebaseGetRate\(timebase\) == 0/ { stopped = NR }
  /let stopped = reported \?\? CMTimebaseGetTime\(timebase\)/ { read = NR }
  /source.seek\(to: seconds\)/ { sound = NR }
  /positionedTime = seconds/ { positioned = NR }
  END { exit !(stopped && read > stopped && sound > read && positioned > sound) }
' <<<"${hold}"; then
  fail "Pausing playback must keep the playhead, the sound and a positioned picture on the paused frame"
fi
if ! body "${clock}" '    func endPeek(' | grep -F 'positionPreview(at: CMTime(seconds: time' >/dev/null; then
  fail "Ending a hover must place and prime the picture back on the playhead"
fi

finish="$(body "${clock}" '    private func finishPreviewPosition(')"
if ! awk '
  /!layer.isReadyForDisplay/ { display = NR }
  /observeReadiness\(of: item, layer: layer\)/ { observe = NR }
  /if playbackRequested [{] play\(\) [}]/ { play = NR }
  END { exit !(display && observe > display && play > observe) }
' <<<"${finish}" || ! grep -qF 'previewClock: clock' "${surface}" ||
  ! grep -qF 'previewClock?.bindPreviewLayer(view.playerLayer)' "${layerHost}"; then
  fail "Wait for the first mounted preview picture before releasing a cold Play"
fi

if [ "$(grep -cF 'run: /bin/bash scripts/check-playback-start.sh' "${workflow}")" -ne 1 ]; then
  fail "The graphical benchmark must run in the required checks workflow"
fi

if ! python3 -B checks/PlaybackStart/test_compare.py; then
  fail "Playback timing consensus must preserve failures and bound confirmation"
fi

if [ "${failed}" -eq 0 ]; then echo "✓ Playback start wiring"; fi
exit "${failed}"
