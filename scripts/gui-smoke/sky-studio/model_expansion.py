"""真实 App/MCP：七模型、参数、实际素材入轨、幂等和交付失败结算；只访问回环假服务。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP
from model_expansion_fixtures import CATALOG

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
WORK = D / "work"
SERVER = "http://127.0.0.1:18766"
FFMPEG = os.environ["SRTFLOW_FFMPEG"]
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(name, args=None):
    value, error = mcp.call(name, args, timeout=90)
    assert not error, (name, value)
    return value


def control(**data):
    req = urllib.request.Request(SERVER + "/__control", json.dumps(data).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))


def log():
    return json.load(urllib.request.urlopen(SERVER + "/__log"))


def posts(rows):
    return [r["body"] for r in rows if r["method"] == "POST" and r["path"].endswith("/jobs")]


def spent():
    return call("get_status")["generation"]["spent_today_credits"]


def generate(args, status="done"):
    started = call("generate_media", args)
    assert started["status"] == "started", started
    done = mcp.wait_job(started["job_id"], 180)
    assert done["status"] == status, done
    assert done["idempotency_key"] == started["idempotency_key"]
    return started, done


def path(name):
    value = Path(name)
    return value if value.is_absolute() else WORK / value


try:
    call("open_folder", {"path": str(WORK)})
    call("set_view", {"mode": "background"})
    call("new_project", {"version": "new-models-" + str(time.time_ns())})
    control(hold=False, refuse_seedance=False, unknown_submission=False, quote_error=False,
            delivery_failure=False, billing_pending=False, settle_refund=False)
    found = call("get_status", {"models": True})["generation_models"]
    by_id = {m["id"]: m for m in found["models"]}
    assert found["billing_policy"]["version"] == "2026-10-31"
    for model in CATALOG["models"]:
        assert by_id[model["id"]] == model, (model["id"], by_id.get(model["id"]))
    print("PASS discovery: seven complete model records and billing policy", flush=True)
    output = []
    for model in CATALOG["models"]:
        identity, kind = model["id"], model["kind"]
        args = dict(kind=kind, model=identity, name=identity, idempotency_key="smoke-" + identity + str(time.time_ns()))
        if identity.startswith("wan-"):
            resolution = {"wan-3.0-text-to-video": "480p", "wan-3.0-image-to-video": "720p", "wan-3.0-reference-to-video": "1080p"}[identity]
            args.update(prompt="Calm blue studio", resolution=resolution, duration=2, generate_audio=False,
                        enable_prompt_expansion=True, enable_thinking=False, enable_safety_checker=True, seed=1031)
            if identity == "wan-3.0-image-to-video":
                args.update(image="subject.png", last_image="subject.png")
            elif identity == "wan-3.0-reference-to-video":
                args.update(input_mode="multimodal", reference_images=["subject.png"], reference_videos=["motion.mp4"])
        elif identity.startswith("heygen-"):
            args.update(video="motion.webm" if "precision" in identity else "motion.mp4", audio="reference.wav")
            if "precision" in identity:
                args.update(title="Replacement", enable_caption=True, enable_dynamic_duration=True,
                            disable_music_track=True, enable_speech_enhancement=True, start_time=0.1, end_time=1.5)
        elif identity == "minimax-h3-max-lip-sync":
            args.update(image="subject.png", audio="reference.wav", resolution="480p", seed=1031,
                        enable_transcription=True, enable_safety_checker=True)
        else:
            args.update(operation="remove_background", image="subject.png", sync_mode=True, enable_safety_checker=True)
        before, mark = spent(), len(log())
        started, done = generate(args)
        assert spent() == before + 1, done
        again = call("generate_media", args)
        assert again["job_id"] == started["job_id"] and spent() == before + 1
        posted = posts(log()[mark:])
        assert len(posted) == 1 and posted[0]["model"] == identity and posted[0]["idempotency_key"] == args["idempotency_key"]
        assert posted[0]["params"] == started["params"], posted
        uploads = [r["body"]["purpose"] for r in log()[mark:] if r["method"] == "POST" and r["path"].endswith("/uploads")]
        if identity.startswith("heygen-"):
            assert uploads == ["lipsync_video", "lipsync_audio"], uploads
            assert posted[0]["params"]["enable_dynamic_duration"] == ("precision" in identity)
            assert path(done["caption_file"]).read_text().startswith("1\n")
        elif identity == "minimax-h3-max-lip-sync":
            assert uploads == ["image", "h3_lipsync_audio"]
            assert posted[0]["params"]["resolution"] == "480P"
        elif identity == "ideogram-remove-background":
            assert uploads == ["background_removal_image"] and done["has_transparency"] is True
            assert path(done["file"]).read_bytes() == (D / "assets/cutout.png").read_bytes(), "PNG bytes/alpha must remain unchanged"
        if "precision" in identity:
            assert done["content_type"] == "video/webm"
            assert path(done["original_file"]).read_bytes() == (D / "assets/video.webm").read_bytes()
            assert path(done["file"]).suffix == ".mp4", "native-incompatible WebM needs an editing copy"
        subprocess.run([FFMPEG, "-v", "error", "-i", str(path(done["file"])), "-f", "null", "-"], check=True, timeout=30)
        if kind == "lipsync":
            subprocess.run([FFMPEG, "-v", "error", "-i", str(path(done["file"])), "-map", "0:a:0", "-f", "null", "-"], check=True, timeout=30)
        call("add_clips", {"clips": [{"file": done["file"]}]})
        output.append(done)
        print("PASS generate/import/idempotency", identity, flush=True)
    timeline = call("get_timeline")
    clips = [clip for track in timeline["tracks"] for clip in track["clips"]]
    videos = [clip for clip in clips if clip["kind"] == "video"]
    assert len(videos) == 6 and all(abs(clip["source_out"] - clip["source_in"] - 2) < 0.05 for clip in videos), videos
    assert all("640" in clip["source_size"] for clip in videos), videos
    caption = next(d["caption_file"] for d in output if d.get("caption_file"))
    call("add_clips", {"clips": [{"file": caption}]})
    assert call("get_subtitles")["original"]["lines"], "SRT sidecar must import through the real subtitle route"
    deadline = time.monotonic() + 90
    while True:
        timeline = call("get_timeline")
        images = [clip for track in timeline["tracks"] for clip in track["clips"] if clip["kind"] == "image"]
        assert len(images) == 1, "transparent image must remain in the project"
        if images[0].get("source_size"):
            break
        assert time.monotonic() < deadline, "native transparent-image preparation did not finish"
        time.sleep(0.25)
    # 原始 WebM 还必须经真实预览 / 导出路径产出有画面的视频，不能只靠 ffprobe 看得见轨道。
    exported = call("export_video", {"path": str(WORK / "model-expansion.mp4")})
    encoded = mcp.wait_job(exported["job_id"], 240)
    assert encoded["status"] == "done", encoded
    subprocess.run([FFMPEG, "-v", "error", "-i", str(path(encoded["path"])), "-f", "null", "-"], check=True, timeout=45)
    print("PASS actual timeline, transparent PNG, SRT and export", flush=True)

    mark, before = len(log()), spent()
    control(delivery_failure=True)
    _, failed = generate(dict(kind="text_to_video", model="wan-3.0-text-to-video", prompt="delivery fixture", duration=2), "failed")
    assert failed["billing"]["status"] == "charged" and spent() == before + 1
    call("get_job", {"job_id": failed["job_id"]})
    assert len(posts(log()[mark:])) == 1 and failed["remote_result"]
    control(delivery_failure=False, billing_pending=True)
    before, mark = spent(), len(log())
    _, pending = generate(dict(kind="text_to_video", model="wan-3.0-text-to-video", prompt="review fixture", duration=2), "failed")
    assert pending["billing"]["status"] == "pending_review" and spent() == before + 1
    control(settle_refund=True)
    reconciled = call("get_job", {"job_id": pending["job_id"]})
    assert reconciled["billing"]["status"] == "refunded" and spent() == before
    call("get_job", {"job_id": pending["job_id"]})
    assert spent() == before and len(posts(log()[mark:])) == 1
    control(billing_pending=False, settle_refund=False, unknown_submission=True)
    mark, before = len(log()), spent()
    args = dict(kind="text_to_video", model="wan-3.0-text-to-video", prompt="lost response", duration=2, idempotency_key="lost-" + str(time.time_ns()))
    started, unknown = generate(args, "failed")
    assert unknown["credits_unknown"] is True and spent() == before + 1
    assert call("generate_media", args)["job_id"] == started["job_id"]
    assert len(posts(log()[mark:])) == 1, "lost submit must not replay or switch models"
    assert all(not r["has_auth"] for r in log() if r["method"] == "PUT" or r["path"].startswith("/files/"))
    print("PASS delivery failure stays charged; pending review reconciles original; duplicate/lost requests do not charge again", flush=True)
finally:
    mcp.close()
