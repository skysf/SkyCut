"""Measure the authored mix, then inspect the actual AAC track delivered by export_video."""

import math
from pathlib import Path
import re
import subprocess


def ff(ffmpeg, *arguments, **kwargs):
    return subprocess.run([str(ffmpeg), "-hide_banner", "-nostdin", *map(str, arguments)],
                          check=True, timeout=25, **kwargs)


def make_media(work, ffmpeg):
    ff(ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", "color=c=0x284C8C:s=320x180:r=24",
       "-t", 3, "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", work / "picture.mp4")
    # Same-phase stereo parts produce a known overload, concentrated in three timeline frames.
    tone = r"if(between(t\,1.25\,1.375)\,0.76\,0.22)*sin(2*PI*480*t)"
    ff(ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", f"aevalsrc={tone}|{tone}:s=48000:d=3",
       "-c:a", "pcm_f32le", work / "tone.wav")


def near(actual, expected, tolerance, label):
    assert math.isfinite(actual) and abs(actual - expected) <= tolerance, (
        f"{label}: expected {expected} ± {tolerance}, got {actual}"
    )


def verify_mix_export(session, work, ffmpeg):
    session.new_project(work, "Mix")
    session.edit("set_canvas", fps=24)
    session.edit("add_clips", clips=[
        {"file": "picture.mp4", "track": "V1"},
        {"file": "tone.wav", "track": "A1"},
        {"file": "tone.wav", "track": "A2"},
    ])
    session.edit("set_track", track="A2", volume_db=-3)
    mixed = session.edit("listen", mix=True, layers=["A1", "A2"], frames=True)
    if "job_id" in mixed:
        mixed = session.job(mixed)
    a1, a2 = mixed["layers"]
    assert [a1["name"], a2["name"]] == ["A1", "A2"], mixed["layers"]
    near(a1["peak_db"], 20 * math.log10(0.76), 0.2, "A1 true peak")
    near(a2["peak_db"], a1["peak_db"] - 3, 0.2, "A2 track gain")
    mix = mixed["mix"]
    assert 1.5 < mix["peak_db"] < 3 and 0.04 < mix["limited_seconds"] < 0.10, mix
    assert 1.25 <= mix["loudest_at"] <= 1.334, mix
    frames = mixed["frames"]
    assert frames["fps"] == 24 and frames["count"] == 72, frames["count"]
    assert frames["mix"]["reduction_db"][31] > 2 and frames["mix"]["reduction_db"][10] == 0

    folder = work / "unwritable"
    folder.mkdir(mode=0o500)
    try:
        assert not is_writable(folder), "Fixture folder is writable"
        failure, error = session.client.call("export_video", {
            "project": session.project, "path": str(folder / "refused.mp4"), "encoder": "software",
        }, timeout=20)
        assert error and "Nothing was exported" in failure and "can't write into" in failure, failure
        assert list(folder.iterdir()) == [], "Destination preflight left a file behind"
    finally:
        folder.chmod(0o700)

    destination = work / "delivery" / "mix.mp4"
    destination.parent.mkdir()
    destination.write_bytes(b"existing delivery")
    finished = session.job(session.edit("export_video", path=str(destination), encoder="software"))
    movie = Path(finished["path"]).resolve()
    assert movie.parent == destination.parent and movie != destination and movie.is_file(), finished
    assert destination.read_bytes() == b"existing delivery", "Export replaced an existing file"
    assert finished["video"]["width"] == 320 and finished["video"]["height"] == 180, finished["video"]
    near(finished["audio_peak_before_limiter_dbtp"], mix["peak_db"], 0.15, "export pre-limiter peak")
    near(finished["audio_loudness_lufs"], mix["loudness_lufs"], 0.75, "export mix loudness")
    measured = ff(ffmpeg, "-i", movie, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-",
                  stderr=subprocess.PIPE, text=True).stderr.rsplit("Summary:", 1)[-1]
    decoded_peak = float(re.search(r"Peak:\s+(-?[0-9.]+) dBFS", measured)[1])
    near(finished["audio_peak_dbtp"], decoded_peak, 0.4, "export reports the delivered AAC true peak")
    assert decoded_peak < -0.2, f"Export clipped after limiting: {decoded_peak} dBTP"
    print("MCP mix/export passed: layer gains, bus overload, limiter, AAC true peak and destination preflight", flush=True)


def is_writable(folder):
    try:
        with (folder / "write-test").open("xb"):
            pass
    except PermissionError:
        return False
    (folder / "write-test").unlink()
    return True
