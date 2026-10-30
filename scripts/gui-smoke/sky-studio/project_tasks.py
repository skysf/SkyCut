"""工程卡片 / MCP 的免费端到端：真 App、真小程序、回环假服务；完成后留窗口供界面验收。"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
SERVER = "http://127.0.0.1:18766"
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"),
          env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(tool, args=None):
    result, error = mcp.call(tool, args, timeout=90)
    assert not error, (tool, result)
    return result


def control(**values):
    request = urllib.request.Request(SERVER + "/__control", json.dumps(values).encode(),
                                     {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def server_log():
    with urllib.request.urlopen(SERVER + "/__log", timeout=10) as response:
        return json.load(response)


def wait_status(condition, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = call("get_status")
        if condition(result):
            return result
        time.sleep(0.2)
    raise AssertionError(("Timed out waiting for task report", result))


def make_project(name):
    project = call("new_project", {"name": name, "version": "cards-" + str(time.time_ns())})["project"]
    call("add_clips", {"project": project, "clips": [{"file": "motion.mp4"}]})
    return project


def generate(project, kind, name):
    model = "nano2" if kind == "image" else "minimax-h3"
    started = call("generate_media", {"project": project, "kind": kind, "model": model, "name": name, "prompt": name})
    assert started["status"] == "started", started
    return started["job_id"]


def verify_report(status, projects, jobs):
    report = status["cloud_tasks"]
    assert report["summary"]["active_count"] == 5, report
    assert report["summary"]["queued_count"] == 5, report
    assert report["summary"]["estimated_credits"] == 225, report
    groups = {item["project"]: item for item in report["projects"] if item["project_open"]}
    assert [groups[p]["summary"]["active_count"] for p in projects] == [2, 2, 1], groups
    tasks = [task for group in groups.values() for task in group["tasks"]]
    assert {t["media_type"] for t in tasks} == {"video", "audio", "image"}, tasks
    assert {t["job_id"] for t in tasks} == set(jobs), tasks
    for task in tasks:
        assert task["phase"] == "queued" and task.get("skystudio_job_id"), task
        assert "transfer_percent" not in task, task
    opened = {p["id"]: p for p in status["projects"]}
    for project in projects:
        assert opened[project]["cloud_task_summary"] == groups[project]["summary"]
        assert set(opened[project]["cloud_task_ids"]) == {t["task_id"] for t in groups[project]["tasks"]}
    return groups


try:
    call("open_folder", {"path": str(D / "work")})
    control(hold=True, quotes_by_prompt={"卡片视频一": 80, "卡片视频二": 80, "卡片图片一": 32,
                                       "卡片图片二": 32, "卡片失败提示": 120},
            cancel_already_started=False, refuse_seedance=False, submit_refusal=False)
    current = make_project("当前工程")
    jobs = [generate(current, "text_to_video", "卡片视频一")]
    voice = call("add_voiceover", {"project": current, "lines": [{"text": "A queued voiceover for the card preview."}]})
    assert voice["status"] == "started", voice
    jobs.append(voice["job_id"])
    second = make_project("另一个窗口")
    jobs += [generate(second, "text_to_video", "卡片视频二"), generate(second, "image", "卡片图片一")]
    background = make_project("后台工程")
    call("set_view", {"project": background, "mode": "background"})
    jobs.append(generate(background, "image", "卡片图片二"))
    projects = [current, second, background]
    status = wait_status(lambda s: s.get("cloud_tasks", {}).get("summary", {}).get("queued_count") == 5)
    groups = verify_report(status, projects, jobs)
    assert groups[background]["shown_in"] == "background (no window)"
    for job_id in jobs:
        progress = call("get_job", {"job_id": job_id})
        assert progress["phase"] == "queued" and progress.get("skystudio_job_id"), progress

    # 真实后台开窗路径：与卡片复用的注册表 showWindow / focus 是同一套窗口。
    call("set_view", {"project": background, "mode": "visible"})
    visible = call("get_status")
    visible_groups = verify_report(visible, projects, jobs)
    assert visible_groups[background]["shown_in"] == "own window", visible_groups
    call("set_view", {"project": background, "mode": "background"})

    # 一个失败任务的工程关闭后，提示仍归原 token，不伪装成开着的新工程。
    closed = make_project("已关闭工程的问题")
    control(refuse_seedance=True, submit_refusal=True)
    started = call("generate_media", {"project": closed, "kind": "text_to_video", "model": "seedance-2-5",
                                     "name": "需处理的原工程任务", "prompt": "卡片失败提示", "auto_fallback": False})
    failed = mcp.wait_job(started["job_id"], 40)
    assert failed["status"] == "failed", failed
    call("close_project", {"project": closed})
    control(refuse_seedance=False, submit_refusal=False)
    status = wait_status(lambda s: s["cloud_tasks"]["summary"]["needs_attention_count"] == 1)
    verify_report(status, projects, jobs)
    issue_group = next(g for g in status["cloud_tasks"]["projects"] if g["project"] == closed)
    assert not issue_group["project_open"] and issue_group["shown_in"] == "closed", issue_group
    assert issue_group["tasks"][0]["issue"], issue_group
    assert issue_group["tasks"][0]["skystudio_job_id"], issue_group
    assert closed not in {p["id"] for p in status["projects"]}

    before_posts = [x for x in server_log() if x["method"] == "POST" and x["path"].endswith("/jobs")]
    before_spend = status["generation"]["spent_today_credits"]
    for _ in range(2):
        observed = call("get_status")
        verify_report(observed, projects, jobs)
        assert observed["generation"]["spent_today_credits"] == before_spend
    after_posts = [x for x in server_log() if x["method"] == "POST" and x["path"].endswith("/jobs")]
    assert len(before_posts) == len(after_posts), "status queries must never submit work"
    observer = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"),
                   env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
    try:
        observed, error = observer.call("get_status", timeout=30)
        assert not error, observed
        verify_report(observed, projects, jobs)
        assert observed["generation"]["spent_today_credits"] == before_spend
    finally:
        observer.close()
    (D / "project-task-report.json").write_text(json.dumps(status, ensure_ascii=False, indent=2))
    (D / "project-task-ids.json").write_text(json.dumps(dict(projects=projects, jobs=jobs, closed=closed)))
    print("PASS: 5 queued tasks / 225 credits; video, audio, image; per-project MCP details; real background window; retained closed-project issue; read-only queries.")
    print("READY: open task popovers in the two visible windows; current projects differ, global total stays 5, one issue stays visible.")
finally:
    mcp.close()
