"""Compare the reference cut's preview, delivered pixels, sound and timeline with reviewed results."""

from array import array
from copy import deepcopy
import difflib
import json
import math
from pathlib import Path
import subprocess
import tempfile

from mix_export import ff, near
from reference_edits import inspect, read, read_mix, subtitles
from reference_media import WIDTH, HEIGHT, RATE


GOLDEN = Path(__file__).with_name("reference_golden.json")
FRAMES = {
    "base": 0.25,
    "alpha video": 0.875,
    "alpha still": 1.5,
    "stray": 47 / 24,
    "native title": 3.125,
    "web motion": 3.625,
    "subtitle": 4.5,
    "after subtitle": 4.875,
}


def pixels(ffmpeg, *arguments, input=None):
    return ff(ffmpeg, "-v", "error", *arguments, "-frames:v", 1, "-pix_fmt", "rgb24",
              "-c:v", "rawvideo", "-threads:v", 1, "-f", "rawvideo", "pipe:1",
              input=input, stdout=subprocess.PIPE).stdout


def look_pixels(session, ffmpeg, at, **source):
    payload, picture = session.look(time=at, size="small", **source)
    got = pixels(ffmpeg, "-f", "image2pipe", "-i", "pipe:0", "-vf", f"scale={WIDTH}:{HEIGHT}", input=picture)
    assert len(got) == WIDTH * HEIGHT * 3, payload
    return got


def patch(frame, x, y, radius=3):
    points = [(y + dy) * WIDTH + x + dx for dy in range(-radius, radius + 1) for dx in range(-radius, radius + 1)]
    return [round(sum(frame[index * 3 + channel] for index in points) / len(points)) for channel in range(3)]


