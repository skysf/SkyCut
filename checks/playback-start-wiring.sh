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
fast_path "${clock}" '    private func playWhenReady('
fast_path "${clock}" '    private func recoverAudioIfNeeded('
fast_path "${clock}" '    private func anchorVideo('
fast_path "${clock}" '    func goToStart('
fast_path "${clock}" '    func seek(to'
fast_path "${clock}" '    private func positionPreview('
fast_path "${clock}" '    private func preparePositionedPreview('
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
  /player.status == .readyToPlay/ { ready = NR }
  /player.preroll\(atRate: / { pre = NR }
  /self\?\.finishPreviewPosition\(/ { finish = NR }
  END { exit !(current && ready > current && pre > ready && finish > pre) }
' <<<"${preroll}"; then
  fail "Prime a positioned preview on the asynchronous preroll path before releasing Play"
fi

if [ "$(grep -cF 'run: /bin/bash scripts/check-playback-start.sh' "${workflow}")" -ne 1 ]; then
  fail "The graphical benchmark must run in the required checks workflow"
fi

if [ "${failed}" -eq 0 ]; then echo "✓ Playback start wiring"; fi
exit "${failed}"
