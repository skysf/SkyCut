"""新增模型的服务端目录快照和免费素材；不持有或读取生产凭证。"""
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

CATALOG = json.loads((Path(__file__).resolve().parents[3] / "checks/SkyStudio/Fixtures/models-2026-10-31.json").read_text())


def prepare(root, work, ffmpeg):
    subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(root / "video.mp4"), "-i", str(root / "narration.wav"), "-t", "2",
                    "-c:v", "libvpx-vp9", "-b:v", "200k", "-c:a", "libopus", str(root / "video.webm")], check=True, timeout=60)
    subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(root / "video.mp4"), "-i", str(root / "narration.wav"), "-t", "2",
                    "-c:v", "copy", "-c:a", "aac", str(root / "video-with-audio.mp4")], check=True, timeout=30)
    shutil.copyfile(root / "video.webm", work / "motion.webm")
    # 每行一半透明、一半不透明；测试的是 alpha 保存与实际入轨，不是去背景模型质量。
    width = height = 640
    row = b"\x00" + bytes([0, 0, 0, 0]) * (width // 2) + bytes([20, 120, 240, 255]) * (width // 2)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b"")
    (root / "cutout.png").write_bytes(png)
    (root / "captions.srt").write_text("1\n00:00:00,100 --> 00:00:01,500\nHello world\n", encoding="utf-8")


def billing(status="charged", amount=1, reserved=1):
    return dict(policy_version="2026-10-31", status=status, provider_outcome="succeeded",
                credits_reserved=reserved, credits_charged=amount, credits_refunded=max(0, reserved - amount) if amount is not None else None,
                review_required=status == "pending_review")


def finish(job, root, base):
    cutout = job["model"] == "ideogram-remove-background"
    webm = job["model"] == "heygen-v3-lipsync-precision"
    suffix = "png" if cutout else "webm" if webm else "mp4"
    target = root / (job["job_id"] + "." + suffix)
    source = "cutout.png" if cutout else "video.webm" if webm else "video-with-audio.mp4" if job["kind"] == "lipsync" else "video.mp4"
    shutil.copyfile(root / source, target)
    result = dict(url=base + "/files/" + target.name, content_type="image/png" if cutout else "video/" + suffix,
                  width=640, height=640)
    if cutout:
        result.update(has_alpha=True, has_transparency=True)
    else:
        result.update(duration=2, fps=24, billing_duration_seconds=3)
    if job["model"].startswith("heygen-"):
        result.update(caption_file=base + "/files/captions.srt", caption_status="saved")
    if job["model"] == "minimax-h3-max-lip-sync":
        result["seed"] = 1031
    job.update(status="done", generation_status="succeeded", delivery_status="saved", result=result,
               credits_charged=job["credits"], billing=billing(amount=job["credits"], reserved=job["credits"]))
