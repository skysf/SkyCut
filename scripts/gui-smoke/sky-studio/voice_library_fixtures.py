"""假 Sky Studio 的声音库（SkyCut 声音 PR 6）：`/voices` 的增删改查、设计 / 建 MiniMax 版的报价和成品、
用声音库的声音读稿时的整段报价（这种语言的 MiniMax 版还没建：`default_needs_one_time` + `one_time`）。
合同照 Sky Studio 仓库 docs/agents/skycut-api.md「Voice library」，形状和 SkyCut 的 checks/VoiceRecovery/LibraryFixture.swift 一致。
只在本机回环上答；不存任何服务商 id，录音只按 SkyCut 传上来的 WAV 头核对规格。所有函数都在 server.py 的 LOCK 里调。
长期授权（`/voices/consent-grant`，声音 PR 7）按账号记在 server.py 的 GRANTS，建声音时把这个账号的那一条传进来（`grant`）。"""
import datetime
import uuid
import wave

RECORDING_VERSION = "voice-consent-v1"
ENROLL_CREDITS = 375.0
DESIGN_CREDITS = {"qwen3-voice-design": 22.5, "minimax-voice-design": 750.0}
CLONE_BATCH_CREDITS = 1.5
STATE = {"voices": {}, "keys": {}, "hidden": set(), "reference_files": {}}


def stamp(seconds=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).isoformat()


def error(status, code, **extra):
    return status, {"error": {"code": code, "message": "Sky Studio says " + code + ".", **extra}}


def public(voice, base):
    """回给 SkyCut 的样子：试听链接是 1 小时的临时链接；没有服务商 id（minimax 只是布尔）。"""
    languages = [{**entry, "preview_url": base + "/files/narration.wav", "preview_expires_at": stamp(3600)} for entry in voice["languages"]]
    return {**{k: v for k, v in voice.items() if k != "languages"}, "languages": languages}


def reference_spec(root, url):
    """SkyCut 传上来的参考录音：44.1 kHz 单声道 16-bit WAV（docs/architecture/voice-library.md 第一节）。回秒数，不合规格回 None。"""
    name = url.rsplit("/", 1)[-1]
    try:
        with wave.open(str(root / name)) as audio:
            if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (44100, 1, 2):
                return None
            return audio.getnframes() / 44100
    except (OSError, wave.Error):
        return None


def handle(method, rest, body, control, root, base, grant=None):
    """`rest`：`/voices` 后面那一截（空、`/<id>`、`/<id>/references`；长期授权那一条在 server.py）。`grant`：这个账号的长期授权。
    回 (状态码, JSON)。"""
    if control.get("library_unavailable"):
        return error(503, "voice_library_unavailable", reason="not_configured", retryable=False)
    voices = STATE["voices"]
    if rest in ("", "/"):
        if method == "GET":
            listed = [public(v, base) for k, v in sorted(voices.items()) if k not in STATE["hidden"]]
            return 200, {"voices": listed, "next_cursor": None}
        if method == "POST":
            return create(body, control, root, base, grant)
        return error(405, "method_not_allowed")
    parts = [p for p in rest.split("/") if p]
    voice_id = parts[0]
    voice = voices.get(voice_id)
    if voice is None:
        return error(404, "not_found")
    if len(parts) == 2 and parts[1] == "references" and method == "POST":
        return add_reference(voice, body, root, base, grant)
    if len(parts) != 1:
        return error(404, "not_found")
    if method == "DELETE":
        if control.get("delete_storage_failures", 0) > 0:
            control["delete_storage_failures"] -= 1
            STATE["hidden"].add(voice_id)  # 已经看不见了（正在删），再发一次 DELETE 接着删
            return error(503, "voice_library_unavailable", reason="storage_unavailable", retryable=True)
        del voices[voice_id]
        STATE["hidden"].discard(voice_id)
        return 200, {"deleted": True}
    if voice_id in STATE["hidden"]:
        return error(404, "not_found")
    if method == "GET":
        return 200, {"voice": public(voice, base)}
    if method == "PATCH":
        name = (body.get("name") or "").strip()
        if not name or len(name) > 80:
            return error(400, "invalid_name")
        voice.update(name=name, updated_at=stamp())
        return 200, {"voice": public(voice, base)}
    return error(405, "method_not_allowed")


