"""声音库的免费冒烟（SkyCut 声音 PR 6，方案 9.2）：真 App、真小程序、真入轨、真撤销，假 Sky Studio（run.sh 起的）。
请求批准、全部权限两种模式各走一遍：列声音；用录音新建（授权的问法、换了参数的令牌不收、人声不够当场拒）；加一种语言（问句写声音的名字，
已经有的那种语言在问之前、传之前就拒）；改名；删除（两种模式、存储一时不可用再发一次）；用 voice=voice_… 读一段旁白（还没建 MiniMax 版：
问一次性费用、skip_one_time 照不花钱的读、点头先建再读）；设计（问价、点头起任务）；每日硬预算挡一次性费用；声音库用不了时预设照回、
写操作和 voice_… 读稿报错不退本机；manage_voices 不登记撤销。
全部权限（声音 PR 7）：打开时记上长期授权，之后建声音（带 standing_grant）、建 MiniMax 版、设计都不问、做完说（结果带 full_access）。
结果留在测试目录的 voice-library-results.json。"""
import json
import os
import subprocess
import time

from voice_smoke_support import D, WORK, Smoke, control, log, rows, server

LINES = [{"text": "Hello world, this is the first line."}, {"text": "Hello world, this is the first line."}]
s = Smoke()
report = {}


def asked(result, *needles):
    assert result.get("status") == "needs_confirmation" and result.get("confirm_token"), result
    text = json.dumps(result, ensure_ascii=False)
    for needle in needles:
        assert needle in text, (needle, result)
    return result["confirm_token"]


def posts(mark, part, **body):
    return rows(log()[mark:], "POST", part, **body)


def create_voice(name, mode):
    """用录音建一个声音：问授权（或在有效的长期授权下不问），点头才传、才建。回声音的 id。"""
    args = {"action": "create", "file": "voice-sample.wav", "language": "en", "name": name}
    mark = len(log())
    first = s.call("manage_voices", args)
    standing = bool((server("/__voices")["grant"] or {}).get("active"))
    if standing and mode == "full_access":
        assert first["status"] == "created", first
        body = posts(mark, "/voices")[-1]["body"]
        assert body["consent"] == "standing_grant", body
        return first["voice"]["id"]
    token = asked(first, "voice-consent-v1", "I am the person in this recording", "voice-sample.wav")
    assert not posts(mark, "/uploads") and not posts(mark, "/voices"), "nothing is uploaded before the user confirms consent"
    wrong = s.call("manage_voices", {**args, "name": name + " (other)", "confirm_token": token})
    assert wrong.get("confirm_token_refused") and wrong["confirm_token"] != token, "a token for another name must not be redeemed"
    assert not posts(mark, "/voices")
    created = s.call("manage_voices", {**args, "confirm_token": token})
    assert created["status"] == "created" and created["voice"]["id"].startswith("voice_"), created
    upload = posts(mark, "/uploads")[-1]["body"]
    assert upload["purpose"] == "voice_reference" and upload["content_type"] == "audio/wav", upload
    body = posts(mark, "/voices")[-1]["body"]
    assert body["consent"] is True and body["consent_statement_version"] == "voice-consent-v1", body
    assert body["source"]["file_name"] == "voice-sample.wav" and body["source"]["auto_selected"] is False and body["idempotency_key"], body
    assert len(posts(mark, "/voices")) == 1, "one POST /voices per confirmed creation"
    return created["voice"]["id"]


