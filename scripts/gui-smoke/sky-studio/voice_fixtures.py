"""假 Sky Studio 的声音那一摊（SkyCut 声音方案 4.2、5.4）：`/models` 的声音模型和预设 / 角色 / 授权文案照 Sky Studio 导出的目录快照，
读稿的 `/quote` 按整段（params.batches）回 voice_plan 和每批的价，做完的结果带实际跑的模型。Gemini 不报字的时间，Eleven v4 报。
声音库那一摊（`/voices`、设计、建 MiniMax 版、用声音库的声音读稿的报价）在 voice_library_fixtures。"""
import copy
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


def models(max_characters=None):
    """`/models` 里的声音模型：读稿的几个 + 声音库一次性费用的那几个（library_models）+ 变声的（声音 PR 9）。`max_characters`：并发冒烟把读稿每批的
    字数上限压小，几句短句就分成几批（App 照 /models 的上限分批、缓存 10 分钟，所以只能在起服务时给）。"""
    reading = [copy.deepcopy(model) for model in CATALOG["models"] if model["kind"] in READING]
    if max_characters:
        for model in reading:
            limits = (model.get("limits") or {}).get("max_characters_by_language")
            for language in limits or {}:
                limits[language] = max_characters
    return reading + library_models() + [model for model in CATALOG["models"] if model["kind"] == CONVERT]


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
