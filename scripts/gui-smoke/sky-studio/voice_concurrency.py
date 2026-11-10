"""几批同时交的旁白（SkyCut 声音 PR 4，方案 8.2、9.2）：真 App、真小程序、真入轨、真撤销，假 Sky Studio。
要 run.sh 这样起：SKYSTUDIO_SMOKE_CONTROL='{"me_audio_jobs": 2, "me_running_jobs": 1, "voice_max_characters": 80}'
（/me 的两个池和 /models 的字数上限 App 一启动就读、之后缓存着，只能在起服务时定）。十句同样的话按 80 字一批分成 5 批。
看：声音池 2 个槽（2 批在飞、3 批在本机等）、共用池 1 个槽且不被声音池挡（图片 A 照交、B 在本机等）、get_job 报几批好了 / 共几批 / 在跑 / 在等；
中途停：Sky Studio 排着队的取消退钱、已开始的照实说并接着查到底、本机在等的离队；恢复：默认只拿回已有的、generate_missing 只补没做的
（照记录的选择再报价；声音池回一次 429，同一个 idempotency_key 等 15 秒再交）；全部好了一次落地、一步撤销。结果留在 voice-concurrency-results.json。"""
import json
import time

from voice_smoke_support import D, WORK, Smoke, control, log, release, rows, server, wait_until

LINES = [{"text": "Hello world, this is the first line."}] * 10
s = Smoke()
report = {"boards": []}


def job(job_id):
    return s.call("get_job", {"job_id": job_id})


def board(job_id, done, running, waiting):
    """get_job 里几批好了 / 在跑 / 在等，等到正好是这几个数（照 SkyStudioVoiceBatchBoard，状态行的「n/5 batches」也是它）。"""
    def matches():
        value = job(job_id)
        seen = (value.get("batches_done"), value.get("batches_running"), value.get("batches_waiting"))
        return value if seen == (done, running, waiting) else None
    value = wait_until(matches, 60, 0.5)
    assert value["batch_count"] == 5, value
    report["boards"].append(f"{done}/5 done, {running} running, {waiting} waiting")
    return value


def posts(mark, kind):
    return rows(log()[mark:], "POST", "/jobs", kind=kind)


def image(project, name):
    args = {"project": project, "kind": "image", "model": "nano2", "prompt": "Pool smoke " + name, "name": name}
    result = s.call("generate_media", args)
    if result.get("status") == "needs_confirmation":
        result = s.call("generate_media", {**args, "confirm_token": result["confirm_token"]})  # 扮演测试用户点头
    assert result["status"] == "started", result
    return result["job_id"]


