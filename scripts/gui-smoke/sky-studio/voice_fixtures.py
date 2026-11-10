"""假 Sky Studio 的声音那一摊（SkyCut 声音方案 4.2、5.4）：`/models` 的声音模型和预设 / 角色 / 授权文案照 Sky Studio 导出的目录快照，
读稿的 `/quote` 按整段（params.batches）回 voice_plan 和每批的价，做完的结果带实际跑的模型。Gemini 不报字的时间，Eleven v4 报。
声音库那一摊（`/voices`、设计、建 MiniMax 版、用声音库的声音读稿的报价）在 voice_library_fixtures。"""
import copy
import json
from pathlib import Path

CATALOG = json.loads((Path(__file__).resolve().parents[3] / "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json").read_text())
READING = ("voice", "voice_clone")
TOP_LEVEL = ("voice_presets", "voice_roles", "voice_rules", "voice_consent")


def models(max_characters=None):
    """快照里全部声音模型（读稿、建 MiniMax 版、设计、变声）。`max_characters`：并发冒烟把读稿每批的字数上限压小，
    几句短句就分成几批（App 照 /models 的上限分批、缓存 10 分钟，所以只能在起服务时给）。"""
    voices = [copy.deepcopy(model) for model in CATALOG["models"] if model["kind"].startswith("voice")]
    if max_characters:
        for model in voices:
            limits = (model.get("limits") or {}).get("max_characters_by_language")
            if model["kind"] in READING and limits:
                for language in limits:
                    limits[language] = max_characters
    return voices


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
    """整段报价：每批 per_batch 积分（最多 = 大概）；没有一次性费用。预设的备用是 Eleven v4 读同一个预设（中途换备用时用）。"""
    batches = (data.get("params") or {}).get("batches") or []
    chosen = selection(data)
    fallback = {"selection": {"model": "eleven-v4", "voice": chosen.get("voice", "gemini:Charon")}, "available": True, "auto": True,
                "one_time": []}
    return {"credits": per_batch * len(batches), "credits_expected": per_batch * len(batches), "settlement": "exact", "typical_seconds": 5,
            "voice_plan": {"selection": chosen, "requested_model": data.get("model", "auto"), "rule": "preset",
                           "reason": "A preset voice reads this text.", "languages": [{"language": "en", "share": 1, "seconds": 3}],
                           "cross_language": False, "warnings": [], "fallback": fallback},
            "batches": [{"credits": per_batch, "credits_expected": per_batch, "characters": len(text)} for text in batches],
            "one_time": []}


def gives_words(job, model=None):
    """这一单实际跑的模型报不报字的时间（目录里的 output.words）。"""
    model = model or (job.get("plan") or {}).get("model", job["model"])
    return any(entry["id"] == model and (entry.get("output") or {}).get("words") for entry in CATALOG["models"])


def outcome(job):
    """做完的结果里实际跑的模型。冒烟让某一批「中途换了备用」（job["outcome"] == "fallback_used"）：预设换 Eleven v4，
    声音库的声音在 IndexTTS2 和 MiniMax 之间换。"""
    plan = job.get("plan") or {"model": job["model"]}
    if job.get("outcome") != "fallback_used":
        return {"model": plan.get("model"), "fallback_used": False, "voice_plan": {"selection": plan}}
    if job["kind"] == "voice":
        used = {"model": "eleven-v4", "voice": plan.get("voice", "gemini:Charon")}
    else:
        used = {"model": "index-tts-2" if plan.get("model") != "index-tts-2" else "minimax-speech-2.8-hd", "reference_language": "en"}
    return {"model": used["model"], "fallback_used": True, "voice_plan": {"selection": plan}}


def fallback_needs_one_time(job, billing):
    """这一批默认出错、备用要先建 MiniMax 版：任务以 fallback_needs_one_time 结束、没扣钱（结束码不带价，SkyCut 自己报一次 voice_enroll 的价）。"""
    voice = (job.get("params") or {}).get("voice")
    job.update(status="failed", billing=billing("refunded", 0, job["credits"]),
               error={"code": "fallback_needs_one_time", "refunded": True,
                      "message": "The default model failed and its fallback first needs the voice's MiniMax version.",
                      "one_time": [{"kind": "voice_enroll", "model": "minimax-voice-clone", "voice": voice, "language": "en"}]})