def consent_ok(body, grant):
    """`consent: true`（这一次点过头）或 `"standing_grant"`（这个账号要有有效的长期授权）。"""
    given = body.get("consent")
    if given is True:
        return body.get("consent_statement_version", RECORDING_VERSION) == RECORDING_VERSION, "consent_outdated"
    if given == "standing_grant":
        return bool(grant and grant.get("active")), "no_standing_grant"
    return False, "consent_required"


def create(body, control, root, base, grant):
    key = body.get("idempotency_key")
    if key and key in STATE["keys"] and STATE["keys"][key] in STATE["voices"]:
        return 200, {"voice": public(STATE["voices"][STATE["keys"][key]], base)}
    ok, code = consent_ok(body, grant)
    if not ok:
        return error(403 if code == "no_standing_grant" else 400, code)
    if len(STATE["voices"]) >= control.get("voice_limit", 50):
        return error(409, "voice_limit", limit=control.get("voice_limit", 50))
    seconds = reference_spec(root, body.get("reference_url", ""))
    if seconds is None:
        return error(400, "invalid_reference")
    name = (body.get("name") or "").strip()
    voice_id = "voice_" + uuid.uuid4().hex
    STATE["voices"][voice_id] = {
        "id": voice_id, "name": name, "source": "recording", "scope": "personal", "team_id": None,
        "languages": [{"language": body["language"], "kind": "recording", "seconds": round(seconds, 2), "minimax": False}],
        "created_at": stamp(), "updated_at": stamp()}
    STATE["reference_files"][voice_id] = [body.get("reference_url")]
    if key:
        STATE["keys"][key] = voice_id
    return 200, {"voice": public(STATE["voices"][voice_id], base)}


def add_reference(voice, body, root, base, grant):
    ok, code = consent_ok(body, grant)
    if not ok:
        return error(403 if code == "no_standing_grant" else 400, code)
    language = body.get("language")
    if any(entry["language"] == language for entry in voice["languages"]):
        return error(409, "reference_exists", language=language)
    seconds = reference_spec(root, body.get("reference_url", ""))
    if seconds is None:
        return error(400, "invalid_reference")
    voice["languages"].append({"language": language, "kind": "recording", "seconds": round(seconds, 2), "minimax": False})
    voice["updated_at"] = stamp()
    STATE["reference_files"].setdefault(voice["id"], []).append(body.get("reference_url"))
    return 200, {"voice": public(voice, base)}


def enroll_item(voice, entry):
    """建这种语言的 MiniMax 版那一笔一次性费用（报价的 one_time 里的一项）。"""
    return {"kind": "voice_enroll", "model": "minimax-voice-clone", "voice": voice["id"], "language": entry["language"],
            "credits": ENROLL_CREDITS, "why": "The default model reads this voice in English from its MiniMax version.",
            "then": {"model": "minimax-speech-2.8-hd", "credits_expected": CLONE_BATCH_CREDITS}}


def clone_quote(data, control):
    """用声音库的声音读稿（`voice_clone`）整段报一次价。英文默认要 MiniMax 版；没建就先给不花一次性费用的 IndexTTS2，
    one_time 里是建它的那一笔（SkyCut 声音方案 4.5）。带了 params.plan 就照它（恢复补批次 / 跳过一次性费用后的再报价）。"""
    if control.get("library_unavailable"):
        return error(503, "voice_library_unavailable", reason="not_configured", retryable=False)
    params = data.get("params") or {}
    voice = STATE["voices"].get(params.get("voice"))
    if voice is None or voice["id"] in STATE["hidden"]:
        return error(404, "voice_not_found")
    batches = params.get("batches") or []
    language = params.get("language", "en")
    entry = next((e for e in voice["languages"] if e["language"] == language), voice["languages"][0])
    built = entry["minimax"]
    plan = params.get("plan")
    one_time = []
    if plan:
        selection, rule = plan, "plan"
    elif built:
        selection, rule = {"model": "minimax-speech-2.8-hd", "reference_language": entry["language"]}, "en_80"
    else:
        selection, rule = {"model": "index-tts-2", "reference_language": entry["language"]}, "default_needs_one_time"
        one_time = [enroll_item(voice, entry)]
    # 备用：MiniMax 版建了就是 IndexTTS2；没建时默认先给了 IndexTTS2，备用是 MiniMax、要先花那笔一次性费用（中途出错 = fallback_needs_one_time）。
    if built:
        fallback = {"selection": {"model": "index-tts-2", "reference_language": entry["language"]}, "available": True, "auto": True,
                    "one_time": []}
    else:
        fallback = {"selection": {"model": "minimax-speech-2.8-hd", "reference_language": entry["language"]}, "available": False,
                    "auto": False, "one_time": [enroll_item(voice, entry)]}
    total = CLONE_BATCH_CREDITS * len(batches)
    return 200, {"credits": total, "credits_expected": total, "settlement": "exact", "typical_seconds": 5,
                 "voice_plan": {"selection": selection, "requested_model": data.get("model", "auto"), "rule": rule,
                                "reason": "English is at least 80% of the reading time.",
                                "languages": [{"language": entry["language"], "share": 1, "seconds": 3}],
                                "cross_language": entry["language"] != language, "warnings": [], "fallback": fallback},
                 "batches": [{"credits": CLONE_BATCH_CREDITS, "credits_expected": CLONE_BATCH_CREDITS, "characters": len(text)}
                             for text in batches],
                 "one_time": one_time}


