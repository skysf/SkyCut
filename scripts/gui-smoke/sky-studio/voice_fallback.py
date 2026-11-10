"""旁白中途换备用（SkyCut 声音 PR 4、PR 6，方案 8.4、4.5、9.2）：真 App、真小程序、真入轨，假 Sky Studio。
和 voice_concurrency.py 同一个起法（SKYSTUDIO_SMOKE_CONTROL='{"me_audio_jobs": 2, "me_running_jobs": 1, "voice_max_characters": 80}'，
两句一批）。两件事：
1. fallback_used：先做完的那一批说服务器在里面换了备用 → 还没交的批改带 voice_plan.fallback.selection，结果的 line_models 写清哪几句
   是哪个模型读的、voice.note 提醒前后可能听得出差别；已经交出去的不重做。
2. fallback_needs_one_time（声音库的声音，MiniMax 版还没建、照 IndexTTS2 读）：那一批默认出错、备用要先建 MiniMax 版 → 那一批没扣钱、
   别的批收好，任务以可恢复的 failed 结束，get_job 问一次性费用（结束码不带价，SkyCut 自己报 voice_enroll 的价）；resume + 令牌建，
   建完 resume + generate_missing 只补那一批（新 key、原来的选择），一次落地。结果留在 voice-fallback-results.json。"""
import json
import time

from voice_smoke_support import D, WORK, Smoke, control, log, release, rows, wait_until

LINE = {"text": "Hello world, this is the first line."}
s = Smoke()
report = {}


def posts(mark, kind):
    return rows(log()[mark:], "POST", "/jobs", kind=kind)


def fallback_used():
    project = s.call("new_project", {"version": "fallback-used-" + str(time.time_ns())})["project"]
    control(hold_kinds=["voice"], voice_job_outcomes=["fallback_used"])
    mark = len(log())
    started = s.call("add_voiceover", {"project": project, "lines": [LINE] * 6, "subtitles": True})
    assert started["status"] == "started" and started["batches"] == 3, started
    wait_until(lambda: len(posts(mark, "voice")) == 2)
    release(count=1, kind="voice")  # 先交上去的那一单带着 fallback_used
    wait_until(lambda: len(posts(mark, "voice")) == 3, 60)
    plans = [row["body"]["params"]["plan"]["model"] for row in posts(mark, "voice")]
    assert plans == ["gemini-3.8-flash-tts", "gemini-3.8-flash-tts", "eleven-v4"], plans
    release(kind="voice")
    done = s.wait(started["job_id"])
    assert done["status"] == "done", done
    models = [entry["model"] for entry in done["line_models"]]
    assert sorted(set(models)) == ["eleven-v4", "gemini-3.8-flash-tts"] and models.count("eleven-v4") == 4, done["line_models"]
    assert "fallback" in done["voice"]["note"] and "line_models" in done["next_step"], done
    assert s.timeline_counts(project) == (6, 6)
    report["fallback_used"] = {"plans": plans, "line_models": models, "note": done["voice"]["note"]}
    s.call("close_project", {"project": project})


def library_voice():
    args = {"action": "create", "file": "voice-sample.wav", "language": "en", "name": "Fallback Voice"}
    asked = s.call("manage_voices", args)
    assert asked["status"] == "needs_confirmation", asked
    created = s.call("manage_voices", {**args, "confirm_token": asked["confirm_token"]})  # 扮演测试用户确认授权那句
    return created["voice"]["id"]


def fallback_fee():
    voice = library_voice()
    project = s.call("new_project", {"version": "fallback-fee-" + str(time.time_ns())})["project"]
    control(hold_kinds=["voice_clone"], voice_job_outcomes=["fallback_needs_one_time"])
    mark = len(log())
    args = {"project": project, "lines": [LINE] * 4, "voice": voice, "subtitles": True, "skip_one_time": True}
    started = s.call("add_voiceover", args)
    assert started["status"] == "started" and started["voice_plan"]["selection"]["model"] == "index-tts-2", started
    wait_until(lambda: len(posts(mark, "voice_clone")) == 2)
    first_keys = [row["body"]["idempotency_key"] for row in posts(mark, "voice_clone")]
    release(count=1, kind="voice_clone")  # 先交上去的那一批：默认出错、备用要先建 MiniMax 版
    release(kind="voice_clone")
    failed = s.wait(started["job_id"])
    control(hold_kinds=[])
    text = json.dumps(failed, ensure_ascii=False)
    assert failed["status"] == "failed" and "fallback_needs_one_time" in text and failed.get("confirm_token"), failed
    assert failed["one_time"][0]["credits"] == 375 and failed["not_generated_batch_indices"], failed
    assert rows(log()[mark:], "POST", "/quote", kind="voice_enroll"), "SkyCut prices the fee itself when the end code carries none"
    recovery = failed["recovery_file"]
    enroll = s.call("add_voiceover", {"project": project, "resume": recovery, "confirm_token": failed["confirm_token"]})
    assert enroll["status"] == "started" and enroll["kind"] == "voice_enroll", enroll
    assert s.wait(enroll["job_id"])["status"] == "done"
    fill_mark = len(log())
    filled = s.call("add_voiceover", {"project": project, "resume": recovery, "generate_missing": True})
    done = s.wait(filled["job_id"])
    assert done["status"] == "done", done
    resent = posts(fill_mark, "voice_clone")
    assert len(resent) == 1 and resent[0]["body"]["idempotency_key"] not in first_keys, "only the refunded batch, with a new key"
    assert s.timeline_counts(project) == (4, 4)
    report["fallback_needs_one_time"] = {"question": failed.get("question"), "retry_plan": resent[0]["body"]["params"]["plan"],
                                         "enroll_credits": failed["one_time"][0]["credits"]}
    s.call("close_project", {"project": project})


try:
    setup = control()
    assert (setup.get("me_audio_jobs"), setup.get("voice_max_characters")) == (2, 80), \
        "Start run.sh with SKYSTUDIO_SMOKE_CONTROL='{\"me_audio_jobs\": 2, \"me_running_jobs\": 1, \"voice_max_characters\": 80}'"
    s.call("get_status")
    s.call("open_folder", {"path": str(WORK)})
    s.call("set_view", {"mode": "background"})
    fallback_used()
    fallback_fee()
    control(hold_kinds=[], voice_job_outcomes=[])
    (D / "voice-fallback-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print("PASS fallback: fallback_used switches the unsent batches and reports line_models; fallback_needs_one_time keeps the other "
          "batches, asks the priced fee in get_job, enrols on the token and generate_missing resends only the refunded batch")
finally:
    s.close()
