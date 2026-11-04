"""真后台 App/MCP 官方三阶段验收；假服务和合成素材，无生产配方、外网生成或真实积分。"""
from copy import deepcopy
import json
import os
import shutil
import sys
import time

sys.dont_write_bytecode = True
from official_client import Session, WORK, admitted, control, log, posts
from official_story import story
from production_smoke import author


def key(label):
    return "official-" + label + "-" + str(time.time_ns())


def prepare(session, base):
    args = {**base, "prepare_references": True, "idempotency_key": key("prepare")}
    before, mark = session.spent(), len(log())
    start = session.call("generate_media", args)
    assert start["status"] == "preparing_references", start
    done = session.wait(start["job_id"])
    again = session.call("generate_media", args)
    assert again["job_id"] == start["job_id"], "Preparation key must reuse its original task"
    assert done["charged"] is False and session.spent() == before
    assert not posts(log()[mark:]) and not posts(log()[mark:], "quote")
    assert done["inputs"]["image_url"].startswith("https://assets.skycut-smoke.invalid/originals/local-smoke/")
    assert done["inputs"]["last_frame_url"] != done["inputs"]["image_url"], "First/last roles retain distinct uploaded originals"
    assert done["prepared_render"]["inputs"] == done["inputs"] and done["prepared_render"]["params"]["duration"] == base["duration"]
    assert len(posts(log()[mark:], "uploads")) in (0, 2), "A repeated prepare must not upload twice"
    return done


def quote(session, base, prepared):
    # 保存无输出的完整公开故事，再报价；真正输出审查由独立 production 场景承担。
    film = author(session, base["project"], story(prepared["inputs"], prepared["prepared_render"]), prepared["prepared_render"])
    args = {**base, "film": film, "prepared_references": prepared["prepared_references"]}
    mark, before = len(log()), session.spent()
    result = session.call("generate_media", {**args, "quote_only": True, "idempotency_key": key("quote")})
    assert result["status"] == "quoted" and result["uploaded"] is False and result["charged"] is False
    assert all(result["seam_review"][side] for side in ("previous", "next")), result
    assert result["official_recipe"]["preflight_only"] is True
    assert not posts(log()[mark:]) and not posts(log()[mark:], "uploads") and session.spent() == before
    sent = posts(log()[mark:], "quote")
    assert len(sent) == 1 and sent[0]["inputs"] == prepared["inputs"]
    assert sent[0]["film"] == args["film"], "Quote must preserve complete actual neighbor declarations"
    return {**args, "quote_token": result["quote_token"], "seam_review": result["seam_review"], "idempotency_key": key("submit")}, result