def white_ink(frame, start_row):
    # Colored picture and web motion pixels fall below this threshold.
    ink = [(index % WIDTH, index // WIDTH) for index in range(WIDTH * start_row, WIDTH * HEIGHT)
           if min(frame[index * 3:index * 3 + 3]) >= 190]
    if not ink:
        return []
    x, y = zip(*ink)
    return [min(x), min(y), max(x), max(y)]


def read_frame_evidence(session, movie, ffmpeg):
    points = [(55, 90), (160, 90), (265, 90), (52, 42)]
    frames = {}
    for label, at in FRAMES.items():
        frame = pixels(ffmpeg, "-ss", f"{at:.6f}", "-i", movie)
        assert len(frame) == WIDTH * HEIGHT * 3, (label, len(frame))
        samples = [patch(frame, x, y) for x, y in points]
        evidence = {"rgb": samples}
        if label in {"alpha video", "alpha still", "web motion"}:
            # Compare both pictures using the App's color-managed look decode. The export-side oracle also
            # reads the actual file independently with ffmpeg and records those values below.
            preview = look_pixels(session, ffmpeg, at)
            delivered = look_pixels(session, ffmpeg, at, file=str(movie))
            preview_samples = [patch(preview, x, y) for x, y in points]
            delivered_samples = [patch(delivered, x, y) for x, y in points]
            close_numbers(preview_samples, delivered_samples, 15, f"{label} preview and delivered pixels")
            evidence["preview_rgb"] = preview_samples
        if label == "native title":
            evidence["white_ink"] = white_ink(frame, HEIGHT // 4)
        if label in {"subtitle", "after subtitle"}:
            evidence["white_ink"] = white_ink(frame, HEIGHT // 2)
        frames[label] = evidence

    movie_colors = frames["alpha video"]["rgb"]
    still_colors = frames["alpha still"]["rgb"]
    base_colors = frames["base"]["rgb"]
    close_numbers(movie_colors[0], base_colors[0], 8, "transparent ProRes region reveals the base")
    close_numbers(still_colors[0], base_colors[0], 8, "transparent PNG region reveals the base")
    assert movie_colors[2][1] > 155 and movie_colors[2][0] < 70, movie_colors
    assert movie_colors[1][0] > movie_colors[2][0] + 25 and movie_colors[1][1] < movie_colors[2][1] - 20, movie_colors
    assert still_colors[2][0] > 180 and still_colors[2][1] > 130, still_colors
    mark = frames["web motion"]["rgb"][3]
    assert mark[0] > 160 and mark[1] < 75 and mark[2] > 110, mark
    assert frames["native title"]["white_ink"], frames["native title"]
    assert frames["subtitle"]["white_ink"] and not frames["after subtitle"]["white_ink"], frames
    return frames


def check_sound_strip(session, ffmpeg):
    plain, image = session.look(time=2, size="small")
    drawn, sheet = session.look(time=2, size="small", sound=["mix", "A4"])
    def shown(frames):
        return [(frame["time"], frame["on_screen"]) for frame in frames]

    assert shown(plain["frames"]) == shown(drawn["frames"]), "Sound strip changed the picture evidence"
    rows = drawn["sound"]["rows"]
    assert [row["row"] for row in rows] == ["mix", "A4"], rows
    near(rows[1]["loudest_at"], 2, 1 / 24, "music's strongest frame on the sound strip")
    strip = pixels(ffmpeg, "-f", "image2pipe", "-i", "pipe:0", "-vf", "scale=256:-1", input=sheet)
    picture = pixels(ffmpeg, "-f", "image2pipe", "-i", "pipe:0", "-vf", "scale=256:-1", input=image)
    assert len(strip) - len(picture) >= 40 * 256 * 3, "Sound strip pixels are missing from the MCP image"


def tone_db(samples, start, frequency):
    wave = samples[round(start * RATE):round((start + 0.1) * RATE)]
    angle = 2 * math.pi * frequency / RATE
    magnitude = abs(sum(value * complex(math.cos(angle * n), math.sin(angle * n))
                        for n, value in enumerate(wave)))
    return round(20 * math.log10(max(0.001, 2 * magnitude / len(wave))), 2)


def decoded_audio(ffmpeg, movie):
    raw = ff(ffmpeg, "-v", "error", "-i", movie, "-vn", "-ac", 1, "-ar", RATE, "-f", "f32le", "pipe:1",
             stdout=subprocess.PIPE).stdout
    samples = array("f")
    samples.frombytes(raw)
    return samples


def require_voice_band_cut(delivered, source):
    # The outer tones account for the common gain of the mix, limiter and channel conversion.
    low, middle, high = [out - original for out, original in zip(delivered, source)]
    attenuation = (low + high) / 2 - middle
    assert 8 <= attenuation <= 16, (
        f"Delivered 960 Hz voice cut should be 8–16 dB relative to 100 and 4000 Hz, got {attenuation:.2f} dB "
        f"(decoded AAC {delivered}, original narration {source})"
    )


def read_sound_evidence(session, finished, movie, ffmpeg):
    # Four layers with per-frame bands fit on the wire over the four seconds containing both hits.
    result = read_mix(session, ["A3", "A4", "A5", "rest"], **{"from": 0, "to": 4})
    frames = result["frames"]["layers"]
    a4 = frames["A4"]["db"]
    a5 = frames["A5"]["db"]
    assert abs(a4.index(max(a4)) - 48) <= 1, "The music accent does not sound on the requested frame"
    assert max(a5) > -40 and max(a5[82:87]) == max(a5), "The made effect did not sound at its requested hit"
    samples = decoded_audio(ffmpeg, movie)
    voice_frequencies = (100, 960, 4000)
    # The two camera tones are both audible before and after the picture cut, only inside the fade.
    bands = {
        "before cut": [tone_db(samples, 1.6, hz) for hz in (240, 360)],
        "fade into cut": [tone_db(samples, 1.875, hz) for hz in (240, 360)],
        "fade out of cut": [tone_db(samples, 2.025, hz) for hz in (240, 360)],
        "after cut": [tone_db(samples, 2.3, hz) for hz in (240, 360)],
        "voice band": [tone_db(samples, 0.65, hz) for hz in voice_frequencies],
        "ducking": [tone_db(samples, at, 120) for at in (0.65, 5.30)],
    }
    assert bands["fade into cut"][1] > bands["before cut"][1] + 12, bands
    assert bands["fade out of cut"][0] > bands["after cut"][0] + 12, bands
    assert bands["ducking"][1] > bands["ducking"][0] + 7, bands["ducking"]
    narrator = decoded_audio(ffmpeg, movie.with_name("narrator.wav"))
    # Narration starts at 0.25 s in the cut, so these windows cover the same samples.
    require_voice_band_cut(bands["voice band"], [tone_db(narrator, 0.40, hz) for hz in voice_frequencies])
    return {
        "range": [result["mix"]["from"], result["mix"]["to"]],
        "levels": {layer["name"]: [layer["level_db"], layer["peak_db"]] for layer in result["layers"]},
        "mix": [result["mix"]["level_db"], result["mix"]["peak_db"], result["mix"]["loudness_lufs"]],
        "aac_bands": bands,
        "delivered": [finished["audio_loudness_lufs"], finished["audio_peak_dbtp"]],
    }


def stable_timeline(session):
    timeline = read(session)
    resolved = {key: deepcopy(timeline.get(key, [])) for key in
                ("canvas", "fps", "duration", "tracks", "texts", "shapes", "subtitles")}
    groups = {}
    for track in resolved["tracks"]:
        for clip in track["clips"]:
            del clip["id"]
            if "file" in clip:
                clip["file"] = Path(clip["file"]).name
            if "link_group" in clip:
                group = clip["link_group"]
                clip["link_group"] = groups.setdefault(group, len(groups) + 1)
            if "web_motion" in clip:
                clip["web_motion"].pop("macOS", None)
    for row in resolved["texts"] + resolved["shapes"]:
        row.pop("id", None)
    return resolved


def close_numbers(actual, expected, tolerance, label):
    if isinstance(expected, dict):
        assert actual.keys() == expected.keys(), (label, actual.keys(), expected.keys())
        for key in expected:
            close_numbers(actual[key], expected[key], tolerance, f"{label}.{key}")
    elif isinstance(expected, list):
        assert len(actual) == len(expected), (label, actual, expected)
        for index, (value, baseline) in enumerate(zip(actual, expected)):
            close_numbers(value, baseline, tolerance, f"{label}[{index}]")
    else:
        near(actual, expected, tolerance, label)


def encode(value):
    return json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"


def record_or_compare(measured, update):
    baseline = GOLDEN.read_text(encoding="utf-8")
    if update:
        candidate = encode(measured)
        folder = Path(tempfile.mkdtemp(prefix="skycut-golden.", dir="/tmp"))
        new_file = folder / "reference_golden.candidate.json"
        diff_file = folder / "reference_golden.diff"
        difference = difflib.unified_diff(baseline.splitlines(keepends=True), candidate.splitlines(keepends=True),
                                          fromfile=GOLDEN.name, tofile=new_file.name)
        new_file.write_text(candidate, encoding="utf-8")
        diff_file.write_text("".join(difference) or "Candidate matches the committed golden.\n", encoding="utf-8")
        print(f"Golden candidate: {new_file}\nReview diff: {diff_file}", flush=True)
        return new_file, diff_file
    expected = json.loads(baseline)
    if measured["timeline"] != expected["timeline"]:
        difference = difflib.unified_diff(encode(expected["timeline"]).splitlines(), encode(measured["timeline"]).splitlines())
        raise AssertionError("Reference timeline changed\n" + "\n".join(difference))
    for field in ("text", "start", "end"):
        assert measured["subtitle"][field] == expected["subtitle"][field], measured["subtitle"]
    close_numbers(measured["subtitle"]["box"], expected["subtitle"]["box"], 0.03, "subtitle layout box")
    assert measured["frames"].keys() == expected["frames"].keys(), "Reference frame set changed"
    for label, frame in expected["frames"].items():
        close_numbers(measured["frames"][label]["rgb"], frame["rgb"], 11, f"{label} frame")
        if "preview_rgb" in frame:
            close_numbers(measured["frames"][label]["preview_rgb"], frame["preview_rgb"], 11, f"{label} preview")
        if "white_ink" in frame:
            close_numbers(measured["frames"][label]["white_ink"], frame["white_ink"], 3, f"{label} ink bounds")
    close_numbers(measured["sound"]["levels"], expected["sound"]["levels"], 0.8, "stem levels (dB)")
    assert measured["sound"]["range"] == expected["sound"]["range"], measured["sound"]["range"]
    close_numbers(measured["sound"]["mix"], expected["sound"]["mix"], 0.7, "mix (dB, LUFS)")
    close_numbers(measured["sound"]["aac_bands"], expected["sound"]["aac_bands"], 3, "delivered frequency probes (dB)")
    close_numbers(measured["sound"]["delivered"], expected["sound"]["delivered"], 0.7, "AAC loudness and true peak")


def check_reference_output(session, work, ffmpeg, update):
    finished = session.job(session.edit("export_video", path=str(work / "Reference.mp4"), encoder="software", quality="high"))
    movie = Path(finished["path"]).resolve()
    assert movie == work / "Reference.mp4" and movie.is_file(), finished
    frames = read_frame_evidence(session, movie, ffmpeg)
    check_sound_strip(session, ffmpeg)
    report = inspect(session, file=str(movie))
    assert report["frame_scan"]["frames"] == 144, report["frame_scan"]
    assert any(item["kind"] == "stray_frames" and abs(item["from"] - 46 / 24) < 0.002
               and abs(item["to"] - 2) < 0.002 for item in report["findings"]), report["findings"]
    subtitle, = subtitles(session)
    subtitle.pop("id")
    measured = {"timeline": stable_timeline(session), "frames": frames, "subtitle": subtitle,
                "sound": read_sound_evidence(session, finished, movie, ffmpeg)}
    record_or_compare(measured, update)
    print("MCP reference cut passed: preview, delivery report, timeline, pixels, subtitles and sound", flush=True)
