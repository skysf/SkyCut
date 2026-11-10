"""假 Sky Studio 的声音那一摊（SkyCut 声音方案 4.2、5.4）：`/models` 的声音模型和预设 / 角色 / 授权文案照 Sky Studio 导出的目录快照，
读稿的 `/quote` 按整段（params.batches）回 voice_plan 和每批的价，做完的结果带实际跑的模型。Gemini 不报字的时间，Eleven v4 报。"""
import json
from pathlib import Path

CATALOG = json.loads((Path(__file__).resolve().parents[3] / "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json").read_text())
READING = ("voice", "voice_clone")
TOP_LEVEL = ("voice_presets", "voice_roles", "voice_rules", "voice_consent")


def models():
    return [model for model in CATALOG["models"] if model["kind"] in READING]


def library_models():
    """声音库的一次性费用那几个模型（设计、建 MiniMax 版）：打开全部权限时那段说明的价目从它们读（声音 PR 7）。"""
    return [model for model in CATALOG["models"] if model["kind"] in ("voice_design", "voice_enroll")]


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
