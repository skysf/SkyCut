#!/bin/bash
# Times production playback in a real editor window. The CI GUI job has a graphical session;
# local runs use the active Mac session. The application mutes the speakers after the audio probe.
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "${pid}" ]; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT
out="${PLAYBACK_START_OUT:-${work}/out}"
media="${work}/media"
mkdir -p "${out}" "${media}"
rm -f "${out}/confirmed-summary.md"

ffmpeg="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${ffmpeg}" ]; then
  echo "Cannot generate the playback fixtures without executable ffmpeg at ${ffmpeg}" >&2
  exit 1
fi

swift build --arch arm64 --product SrtFlow
app="$(swift build --arch arm64 --show-bin-path)/SrtFlow"
if [ ! -x "${app}" ]; then
  echo "Cannot find the debug editor at ${app}" >&2
  exit 1
fi

ff() { "${ffmpeg}" -hide_banner -loglevel error -y -filter_threads 2 "$@"; }
ff -f lavfi -i "testsrc2=s=3840x2160:r=30:d=24" -c:v libx264 -threads:v 2 -preset ultrafast -crf 14 \
  -maxrate 36M -bufsize 36M \
  -g 240 -sc_threshold 0 -pix_fmt yuv420p -movflags +faststart "${media}/primary.mp4"
ff -f lavfi -i "testsrc2=s=1920x1080:r=30:d=24" -c:v libx264 -threads:v 2 -preset ultrafast -g 30 \
  -pix_fmt yuv420p "${media}/opening.mp4"
ff -f lavfi -i "testsrc2=s=640x360:r=30:d=24" -c:v libx264 -threads:v 2 -preset ultrafast -g 30 \
  -pix_fmt yuv420p "${media}/overlay.mp4"
ff -f lavfi -i "sine=frequency=443:sample_rate=48000:duration=24" -ac 2 -c:a pcm_s16le "${media}/tone.wav"

# One editor process: writes its result JSON, returns its exit status (124 when it hangs past the deadline).
launch() {
  local result="$1" log="$2" deadline status=0
  rm -f "${result}"
  echo "Started $(date -u +%H:%M:%S), load average $(sysctl -n vm.loadavg)" >"${log}"
  SRTFLOW_PLAYBACK_START_OUT="${result}" SRTFLOW_PLAYBACK_START_MEDIA="${media}" SRTFLOW_SMOKE_MUTE=1 \
    "${app}" -mainWindowSection videoEdit -ApplePersistenceIgnoreState YES -NSRecentDocumentsLimit 0 \
    -optimizedMedia.previewMode original >>"${log}" 2>&1 &
  pid=$!
  deadline=$((SECONDS + 45))
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      pid=""
      echo "Timed out after 45 s" >>"${log}"
      return 124
    fi
    sleep 1
  done
  wait "${pid}" || status=$?
  pid=""
  if [ "${status}" -eq 0 ] && [ ! -s "${result}" ]; then status=1; fi
  return "${status}"
}

run_trials() {
  local destination="$1" launches="$2" trial status
  for ((trial = 1; trial <= launches; trial++)); do
    echo "Playback start trial ${trial}/${launches}"
    status=0
    launch "${destination}/trial-${trial}.json" "${destination}/trial-${trial}.log" || status=$?
    if [ "${status}" -ne 0 ]; then
      echo "Playback start trial ${trial} did not write a result (exit ${status})" >&2
      tail -n 50 "${destination}/trial-${trial}.log" >&2
      exit 1
    fi
  done
}

{
  sw_vers
  sysctl hw.model hw.ncpu
  swift --version 2>&1
} >"${out}/machine.txt"

# The first launch of a freshly linked binary carries one-time system costs that opening a project never does again.
# On hosted runners it froze or delayed the picture for seconds while later launches started in sync, so it runs the
# same scenarios unscored. Its samples stay in the artifact and the summary (docs/architecture/playback-start.md).
mkdir -p "${out}/warmup"
warmup=0
echo "Playback start warm-up launch (not scored)"
launch "${out}/warmup/trial-1.json" "${out}/warmup/trial-1.log" || warmup=$?
echo "Warm-up launch exit status ${warmup}"

run_trials "${out}" 5

status=0
python3 checks/PlaybackStart/compare.py "${out}/summary.md" "${out}"/trial-[1-5].json \
  --warmup "${out}/warmup/trial-1.json" || status=$?
if [ "${status}" -ne 2 ]; then exit "${status}"; fi

echo "Confirming hosted timing with three more launches. All eight count toward the verdict."
repeat="${out}/repeat"
mkdir -p "${repeat}"
run_trials "${repeat}" 3
python3 checks/PlaybackStart/compare.py "${out}/confirmed-summary.md" \
  "${out}"/trial-[1-5].json "${repeat}"/trial-[1-3].json --confirm --warmup "${out}/warmup/trial-1.json"
