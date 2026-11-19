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

run_trials() {
  local destination="$1" trial result log deadline status
  for trial in 1 2 3 4 5; do
    result="${destination}/trial-${trial}.json"
    log="${destination}/trial-${trial}.log"
    rm -f "${result}"
    echo "Playback start trial ${trial}/5"
    SRTFLOW_PLAYBACK_START_OUT="${result}" SRTFLOW_PLAYBACK_START_MEDIA="${media}" SRTFLOW_SMOKE_MUTE=1 \
      "${app}" -mainWindowSection videoEdit -ApplePersistenceIgnoreState YES -NSRecentDocumentsLimit 0 \
      -optimizedMedia.previewMode original >"${log}" 2>&1 &
    pid=$!
    deadline=$((SECONDS + 90))
    while kill -0 "${pid}" 2>/dev/null; do
      if [ "${SECONDS}" -ge "${deadline}" ]; then
        echo "Playback start trial ${trial} timed out" >&2
        tail -n 50 "${log}" >&2
        exit 1
      fi
      sleep 1
    done
    status=0
    wait "${pid}" || status=$?
    pid=""
    if [ "${status}" -ne 0 ] || [ ! -s "${result}" ]; then
      echo "Playback start trial ${trial} did not write a result (exit ${status})" >&2
      tail -n 50 "${log}" >&2
      exit 1
    fi
  done
}

score() {
  local destination="$1"
  shift
  python3 checks/PlaybackStart/compare.py "${destination}/summary.md" "${destination}"/trial-[1-5].json "$@"
}

run_trials "${out}"

{
  sw_vers
  sysctl hw.model hw.ncpu
  swift --version 2>&1
} >"${out}/machine.txt"
status=0
score "${out}" || status=$?
if [ "${status}" -ne 2 ]; then exit "${status}"; fi

echo "The hosted VM supplied isolated late frames. Running one repeat and retaining both batches."
repeat="${out}/repeat"
mkdir -p "${repeat}"
cp "${out}/machine.txt" "${repeat}/machine.txt"
run_trials "${repeat}"
score "${repeat}" --confirm "${out}"
