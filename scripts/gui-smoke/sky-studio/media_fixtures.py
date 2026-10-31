"""免费媒体合同夹具；只复制 run.sh 生成的文件，不访问提供方。"""
import shutil


def models():
    image_limits = dict(max_images=14, max_videos=0, max_audio=0, max_total_files=14)
    h3 = dict(max_images=9, max_videos=3, max_audio=3, max_total_files=12,
              max_total_video_seconds=15, max_total_audio_seconds=15, audio_requires_visual=True,
              min_video_clip_seconds=2, max_video_clip_seconds=15,
              max_image_bytes=30 * 1024 * 1024, max_audio_bytes=15 * 1024 * 1024,
              max_total_video_bytes_exclusive=50 * 1024 * 1024,
              resolution=["480p", "768p", "2K", "4K"])
    omni = dict(max_images=10, max_videos=3, max_audio=0, max_total_files=13,
                max_video_clip_seconds=10, duration_tolerance_seconds=0.1, resolution=["720p", "1080p"])
    seedance = dict(max_images=30, max_videos=10, max_audio=10, max_total_files=50,
                    max_total_video_seconds=30.2, max_total_audio_seconds=30.2, resolution=["480p", "720p", "1080p"])
    result = []
    titles = {"minimax-h3": "MiniMax H3", "gemini-omni-1.1-flash": "Google Omni 1.1", "seedance-2-5": "Seedance 2.5"}
    for model in ["seedream5-flash", "nano2"]:
        result.append(dict(id=model, kind="image", title=model,
                           params=dict(resolution=["2K", "4K"] if model == "nano2" else ["2K"], aspect_ratio=["16:9", "9:16", "4:1"]),
                           defaults=dict(resolution="2K"), limits=dict(references={**image_limits, "max_images": 10 if model == "seedream5-flash" else 14})))
    for model, resolution, seconds, caps in [("minimax-h3", "768p", 5, h3),
            ("gemini-omni-1.1-flash", "720p", 5, omni), ("seedance-2-pro", "720p", 5, h3),
            ("seedance-2-5", "720p", 5, seedance), ("veo-fast", "1080p", 8, None), ("veo-pro", "1080p", 8, None)]:
        for kind in ["image_to_video", "text_to_video"]:
            modes = {"frames": dict(max_images=2, max_videos=0, max_audio=0, max_total_files=2, resolution=[resolution])}
            if caps:
                modes["multimodal"] = caps
            result.append(dict(id=model, kind=kind, title=titles.get(model, model), params=dict(duration_values=[8] if model.startswith("veo") else list(range(3, 16)),
                        resolution=[resolution], aspect_ratio=["16:9", "9:16"], mode=list(modes)),
                        defaults=dict(duration=seconds, resolution=resolution, mode="frames"), inputs=dict(modes=modes)))
    return result


def finish(job, root, base):
    image = job["kind"] == "image"
    ext = ".png" if image else ".mp4"
    target = root / (job["job_id"] + ext)
    shutil.copyfile(root / ("picture.png" if image else "video.mp4"), target)
    job.update(status="done", credits_charged=job["credits"], result=dict(url=base + "/files/" + target.name,
                content_type="image/png" if image else "video/mp4", width=640, height=640, **({} if image else dict(duration=2))))


def refuse(job, refunded):
    job.update(status="failed", error=dict(code="provider_error", provider_code="REAL_PERSON_REFERENCE",
               reason="real_person_reference", refunded=refunded, message="The reference likeness was refused."),
               billing=dict(status="refunded" if refunded else "refund_pending", credits_charged=0 if refunded else None,
                            credits_refunded=job["credits"] if refunded else 0))