def invalidations(session, base, prepared, submit):
    session.refused({**base, "film": submit["film"], "quote_only": True})
    for side in ("previous", "next"):
        changed = deepcopy(submit)
        changed["seam_review"][side] = None
        session.refused(changed)
    session.refused({**submit, "seam_review": {"previous": "stale", "next": submit["seam_review"]["next"]}})
    for changes in [dict(prompt="A different original view."), dict(duration=4), dict(name="changed destination"),
                    dict(quote_token="quote-does-not-exist"), dict(prepared_references="refs-does-not-exist"),
                    dict(image=base["last_image"], last_image=base["image"])]:
        session.refused({**submit, **changes})
    changed = deepcopy(submit)
    changed["film"]["next"]["render"]["prompt"] = "The same room from another angle."
    session.refused(changed)
    changed = deepcopy(submit)
    del changed["film"]["next"]
    session.refused(changed)
    other = session.call("new_project", {"name": "Official isolated", "version": key("other")})
    session.refused({**submit, "project": other["project"]})
    session.call("close_project", {"project": other["project"]})
    mark = len(log())
    repeat, _ = quote(session, base, prepared)
    assert not posts(log()[mark:], "uploads"), "More quotes cannot re-upload prepared images"
    # 只变本轮复制的合成源文件身份；不碰用户素材或生成结果。
    file = WORK / base["last_image"]
    stat = file.stat()
    os.utime(file, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
    session.refused(submit)
    session.refused({**base, "film": repeat["film"], "prepared_references": prepared["prepared_references"], "quote_only": True})
    session.passed_case("both seams, changed request/token/order/project/file reject before paid work")


def failures(session, base, prepared):
    film = author(session, base["project"], story(prepared["inputs"], prepared["prepared_render"]), prepared["prepared_render"])
    args = {**base, "film": film, "prepared_references": prepared["prepared_references"], "quote_only": True}
    for failure in ("unavailable", "unsupported"):
        control(official_failure=failure)
        result = session.refused({**args, "idempotency_key": key(failure)})
        assert ("recipe" if failure == "unavailable" else "context") in json.dumps(result).lower(), result
    control(official_failure=None, official_quote_seconds=-1)
    session.refused({**args, "idempotency_key": key("expired")})
    control(official_quote_seconds=300)
    submitted, _ = quote(session, {**base, "name": key("disabled-after-quote")}, prepared)
    mark, before, count = len(log()), session.spent(), admitted()
    control(official_failure="unavailable")
    started = session.call("generate_media", submitted)
    assert started["status"] == "started", started
    failed = session.wait(started["job_id"], "failed")
    assert len(posts(log()[mark:])) == 1 and admitted() == count, "Rejected HTTP request is not an admitted provider job"
    assert session.spent() == before and not failed.get("credits_unknown", False), failed
    control(official_failure=None)
    session.passed_case("recipe unavailable, unsupported context and expired quote fail without admission")
    return submitted


def slot_revalidation(session, base, prepared):
    submitted, _ = quote(session, {**base, "name": key("slot-wait")}, prepared)
    mark, before, count = len(log()), session.spent(), admitted()
    control(official_slot_full=True)
    try:
        start = session.call("generate_media", submitted)
        assert start["status"] == "started", start
        deadline = time.monotonic() + 20
        while not posts(log()[mark:]):
            assert time.monotonic() < deadline, "Official job did not reach its first slot refusal"
            time.sleep(.1)
        assert admitted() == count, "A slot refusal must not admit a provider job"
        # 只改合成夹具的文件身份，发生在运行器的实际15秒等待内。
        file = WORK / base["image"]
        stat = file.stat()
        os.utime(file, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        control(official_slot_full=False)
        failed = session.wait(start["job_id"], "failed")
        assert failed["recovery_state"] == "confirmed_not_submitted" and failed["rejection_code"] == "local_not_sent", failed
        assert failed["charged"] is False and failed["recovery_evidence_saved"] is True, failed
        assert not failed.get("credits_unknown", False) and session.spent() == before, failed
        assert len(posts(log()[mark:])) == 1 and admitted() == count, "Changed references must block the second POST after slot wait"
        assert session.call("generate_media", submitted)["job_id"] == start["job_id"]
        session.passed_case("slot wait rechecks actual original files before another POST; rejected operation refunds and retires its key")
        return submitted
    finally:
        control(official_slot_full=False)


def render_review(session, project, file):
    session.call("add_clips", {"project": project, "clips": [
        {"file": file, "source_in": 0, "source_out": 2, "start": start, "track": "V1"} for start in (0, 2, 4)]})
    session.call("add_clips", {"project": project, "clips": [{"file": "reference.wav", "source_out": 6, "track": "A1", "start": 0}]})
    timeline = session.call("get_timeline", {"project": project})
    clips = [clip for track in timeline["tracks"] for clip in track["clips"]]
    videos = [clip for clip in clips if clip["kind"] == "video"]
    assert len(videos) == 3, videos
    session.look({"project": project, "file": file, "times": [0, .25, .5, 1, 1.5, 1.95]}, "source-used-frames")
    session.look({"project": project, "times": [1.5, 1.95, 2, 2.25, 2.5, 3, 3.5, 3.95, 4, 4.25]}, "both-composed-seams")
    levels = session.call("listen", {"project": project, "from": 1.5, "to": 4.5})
    assert any(clip.get("level_db", -120) > -60 for clip in levels["clips"]), levels
    encoded = session.call("export_video", {"project": project, "preset": "quick_review", "name": key("review")})
    exported = session.wait(encoded["job_id"])
    session.look({"project": project, "file": exported["path"], "times": [1.95, 2, 2.25, 3.95, 4, 4.25]}, "export-seams")
    inspected = session.call("inspect_video", {"project": project, "file": exported["path"], "from": 1.5, "to": 4.5})
    findings = session.wait(inspected["job_id"])
    (session.evidence / "inspection.json").write_text(json.dumps(findings, indent=2))
    (session.evidence / "measured-audio.json").write_text(json.dumps(levels, indent=2))
    session.background(project)
    session.passed_case("background MCP import/export; used-frame and both-seam contact sheets; measured mixed sound")


def approval_and_budget(session, base):
    def settings(args):
        result = session.call("set_settings", args)
        if result.get("status") == "needs_confirmation":
            # 仅假账户：模拟夹具用户明确同意，绝不替真实用户批准消费或权限。
            result = session.call("set_settings", {**args, "confirm_token": result["confirm_token"]})
        return result

    initial = session.call("get_settings")["sections"]
    limit = initial["sky_studio"]["daily_ai_credit_limit"]
    mode = initial["ai"]["ai_access_mode"]
    settings({"ai_access_mode": "ask_for_approval"})
    try:
        premium = {**base, "duration": 6, "name": key("approval")}
        prepared = prepare(session, premium)
        submitted, quoted = quote(session, premium, prepared)
        mark, before = len(log()), session.spent()
        question = session.call("generate_media", submitted)
        assert question["status"] == "needs_confirmation", question
        again = session.call("generate_media", submitted)
        assert again["confirm_token"] == question["confirm_token"], "Pending exact action keeps its confirmation"
        wrong = session.call("generate_media", {**submitted, "confirm_token": "unrelated-confirmation-token"})
        assert not posts(log()[mark:]) and session.spent() == before, "Questions and refused tokens cannot reserve or POST"
        approved = {**submitted, "confirm_token": question["confirm_token"]}
        start = session.call("generate_media", approved)
        assert start["status"] == "started", start
        assert wrong["status"] == "needs_confirmation" and wrong.get("confirm_token_refused"), wrong
        session.wait(start["job_id"])
        for request in (submitted, approved):
            assert session.call("generate_media", request)["job_id"] == start["job_id"]
        assert len(posts(log()[mark:])) == 1 and session.spent() == before + quoted["credits"]
        session.passed_case("same operation key redeems exact official confirmation, then repeats its one original job")

        prepared = prepare(session, base)
        submitted, quoted = quote(session, {**base, "name": key("budget")}, prepared)
        settings({"daily_ai_credit_limit": 0})
        mark, before = len(log()), session.spent()
        blocked = session.call("generate_media", submitted)
        assert blocked["status"] == "blocked" and blocked["code"] == "daily_budget_exceeded", blocked
        assert not posts(log()[mark:]) and session.spent() == before
        settings({"daily_ai_credit_limit": limit})
        start = session.call("generate_media", submitted)
        assert start["status"] == "started", start
        session.wait(start["job_id"])
        assert session.call("generate_media", submitted)["job_id"] == start["job_id"]
        assert len(posts(log()[mark:])) == 1 and session.spent() == before + quoted["credits"]
        session.passed_case("budget refusal retires no operation; explicit fake-user budget restoration lets the same key submit once")
    finally:
        settings({"ai_access_mode": mode, "daily_ai_credit_limit": limit})


def submissions(session, base, prepared):
    submit, quoted = quote(session, base, prepared)
    mark, before = len(log()), session.spent()
    control(quotes_by_prompt={base["prompt"]: quoted["credits"] + 1})
    start = session.call("generate_media", submit)
    assert start["status"] == "started", start
    done = session.wait(start["job_id"])
    duplicate = session.call("generate_media", submit)
    assert duplicate["job_id"] == start["job_id"] and session.spent() == before + quoted["credits"]
    submitted = posts(log()[mark:])
    assert len(submitted) == 1 and submitted[0]["max_credits"] == quoted["credits"]
    assert submitted[0]["seam_review"] == quoted["seam_review"] and submitted[0].get("recipe_pin")
    assert submitted[0]["inputs"] == prepared["inputs"] and submitted[0]["film"] == submit["film"]
    assert not posts(log()[mark:], "quote") and not posts(log()[mark:], "uploads"), "Submit must use the pinned original request"
    session.refused({**submit, "idempotency_key": key("second-submit")})
    control(quotes_by_prompt={})
    session.passed_case("exact quote price and pin submit once; repeated operation key does not charge twice")
    render_review(session, base["project"], done["file"])
    unknown, _ = quote(session, {**base, "name": key("unknown")}, prepared)
    control(unknown_submission=True)
    mark = len(log())
    started = session.call("generate_media", unknown)
    outcome = session.wait(started["job_id"], "failed")
    assert outcome["credits_unknown"] is True, outcome
    assert session.call("generate_media", unknown)["job_id"] == started["job_id"]
    assert len(posts(log()[mark:])) == 1
    control(unknown_submission=False, official_delivery_failure=True)
    known, _ = quote(session, {**base, "name": key("known")}, prepared)
    started = session.call("generate_media", known)
    failure = session.wait(started["job_id"], "failed")
    assert failure.get("skystudio_job_id") or failure.get("remote_result"), failure
    control(official_delivery_failure=False)
    session.passed_case("lost submit and known delivery failure retain original operation without replay")
    return unknown, known


def recovery(session, project_path, rejected, unknown, known, slot_refused):
    project = known["project"]
    production = session.call("get_timeline", {"project": project})["production"]
    assert production and production["plan"]["shots"], "Recovery fixture must first persist a real authored plan"
    session.call("save_project", {"project": project, "production": None, "expected_revision": production["revision"]})
    assert session.call("get_timeline", {"project": project}).get("production") is None
    session.call("undo", {"project": project, "steps": 1})
    restored = session.call("get_timeline", {"project": project})["production"]
    assert restored["revision"] == production["revision"] and restored["plan"] == production["plan"]
    session.call("save_project", {"project": project, "production": None, "expected_revision": restored["revision"]})
    assert session.call("get_timeline", {"project": project}).get("production") is None
    # 制作计划可 clear/undo；原单回执不在时间线中。重启后缺计划仍不能重放，也不能阻断原单 GET。
    session.restart("T")
    other_account_project = session.call("open_project", {"path": project_path})["project"]
    session.refused({**known, "project": other_account_project})
    session.passed_case("another account cannot reuse original account's ephemeral tokens")
    session.restart("S")
    project = session.call("open_project", {"path": project_path})["project"]
    assert session.call("get_timeline", {"project": project}).get("production") is None, "Cleared production must remain absent after restart"
    mark, before = len(log()), session.spent()
    for args, expected in [(rejected, "not_submitted"), (slot_refused, "not_submitted"), (unknown, "unknown"), (known, "recovering")]:
        request_mark = len(log())
        recovered = session.call("generate_media", {**args, "project": project})
        assert recovered["status"] == expected and recovered["submitted_again"] is False, recovered
        if expected == "recovering":
            done = session.wait(recovered["job_id"])
            assert done["recovery_state"] == "recovered" and done["local_budget_reconciliation"] == "pending", done
            session.look({"project": project, "file": done["file"], "times": [0, 1]}, "recovered-original")
        elif expected == "unknown":
            assert recovered["recovery_state"] == "cloud_outcome_unknown", recovered
            assert not [row for row in log()[request_mark:] if not row["path"].endswith("/me")], "Unknown receipt must perform no task requests"
        else:
            assert recovered["recovery_state"] == "confirmed_not_submitted" and recovered["charged"] is False
            expected_code = "local_not_sent" if args is slot_refused else "recipe_unavailable"
            assert recovered["rejection_code"] == expected_code and "job_id" not in recovered
            assert not [row for row in log()[request_mark:] if not row["path"].endswith("/me")], "Rejected key remains retired without task requests"
    rows = log()[mark:]
    assert not any(row["method"] in ("POST", "PUT") for row in rows), "Recovery must only read original tasks/files"
    assert any(row["method"] == "GET" and "/jobs/" in row["path"] for row in rows), "Known recovery must poll original server id"
    assert session.spent() == before
    assert session.call("get_timeline", {"project": project}).get("production") is None, "GET-only recovery must not recreate a story"
    session.refused({**known, "project": project, "prompt": "A changed request cannot recover this key."})
    session.call("close_project", {"project": project})
    session.passed_case("restart after clearing production: rejected key stays no-charge; unknown key blocks replay; known id only GETs original")


def run():
    session = Session()
    try:
        control(official=True, official_failure=None, official_quote_seconds=300, official_delivery_failure=False,
                official_slot_full=False,
                hold=False, quote_error=False, unknown_submission=False, refuse_seedance=False,
                delivery_failure=False, billing_pending=False, settle_refund=False, quotes_by_prompt={})
        status = session.call("get_status")
        assert not status["jobs"], "Do not run alongside another task in this test App"
        assert not any(project.get("path") for project in status["projects"]), "Use a fresh isolated smoke App"
        # 仅复制 run.sh 造的无版权测试源；所有正式剪辑/生成/检查都走 MCP。
        first, last = key("first") + ".png", key("last") + ".png"
        shutil.copyfile(WORK / "subject.png", WORK / first)
        shutil.copyfile(WORK / "subject.png", WORK / last)
        session.call("open_folder", {"path": str(WORK)})
        session.call("set_view", {"mode": "background"})
        created = session.call("new_project", {"name": "Official isolated", "version": key("main")})
        project = created["project"]
        session.background(project)
        session.ownership(project)
        session.passed_case("own background project; second helper cannot read or claim active project")
        mark, before = len(log()), session.spent()
        specification = session.call("generate_media", dict(project=project, kind="text_to_video", model="minimax-h3",
            prompt="An original empty room.", duration=3, prepare_references=True, idempotency_key=key("spec")))
        specification = session.wait(specification["job_id"])
        assert specification["prepared_render"]["inputs"] == {} and "prepared_references" not in specification
        assert not any(row["method"] in ("POST", "PUT") for row in log()[mark:]) and session.spent() == before
        session.passed_case("text-only normalized specification prepares without uploads, quotes or paid jobs")
        base = dict(project=project, kind="image_to_video", model="minimax-h3", prompt="An original still blue room.",
                    image=first, last_image=last, duration=3, resolution="768p", name=key("render"))
        prepared = prepare(session, base)
        submit, _ = quote(session, base, prepared)
        session.passed_case("prepare uploads actual originals once; official quote has two seams and never uploads")
        invalidations(session, base, prepared, submit)
        prepared = prepare(session, base)
        slot_refused = slot_revalidation(session, base, prepared)
        prepared = prepare(session, base)
        rejected = failures(session, base, prepared)
        approval_and_budget(session, base)
        unknown, known = submissions(session, base, prepared)
        session.call("save_project", {"project": project})
        recovery(session, created["created"], rejected, unknown, known, slot_refused)
        assert all(not row["has_auth"] for row in log() if row["method"] == "PUT" or row["path"].startswith("/files/"))
        report = dict(result="passed", cases=session.passed, fake_admitted_jobs=admitted(), real_provider_calls=0, production_recipes_enabled="not tested",
                      production_concurrency="not tested", sound_evidence="measured; no subjective listening claim",
                      video_evidence="synthetic fixture only; MCP contact sheets produced, visual review not yet claimed")
        (session.evidence / "report.json").write_text(json.dumps(report, indent=2))
        print("Evidence: " + str(session.evidence), flush=True)
    finally:
        session.close()


if __name__ == "__main__":
    run()