def narrate(project, voice, mode):
    """用声音库的声音读稿：这种语言的 MiniMax 版没建 → 问一次性费用；skip_one_time 照 IndexTTS2 读；点头建了再读就照默认。
    全部权限 + 长期授权：不问，直接建 MiniMax 版、做完说（full_access），再读就照默认。"""
    args = {"project": project, "lines": LINES, "voice": voice, "subtitles": True}
    mark = len(log())
    question = s.call("add_voiceover", args)
    if mode == "full_access":
        assert question["status"] == "started" and question["kind"] == "voice_enroll" and question.get("full_access"), question
        built = s.wait(question["job_id"])
        assert built["status"] == "done" and server("/__voices")["minimax"][voice] == ["en"], built
        plain = s.call("add_voiceover", args)
        assert plain["status"] == "started" and plain["voice_plan"]["selection"]["model"] == "minimax-speech-2.8-hd", plain
        done = s.wait(plain["job_id"])
        assert done["status"] == "done" and s.timeline_counts(project) == (2, 2), done
        return {"enrolled_without_asking": question["full_access"], "enroll_charged": built.get("credits_charged")}
    token = asked(question, "voice_enroll", "skip_one_time")
    assert question["voice_plan"]["rule"] == "default_needs_one_time" and question["one_time"][0]["credits"] == 375, question
    assert not posts(mark, "/jobs"), "the one-time fee is asked before anything is submitted"
    skipped = s.call("add_voiceover", {**args, "skip_one_time": True})
    assert skipped["status"] == "started" and skipped["voice_plan"]["selection"]["model"] == "index-tts-2", skipped
    read = s.wait(skipped["job_id"])
    assert read["status"] == "done" and read["subtitle_timing"] == "aligned" and len(read["added"]) == 2, read
    job = posts(mark, "/jobs")[-1]["body"]
    assert job["kind"] == "voice_clone" and job["model"] == "auto" and job["params"]["plan"]["model"] == "index-tts-2", job
    assert s.timeline_counts(project) == (2, 2), "two clips and two subtitles land together"
    s.call("undo", {"project": project})
    assert s.timeline_counts(project) == (0, 0), "one undo removes the narration and its subtitles"
    again = s.call("add_voiceover", args)
    assert again["status"] == "needs_confirmation" and again["confirm_token"] == token, "the same pending question keeps its token"
    enroll = s.call("add_voiceover", {**args, "confirm_token": token})
    assert enroll["status"] == "started" and enroll["kind"] == "voice_enroll", enroll
    built = s.wait(enroll["job_id"])
    assert built["status"] == "done" and built["voice"]["languages"][0]["minimax"] is True, built
    assert server("/__voices")["minimax"][voice] == ["en"]
    plain = s.call("add_voiceover", args)
    assert plain["status"] == "started" and plain["voice_plan"]["selection"]["model"] == "minimax-speech-2.8-hd", plain
    done = s.wait(plain["job_id"])
    assert done["status"] == "done" and done["voice"]["quality"] == "Sky Studio voice", done
    assert s.timeline_counts(project) == (2, 2)
    return {"one_time_credits": question["one_time"][0]["credits"], "enroll_charged": built.get("credits_charged"),
            "skip_subtitle_timing": read["subtitle_timing"], "after_enroll_subtitle_timing": done.get("subtitle_timing")}


def design(project, name, mode="ask_for_approval"):
    args = {"action": "design", "description": "A warm, calm male narrator with a slight smile.", "name": name}
    mark = len(log())
    started = s.call("manage_voices", args)
    if mode == "ask_for_approval":
        token = asked(started, "22.5")
        assert started["model"] == "qwen3-voice-design" and not posts(mark, "/jobs"), started
        started = s.call("manage_voices", {**args, "confirm_token": token})
    else:
        assert started.get("full_access"), "full access with a standing consent designs without asking and says so"
    assert started["status"] == "started" and started["kind"] == "voice_design", started
    done = s.wait(started["job_id"])
    assert done["status"] == "done" and done["voice"]["source"] == "design" and done.get("sample_url"), done
    return done["voice"]["id"]


def delete(voice, name, mode, storage_failures=0):
    mark = len(log())
    control(delete_storage_failures=storage_failures)
    first = s.call("manage_voices", {"action": "delete", "voice": voice})
    if mode == "ask_for_approval":
        token = asked(first, name)
        assert not rows(log()[mark:], "DELETE", "/voices"), "nothing is deleted before the user confirms"
        first = s.call("manage_voices", {"action": "delete", "voice": voice, "confirm_token": token})
    assert first["status"] == "deleted", first
    assert voice not in server("/__voices")["voices"]
    return len(rows(log()[mark:], "DELETE", "/voices"))