try:
    setup = control()
    assert (setup.get("me_audio_jobs"), setup.get("me_running_jobs"), setup.get("voice_max_characters")) == (2, 1, 80), \
        "Start run.sh with SKYSTUDIO_SMOKE_CONTROL='{\"me_audio_jobs\": 2, \"me_running_jobs\": 1, \"voice_max_characters\": 80}'"
    s.call("get_status")
    s.call("open_folder", {"path": str(WORK)})
    s.call("set_view", {"mode": "background"})
    project = s.call("new_project", {"version": "pools-" + str(time.time_ns())})["project"]
    control(hold_kinds=["voice", "image"])
    mark = len(log())
    started = s.call("add_voiceover", {"project": project, "lines": LINES, "subtitles": True})
    assert started["status"] == "started" and started["batches"] == 5 and started["subtitle_timing"] == "aligned", started
    narration = started["job_id"]
    # 声音池 2 个槽：两批交上去（Sky Studio 排着队），三批在本机等。
    wait_until(lambda: len(posts(mark, "voice")) == 2)
    board(narration, 0, 2, 3)
    time.sleep(3)
    assert len(posts(mark, "voice")) == 2, "the audio pool keeps at most 2 batches in flight"
    keys = [row["body"]["idempotency_key"] for row in posts(mark, "voice")]
    assert all(row["body"]["params"]["plan"] == posts(mark, "voice")[0]["body"]["params"]["plan"] for row in posts(mark, "voice"))
    # 共用池 1 个槽、不被声音池挡：图片 A 照交，B 在本机等到 A 做完。
    first = image(project, "A")
    wait_until(lambda: len(posts(mark, "image")) == 1)
    second = image(project, "B")
    time.sleep(3)
    assert len(posts(mark, "image")) == 1, "the shared pool keeps at most 1 job in flight"
    release(kind="image")
    assert s.wait(first, 60)["status"] == "done"
    wait_until(lambda: len(posts(mark, "image")) == 2)
    release(kind="image")
    assert s.wait(second, 60)["status"] == "done"
    # 共用池回一次 429（别处占满了）：拿着槽等 15 秒、同一个 idempotency_key 再交。
    control(pool_full={"default": 1}, hold_kinds=["voice"])
    third = image(project, "C")
    assert s.wait(third, 90)["status"] == "done"
    sent = [row["body"]["idempotency_key"] for row in posts(mark, "image")]
    assert len(sent) == 4 and sent[2] == sent[3], "the shared-pool 429 is retried once with the same key"
    assert len(posts(mark, "voice")) == 2, "image jobs never took an audio slot"
    # 放一批：做完还槽，下一批交上去。
    release(count=1, kind="voice")
    board(narration, 1, 2, 2)
    wait_until(lambda: len(posts(mark, "voice")) == 3)
    # 中途停：再放一批但让它慢（停的时候在 Sky Studio 那边已经开始了），另一批还排着队，两批在本机等。
    control(voice_job_seconds=8)
    release(count=1, kind="voice")
    wait_until(lambda: any(j["status"] == "running" and j["kind"] == "voice" for j in server("/__jobs")))
    cancel_mark = len(log())
    s.call("cancel_job", {"job_id": narration})
    stopped = s.wait(narration, 90)
    assert stopped["status"] == "cancelled", stopped
    cancels = rows(log()[cancel_mark:], "POST", "/cancel")
    states = {j["job_id"]: j["status"] for j in server("/__jobs") if j["kind"] == "voice"}
    assert len(cancels) == 2 and sorted(states.values()).count("cancelled") == 1, (cancels, states)
    assert len(posts(mark, "voice")) == 3, "batches still waiting for a slot leave the queue without being submitted"
    recovery = stopped["recovery_file"]
    report["stopped"] = {k: stopped.get(k) for k in ("message", "completed_line_indices", "pending_recovery_line_indices",
                                                     "not_generated_line_indices", "batches_done", "batches_running", "batches_waiting")}
    # 恢复（默认）：只拿回已有的音频（排着队被取消的、没交的都不补），不交新的。
    control(voice_job_seconds=0, hold_kinds=[])
    wait_until(lambda: all(state != "running" for state in
                           (j["status"] for j in server("/__jobs") if j["kind"] == "voice")), 30)
    resume_mark = len(log())
    plain = s.call("add_voiceover", {"project": project, "resume": recovery})
    plain_done = s.wait(plain["job_id"], 90)
    assert plain_done["status"] == "failed" and "generate_missing" in json.dumps(plain_done), plain_done
    assert not posts(resume_mark, "voice") and s.timeline_counts(project) == (0, 0), "a plain resume never pays and never lands half"
    # 恢复补没做的：照记录的选择再报一次价，声音池先回一次 429（同一个 key、等 15 秒再交）。
    control(pool_full={"audio": 1})
    fill_mark = len(log())
    filled = s.call("add_voiceover", {"project": project, "resume": recovery, "generate_missing": True})
    finished = s.wait(filled["job_id"], 180)
    assert finished["status"] == "done", finished
    new = posts(fill_mark, "voice")
    retried = [row for row in new if [r["body"]["idempotency_key"] for r in new].count(row["body"]["idempotency_key"]) == 2]
    assert len(new) == 4 and len(retried) == 2, "three missing batches, one of them resent once after the 429 with the same key"
    assert not set(keys) & {row["body"]["idempotency_key"] for row in new}, "the batches already submitted are never resubmitted"
    requote = rows(log()[fill_mark:], "POST", "/quote", kind="voice")
    assert len(requote) == 1 and requote[0]["body"]["params"]["plan"]["model"] == "gemini-3.8-flash-tts", requote
    assert s.timeline_counts(project) == (10, 10), "all ten lines and subtitles land once"
    s.call("undo", {"project": project})
    assert s.timeline_counts(project) == (0, 0), "one undo removes the whole voiceover"
    report.update(resumed_lines=len(finished.get("added") or []), voice_posts=len(posts(mark, "voice")),
                  cancel_requests=len(cancels), server_states=states)
    s.call("close_project", {"project": project})
    (D / "voice-concurrency-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print("PASS concurrency: audio pool 2 in flight, shared pool 1 not blocked by audio, get_job batches done/running/waiting, "
          "stop cancels queued (refund) and keeps the started batch, waiting batches never sent, plain resume pays nothing, "
          "generate_missing resubmits only missing batches (429 retried with the same key), one landing, one undo")
finally:
    s.close()