def design_model(prompt):
    """描述的语言决定模型（服务器选，SkyCut 不挑）：有汉字用 MiniMax，别的用 Qwen3。"""
    return "minimax-voice-design" if any("一" <= c <= "鿿" for c in prompt) else "qwen3-voice-design"


def library_quote(data, control):
    """设计声音 / 建 MiniMax 版的报价（一次性费用，「约多少（最多多少）」）。"""
    if control.get("library_unavailable"):
        return error(503, "voice_library_unavailable", reason="not_configured", retryable=False)
    if data["kind"] == "voice_design":
        if len(STATE["voices"]) >= control.get("voice_limit", 50):
            return error(409, "voice_limit", limit=control.get("voice_limit", 50))
        model = design_model(data.get("prompt", ""))
        credits = DESIGN_CREDITS[model]
        language = "zh" if model == "minimax-voice-design" else "en"
        # Like the real Sky Studio (2026-11-11 real smoke): no top-level model; it is only in voice_plan.selection.model.
        return 200, {"credits": credits, "credits_expected": credits * 0.9, "settlement": "exact", "typical_seconds": 30,
                     "voice_plan": {"selection": {"model": model}, "requested_model": "auto",
                                    "rule": "zh_80" if language == "zh" else "en_80", "reason": "The description is in one language.",
                                    "languages": [{"language": language, "share": 1, "seconds": 9}], "warnings": []},
                     "one_time": [{"kind": "voice_design", "model": model, "language": language, "credits": credits,
                                   "why": "Designing a voice from a description is a one-time fee."}]}
    return 200, {"credits": ENROLL_CREDITS, "credits_expected": ENROLL_CREDITS, "settlement": "exact",
                 "model": "minimax-voice-clone", "typical_seconds": 30}


def finish(job, base, billing):
    """设计 / 建 MiniMax 版做完：改声音库，回 `result.voice`（设计另有 1 小时的样音链接）。"""
    params = job.get("params") or {}
    if job["kind"] == "voice_enroll":
        voice = STATE["voices"].get(params.get("voice"))
        if voice is None:
            job.update(status="failed", error={"code": "voice_not_found", "message": "The voice was deleted."},
                       billing=billing("refunded", 0, job["credits"]))
            return
        for entry in voice["languages"]:
            if entry["language"] == params.get("language"):
                entry["minimax"] = True
        result = {"voice": public(voice, base), "model": job["model"], "warnings": []}
    else:
        voice_id = "voice_" + uuid.uuid4().hex
        model = design_model(job.get("prompt", ""))
        STATE["voices"][voice_id] = {
            "id": voice_id, "name": params.get("name", ""), "source": "design", "scope": "personal", "team_id": None,
            "languages": [{"language": "en", "kind": "design_sample", "seconds": 8.0, "minimax": False}],
            "design": {"prompt": job.get("prompt", ""), "model": model, "language": "en"},
            "created_at": stamp(), "updated_at": stamp()}
        result = {"voice": public(STATE["voices"][voice_id], base), "model": model,
                  "sample_url": base + "/files/narration.wav", "sample_expires_at": stamp(3600)}
    job.update(status="done", result=result, credits_charged=job["credits"],
               billing=billing("charged", job["credits"], job["credits"]))


def snapshot():
    """测试脚本核对用（`GET /__voices`，server.py 再并上测试账号的长期授权）：声音库里此刻有什么、每个声音传过哪几段录音。"""
    return {"voices": sorted(STATE["voices"]), "hidden": sorted(STATE["hidden"]),
            "minimax": {k: [e["language"] for e in v["languages"] if e["minimax"]] for k, v in STATE["voices"].items()},
            "reference_files": STATE["reference_files"]}
