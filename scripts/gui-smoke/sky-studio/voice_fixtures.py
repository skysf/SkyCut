"""假 Sky Studio 的声音那一摊（SkyCut 声音方案 4.2、5.4）：`/models` 的声音模型和预设 / 角色 / 授权文案照 Sky Studio 导出的目录快照，
读稿的 `/quote` 按整段（params.batches）回 voice_plan 和每批的价，做完的结果带实际跑的模型。Gemini 不报字的时间，Eleven v4 报。"""
import json
from pathlib import Path

CATALOG = json.loads((Path(__file__).resolve().parents[3] / "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json").read_text())
READING = ("voice", "voice_clone")
CONVERT = "voice_convert"
TOP_LEVEL = ("voice_presets", "voice_roles", "voice_rules", "voice_consent")
# 声音库里的一个声音（变声的目标，声音 PR 9）：有中文、英文两段录音。只回 Sky Studio 自己的 id，没有任何服务商 id。
VOICE_ID = "voice_" + "5" * 32
VOICE = {"id": VOICE_ID, "name": "Smoke voice", "source": "recording", "scope": "personal",
         "languages": [{"language": code, "kind": "recording", "seconds": 30, "minimax": False} for code in ("zh", "en")]}


def models():
    return [model for model in CATALOG["models"] if model["kind"] in READING or model["kind"] == CONVERT]


def convert_quote():
    """变声的报价：「最多」和「大概」不一样（界面写「约 X（最多 Y）」）。"""
    return {"credits": 3, "credits_expected": 2, "settlement": "actual_output", "typical_seconds": 5, "model": "chatterbox-hd"}


def finish_convert(job, root, base):
    """变声做完：人声、背景各一个文件（都拿传上来的那段源音频当内容，长度就是源的长度）。"""
    source = root / Path(job["inputs"]["source_audio_url"]).name
    result = {}
    for part in ("voice", "background"):
        target = root / f"{job['job_id']}-{part}.wav"
        target.write_bytes(source.read_bytes())
        result[part + "_url"] = f"{base}/files/{target.name}"
    job.update(status="done", credits_charged=2, billing={"status": "charged", "credits_charged": 2},
               result={**result, "content_type": "audio/wav", "channels": 1, "padded_seconds": 0, "model": "chatterbox-hd",
                       "fallback_used": False})


def top_level():
    return {key: CATALOG[key] for key in TOP_LEVEL if key in CATALOG}


def selection(data):
    params = data.get("params") or {}
    if params.get("plan"):
        return params["plan"]
    if data["kind"] == "voice_clone":
        return {"model": "index-tts-2", "reference_language": "en"}
    model = data.get("model", "auto")
    return {"model": "gemini-3.8-flash-tts" if model == "auto" else model, "voice": params.get("voice", "gemini:Charon")}


def quote(data, per_batch):
    """整段报价：每批 per_batch 积分（最多 = 大概）；没有一次性费用。"""
    batches = (data.get("params") or {}).get("batches") or []
    return {"credits": per_batch * len(batches), "credits_expected": per_batch * len(batches), "settlement": "exact", "typical_seconds": 5,
            "voice_plan": {"selection": selection(data), "requested_model": data.get("model", "auto"), "rule": "preset",
                           "reason": "A preset voice reads this text.", "languages": [{"language": "en", "share": 1, "seconds": 3}],
                           "cross_language": False, "warnings": []},
            "batches": [{"credits": per_batch, "credits_expected": per_batch, "characters": len(text)} for text in batches],
            "one_time": []}


def gives_words(job):
    """这一单实际跑的模型报不报字的时间（目录里的 output.words）。"""
    model = (job.get("plan") or {}).get("model", job["model"])
    return any(entry["id"] == model and (entry.get("output") or {}).get("words") for entry in CATALOG["models"])


def outcome(job):
    plan = job.get("plan") or {"model": job["model"]}
    return {"model": plan.get("model"), "fallback_used": False, "voice_plan": {"selection": plan}}