try:
    s.call("get_status")
    assert {"list_voices", "manage_voices"}.issubset(s.mcp.tools())
    s.call("open_folder", {"path": str(WORK)})
    s.call("set_view", {"mode": "background"})
    initial = s.call("get_settings")["sections"]
    s.settings({"ai_access_mode": "ask_for_approval", "daily_ai_credit_limit": 5000})
    project = s.call("new_project", {"version": "library-" + str(time.time_ns())})["project"]
    spent = s.spent()
    listed = s.call("list_voices")
    presets = {entry["language"]: entry["voices"] for entry in listed["presets"]}
    assert listed["mine"] == [] and set(presets) == {"zh", "en"}, listed
    assert all(any(v["id"] == "gemini:Charon" and v.get("default") for v in voices) for voices in presets.values()), presets
    japanese = s.call("list_voices", {"language": "ja", "include": "presets"})
    assert "mine" not in japanese and japanese["presets"][0]["list_language"] == "en", japanese

    # 人声不够（6 秒的录音）：做参考录音时就拒，不问、不传。
    subprocess.run([os.environ["SRTFLOW_FFMPEG"], "-y", "-v", "error", "-i", str(WORK / "voice-sample.wav"), "-t", "6",
                    str(WORK / "short-sample.wav")], check=True, timeout=30)
    mark = len(log())
    short = s.refused("manage_voices", {"action": "create", "file": "short-sample.wav", "language": "en", "name": "Too short"})
    assert "10" in short and not posts(mark, "/uploads"), short

    # 请求批准模式
    voice = create_voice("Smoke Voice", "ask_for_approval")
    # 加一种语言：问句写声音的名字（不是 id）。
    reference_question = s.call("manage_voices", {"action": "add_reference", "voice": voice, "file": "voice-sample.wav", "language": "zh"})
    token = asked(reference_question, "Smoke Voice")
    assert voice not in reference_question["question"], "the consent question names the voice, not its id"
    added = s.call("manage_voices", {"action": "add_reference", "voice": voice, "file": "voice-sample.wav", "language": "zh",
                                     "confirm_token": token})
    assert added["status"] == "reference_added" and [l["language"] for l in added["voice"]["languages"]] == ["en", "zh"], added
    # 已经有的那种语言：问之前、传之前就拒（本机先 GET 这个声音）。
    mark = len(log())
    exists = s.refused("manage_voices", {"action": "add_reference", "voice": voice, "file": "voice-sample.wav", "language": "zh"})
    assert "already has a recording in Chinese" in exists and not posts(mark, "/uploads") and not posts(mark, "/references"), exists
    renamed = s.call("manage_voices", {"action": "rename", "voice": voice, "name": "Smoke Voice Renamed"})
    assert renamed["status"] == "renamed" and renamed["voice"]["name"] == "Smoke Voice Renamed", renamed
    assert [v["name"] for v in s.call("list_voices", {"include": "mine"})["mine"]] == ["Smoke Voice Renamed"]
    report["ask_narration"] = narrate(project, voice, "ask_for_approval")
    designed = design(project, "Designed Voice")
    limit = int(s.spent()) + 10
    s.settings({"daily_ai_credit_limit": limit})
    mark = len(log())
    blocked = s.call("manage_voices", {"action": "design", "description": "Another calm narrator.", "name": "Over budget"})
    assert blocked["status"] == "blocked" and blocked["code"] == "daily_budget_exceeded" and "confirm_token" not in blocked, blocked
    assert not posts(mark, "/jobs")
    s.settings({"daily_ai_credit_limit": 5000})
    report["ask_delete_requests"] = delete(designed, "Designed Voice", "ask_for_approval")

    # manage_voices 不登记时间线撤销：放一段、改名、撤一步 = 撤掉的是那一段。
    undo_project = s.call("new_project", {"version": "library-undo-" + str(time.time_ns())})["project"]
    s.call("add_clips", {"project": undo_project, "clips": [{"file": "motion.mp4"}]})
    s.call("manage_voices", {"action": "rename", "voice": voice, "name": "Smoke Voice"})
    s.call("undo", {"project": undo_project})
    assert s.timeline_counts(undo_project) == (0, 0), "undo after manage_voices undoes the earlier timeline edit"
    nothing = s.refused("undo", {"project": undo_project})
    assert "nothing to undo" in nothing
    s.call("close_project", {"project": undo_project})

    # 全部权限模式（声音 PR 7）：打开时点头记上长期授权，之后建声音、建 MiniMax 版、设计都不问。
    s.settings({"ai_access_mode": "full_access"})
    assert (server("/__voices")["grant"] or {}).get("active"), "turning on full access records the standing voice consent"
    second = create_voice("Full Access Voice", "full_access")
    full_project = s.call("new_project", {"version": "library-full-" + str(time.time_ns())})["project"]
    report["full_access_narration"] = narrate(full_project, second, "full_access")
    s.call("close_project", {"project": full_project})
    designed_full = design(project, "Full Access Design", "full_access")
    delete(designed_full, "Full Access Design", "full_access")
    report["full_delete_requests"] = delete(second, "Full Access Voice", "full_access", storage_failures=1)
    assert report["full_delete_requests"] == 2, "a storage hiccup is retried once with a second DELETE"

    # 声音库用不了：预设照回、我的声音写一句；写操作和 voice_… 读稿报错、一分不花、不退本机。
    control(library_unavailable=True)
    mark = len(log())
    down = s.call("list_voices")
    assert down["mine"]["unavailable"] is True and down["presets"], down
    rename = s.refused("manage_voices", {"action": "rename", "voice": voice, "name": "Nope"})
    reading = s.refused("add_voiceover", {"project": project, "lines": LINES, "voice": voice})
    assert not posts(mark, "/jobs") and s.timeline_counts(project) == (2, 2), "no local fallback for library voices"
    control(library_unavailable=False)

    s.settings({"ai_access_mode": initial["ai"]["ai_access_mode"], "daily_ai_credit_limit": initial["sky_studio"]["daily_ai_credit_limit"]})
    s.call("save_project", {"project": project})
    s.call("close_project", {"project": project})
    assert all(not row["has_auth"] for row in log() if row["method"] == "PUT" or row["path"].startswith("/files/"))
    report.update(spent=s.spent() - spent, voices_left=server("/__voices")["voices"], reference_exists=exists[:200],
                  library_unavailable={"rename": rename[:200], "add_voiceover": reading[:200]})
    (D / "voice-library-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print("PASS voice library: list (presets per language, mine), create with consent (wrong token refused, short sample refused before "
          "upload), add a language (named in the question, an existing one refused before asking), rename, library narration (one-time "
          "fee asked, skip_one_time, enrol then default), design, budget block, full access with the standing consent (create, enrol and "
          "design without asking), delete in both modes with storage retry, unavailable library without local fallback, no undo from "
          "manage_voices")
finally:
    s.close()
