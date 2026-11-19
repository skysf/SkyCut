#!/bin/bash
# Startup's fast path stays independent of preview rebuilding, proxy work and blocking media reads.
# The graphical benchmark also counts real builds and item attachments around playback.
set -uo pipefail
cd "$(dirname "$0")/.."
clock=Sources/SrtFlow/VideoPreviewView.swift
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
fast_path "${clock}" '    private func anchorVideo('
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

anchor="$(body "${clock}" '    private func anchorVideo(')"
if ! awk '
  /guard player.status == .readyToPlay, player.currentItem\?.status == .readyToPlay/ { ready = NR }
  /player.setRate\(/ { rate = NR }
  END { exit !(ready && rate > ready) }
' <<<"${anchor}"; then
  fail "The synchronized native start requires both the player and its current item to be ready"
fi

preroll="$(body "${clock}" '    private func preparePositionedPreview(')"
if ! awk '
  /guard previewSeek == request/ { current = NR }
  /guard seekFinished, !isAtEnd, player.rate == 0, let item = player.currentItem else/ { placed = NR }
  /guard player.status == .readyToPlay, item.status == .readyToPlay/ { ready = NR }
  /observeReadiness\(of: item\)/ { observe = NR }
  /player.preroll\(atRate: / { pre = NR }
  /self\?\.finishPreviewPosition\(/ { finish = NR }
  END { exit !(current && placed > current && ready > placed && observe > ready && pre > observe && finish > pre) }
' <<<"${preroll}"; then
  fail "Prime a positioned preview on the asynchronous preroll path before releasing Play"
fi
# Every paused placement primes, a new item's first one included: a pending Play must not decide whether to preroll.
if sed 's,//.*,,' <<<"${preroll}" | grep -E 'guard seekFinished.*playbackRequested|playbackRequested[^?]*else [{]' >/dev/null; then
  fail "Prime every paused placement, a new item included, instead of waiting for Play to request the preroll"
fi

# The sound never starts ahead of the picture: Play starts the clocks only with a positioned, primed picture, never
# with a native seek (docs/bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md).
start="$(body "${clock}" '    func play(')"
if ! awk '
  /guard positionedTime == start, !previewIsUnprimed else [{]/ { gate = NR }
  /preparePositionedPreview\(request, at: start, seekFinished: true\)/ { prime = NR }
  /positionPreview\(at: CMTime\(seconds: start/ { place = NR }
  /source.play\(from: start\)/ { if (!first) first = NR }
  gate && /anchorVideo\(to: / { if ($0 !~ /anchorVideo\(to: nil[,)]/) seeking = 1 }
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
