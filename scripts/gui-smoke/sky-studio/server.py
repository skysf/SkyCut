"""本机 Sky Studio 合同夹具：假 Key、原生 say 写文件、无外网、无积分。
起手的控制项可以从环境变量 SKYSTUDIO_SMOKE_CONTROL（JSON）给：/me 的两个池（me_running_jobs、me_audio_jobs）、
目录里读稿每批的字数上限（voice_max_characters）这些 App 一启动就读、之后缓存着的，只能在起服务时定。"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import media_fixtures
import model_expansion_fixtures as expansion
import voice_fixtures
import voice_library_fixtures as library
from official_fixtures import OfficialRecipes

PORT, ROOT, FFMPEG = int(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
ROOT.mkdir(parents=True, exist_ok=True)
BASE = f"http://127.0.0.1:{PORT}"
KEY = "sk-" + "S" * 43
LOCK = threading.RLock()
JOBS, KEYS, LOG, CONTROL = {}, {}, [], json.loads(os.environ.get("SKYSTUDIO_SMOKE_CONTROL") or "{}")
# 每个账号的长期授权（/voices/consent-grant，声音 PR 7）。
GRANTS, STANDING_VERSION = {}, voice_fixtures.CATALOG["voice_consent"]["standing"]["version"]
OFFICIAL = OfficialRecipes(ROOT)
# 和服务器 skycut_begin_job 同一份名单：这几种进声音池（SkyStudioJobSlots.audioKinds）。
AUDIO_KINDS = {"voice", "voice_clone", "voice_enroll", "voice_design", "voice_convert", "sound_effect"}
HIDDEN = ("prompt", "credits", "refuse", "polls", "account", "plan", "params", "held", "outcome")


def stamp(seconds=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).isoformat()


def synthesize(job):
    if job["kind"] in ("voice_enroll", "voice_design"):
        time.sleep(CONTROL.get("library_job_seconds", 1))
        with LOCK:
            library.finish(job, BASE, expansion.billing)
        return
    if job["model"] in {m["id"] for m in expansion.CATALOG["models"]}:
        with LOCK:
            expansion.finish(job, ROOT, BASE)
            if CONTROL.get("delivery_failure"):
                job["result"]["url"] = BASE + "/files/nonexistent.mp4"
            if CONTROL.get("billing_pending"):
                job.update(status="failed", error={"message": "Outcome unknown", "refunded": True},
                           billing=expansion.billing("pending_review", None))
        return
    if job["kind"] in ("image", "text_to_video", "image_to_video"):
        with LOCK:
            media_fixtures.finish(job, ROOT, BASE)
        return
    # 并发冒烟：每批在「处理中」停一会儿，几批同时在跑才看得见。
    time.sleep(CONTROL.get("voice_job_seconds", 0))
    if job.get("outcome") == "fallback_needs_one_time":
        with LOCK:
            voice_fixtures.fallback_needs_one_time(job, expansion.billing)
        return
    target = ROOT / (job["job_id"] + ".wav")
    import wave
    with wave.open(str(ROOT / "narration.wav")) as audio:
        params = audio.getparams()
        pcm = audio.readframes(audio.getnframes())
    repeats = len(job["prompt"].splitlines())
    with wave.open(str(target), "wb") as output:
        output.setparams(params)
        output.writeframes(pcm * repeats)
    duration = (len(pcm) / params.sampwidth / params.nchannels / params.framerate) * repeats
    chars = list(job["prompt"])
    # 每个 chunk 都用全局时间；末尾故意多 50ms，检验 App 按真实时长夹住。
    chunks = []
    for offset in range(0, len(chars), 7):
        indices = list(range(offset, min(offset + 7, len(chars))))
        chunks.append({"characters": [chars[i] for i in indices],
                       "character_start_times_seconds": [duration * i / len(chars) for i in indices],
                       "character_end_times_seconds": [duration * (i + 1) / len(chars) + (0.05 if i == len(chars) - 1 else 0) for i in indices]})
    outcome = voice_fixtures.outcome(job)
    with LOCK:
        job.update(status="done", result={"url": BASE + "/files/" + target.name,
                   "content_type": "audio/wav", "duration": duration,
                   "words": chunks if voice_fixtures.gives_words(job, outcome["model"]) else None, **outcome}, credits_charged=job["credits"])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, code, name):
        self.reply(code, {"error": {"code": name, "message": name}})

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_PUT(self):
        data = self.body()
        (ROOT / Path(self.path).name).write_bytes(data)
        with LOCK:
            LOG.append({"method": "PUT", "path": self.path, "bytes": len(data), "has_auth": "Authorization" in self.headers})
        self.reply(200, {})

    def do_GET(self):
        if self.path.startswith("/files/"):
            if CONTROL.get("official_delivery_failure") and Path(self.path).name.startswith("local-"):
                return self.error(503, "fixture_delivery_unavailable")
            file = ROOT / Path(self.path).name
            if not file.is_file():
                return self.error(404, "missing_file")
            data = file.read_bytes()
            with LOCK:
                LOG.append({"method": "GET", "path": self.path, "has_auth": "Authorization" in self.headers})
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/__log":
            return self.reply(200, LOG)
        if self.path == "/__state":
            return self.reply(200, {"admitted_jobs": len(JOBS)})
        if self.path == "/__voices":
            with LOCK:
                return self.reply(200, {**library.snapshot(), "grant": GRANTS.get("local-smoke")})
        if self.path == "/__jobs":
            with LOCK:
                return self.reply(200, [{k: v for k, v in job.items() if k not in ("prompt", "account")} for job in JOBS.values()])
        if self.path in {"/purchase-fixture", "/machines-fixture"}:
            with LOCK:
                LOG.append({"method": "GET", "path": self.path, "has_auth": "Authorization" in self.headers})
            return self.reply(200, {"fixture": self.path + " opened locally; no payment"})
        if not self.authorized():
            return
        if self.path.endswith("/me"):
            with LOCK:
                LOG.append({"method": "GET", "path": self.path, "account": self.account(), "has_auth": True})
                fixture = CONTROL.get("me_fixture")
            if fixture:
                allowed = {"me-pro-v1", "me-free-purchase-v1", "me-machine-limit-v1", "me-machine-limit-purchase-v1",
                           "me-grace-v1", "me-purchase-unavailable-v1", "me-pro-expiring-v1", "me-pro-manual-expiring-v1"}
                if fixture not in allowed:
                    return self.error(400, "unknown_me_fixture")
                path = Path(__file__).resolve().parents[3] / "checks/SkyStudio/Fixtures" / (fixture + ".json")
                answer = json.loads(path.read_text())
                # 实点购买链接只打开本机页面，不连尚未上线的真实购买页。
                if CONTROL.get("local_purchase_page") and answer["skycut"].get("upgrade_url"):
                    answer["skycut"]["upgrade_url"] = BASE + "/purchase-fixture"
                if CONTROL.get("no_purchase_page"):
                    answer["skycut"]["upgrade_url"] = None
                if CONTROL.get("local_machine_page") and answer["skycut"].get("manage_machines_url"):
                    answer["skycut"]["manage_machines_url"] = BASE + "/machines-fixture"
                if CONTROL.get("no_machine_management"):
                    answer["skycut"]["manage_machines_url"] = None
                return self.reply(200, answer)
            # 两个池照线上（共用 3、声音 8）；me_audio_jobs 给 null 就是还没上声音池的服务器（声音任务进共用池）。
            pools = {"max_running_jobs": CONTROL.get("me_running_jobs", 3)}
            if CONTROL.get("me_audio_jobs", 8) is not None:
                pools["max_running_audio_jobs"] = CONTROL.get("me_audio_jobs", 8)
            return self.reply(200, {"account": {"id": self.account()}, "credits": {"balance": 1000},
                "skycut": {"plan": "pro", "features": {"mcp": True, "watermark": False},
                           "valid_until": stamp(86400), **pools}, "server_time": stamp()})
        if self.path.endswith("/voices/consent-grant"):
            with LOCK:
                LOG.append({"method": "GET", "path": self.path, "has_auth": True})
                return self.reply(200, {"grant": GRANTS.get(self.account()), "current_statement_version": STANDING_VERSION})
        if self.path.endswith("/models"):
            # 快照里全部声音模型（读稿、设计、建 MiniMax 版、变声）：打开全部权限时那段说明的价目也从这里读（声音 PR 7）。
            voices = voice_fixtures.models(CONTROL.get("voice_max_characters"))
            return self.reply(200, {"models": voices + media_fixtures.models() + expansion.CATALOG["models"],
                                    "billing_policy": expansion.CATALOG["billing_policy"], **voice_fixtures.top_level()})
        if "/voices" in self.path:
            return self.voices("GET", {})
        with LOCK:
            job = JOBS.get(self.path.split("/")[-1])
            if job and job.get("account") == self.account():
                if CONTROL.get("settle_refund"):
                    job["billing"] = expansion.billing("refunded", 0)
                LOG.append({"method": "GET", "path": self.path, "has_auth": True})
                if job.get("refuse"):
                    job["polls"] = job.get("polls", 0) + 1
                    media_fixtures.refuse(job, job["polls"] >= CONTROL.get("refund_after_polls", 1))
                public = {k: v for k, v in job.items() if k not in HIDDEN}
                return self.reply(200, public)
        self.error(404, "unknown_job")

    def voices(self, method, data):
        """`/voices…`（声音库，voice_library_fixtures）。列表带 `?limit=50`，路由只看路径。"""
        rest = self.path.split("?", 1)[0].split("/voices", 1)[1]
        with LOCK:
            status, value = library.handle(method, rest, data, CONTROL, ROOT, BASE, GRANTS.get(self.account()))
            LOG.append({"method": method, "path": self.path, "body": data, "status": status, "has_auth": True})
        return self.reply(status, value)

    def do_PATCH(self):
        data = json.loads(self.body() or b"{}")
        if not self.authorized():
            return
        if "/voices" in self.path:
            return self.voices("PATCH", data)
        self.error(404, "unknown_route")

    def do_DELETE(self):
        self.body()
        if not self.authorized():
            return
        if self.path.endswith("/voices/consent-grant"):
            with LOCK:
                LOG.append({"method": "DELETE", "path": self.path, "has_auth": True})
                GRANTS.pop(self.account(), None)
                return self.reply(200, {"revoked": True, "grant": None, "current_statement_version": STANDING_VERSION})
        if "/voices" in self.path:
            return self.voices("DELETE", {})
        self.error(404, "unknown_route")

    def release(self, data):
        """`POST /__release {"count": n, "kind": k}`：放行 hold 着的任务（最早的先；给了 kind 只放这一种），不给 count 全放。"""
        with LOCK:
            held = [job for job in JOBS.values() if job.get("held") and job["status"] == "queued"
                    and data.get("kind") in (None, job["kind"])]
            chosen = held[:data["count"]] if "count" in data else held
            for job in chosen:
                job.update(status="running", held=False)
                threading.Thread(target=synthesize, args=(job,), daemon=True).start()
            return self.reply(200, {"released": [job["job_id"] for job in chosen], "still_held": len(held) - len(chosen)})

    def authorized(self):
        if self.account():
            return True
        self.error(401, "invalid_key")
        return False

    def account(self):
        return {"Bearer " + KEY: "local-smoke", "Bearer sk-" + "T" * 43: "local-smoke-other"}.get(self.headers.get("Authorization"))

    def do_POST(self):
        data = json.loads(self.body() or b"{}")
        if self.path == "/__control":
            with LOCK:
                CONTROL.update(data)
            return self.reply(200, CONTROL)
        if self.path == "/__release":
            return self.release(data)
        if not self.authorized():
            return
        if "/voices" in self.path and not self.path.endswith("/voices/consent-grant"):
            return self.voices("POST", data)
        with LOCK:
            LOG.append({"method": "POST", "path": self.path, "body": data, "has_auth": True})
            if self.path.endswith("/quote"):
                if CONTROL.get("quote_error"):
                    return self.error(503, "unavailable")
                if data["kind"] == "voice_clone" and "batches" in (data.get("params") or {}):
                    status, value = library.clone_quote(data, CONTROL)
                    return self.reply(status, value)
                if data["kind"] in ("voice_design", "voice_enroll"):
                    status, value = library.library_quote(data, CONTROL)
                    return self.reply(status, value)
                credits = 2.5 if data["kind"] == "voice_clone" else 1
                if data["kind"] in voice_fixtures.READING and "batches" in (data.get("params") or {}):
                    return self.reply(200, voice_fixtures.quote(data, credits))
                credits = CONTROL.get("quotes_by_prompt", {}).get(data.get("prompt"), credits)
                if CONTROL.get("replacement_expensive") and data["model"] == "minimax-h3":
                    credits = 2
                if "film" in data:
                    code, result = OFFICIAL.quote(data, self.account(), credits, CONTROL)
                    return self.error(code, result) if isinstance(result, str) else self.reply(code, result)
                return self.reply(200, {"credits": credits, "typical_seconds": 5})
            if self.path.endswith("/voices/consent-grant"):
                version = data.get("statement_version") or ""
                if not version:
                    return self.reply(400, {"error": {"code": "invalid_request", "message": "statement_version", "field": "statement_version"}})
                GRANTS[self.account()] = {"statement_version": version, "granted_at": stamp(), "active": version == STANDING_VERSION,
                                          "inactive_reason": None if version == STANDING_VERSION else "outdated"}
                return self.reply(200, {"grant": GRANTS[self.account()], "current_statement_version": STANDING_VERSION})
            if self.path.endswith("/uploads"):
                suffix = Path(data["filename"]).suffix.lstrip(".")
                name = f"upload-{len(LOG)}.{suffix}"
                url = OFFICIAL.original(self.account(), name) if CONTROL.get("official") else BASE + "/files/" + name
                return self.reply(200, {"upload_url": BASE + "/put/" + name, "file_url": url, "headers": {}})
            if self.path.endswith("/cancel"):
                job = JOBS.get(self.path.split("/")[-2])
                if job and job.get("account") != self.account():
                    return self.error(404, "unknown_job")
                if job and CONTROL.get("cancel_already_started"):
                    job["status"] = "running"
                    threading.Thread(target=synthesize, args=(job,), daemon=True).start()
                    return self.error(409, "not_cancellable")
                if job and job["status"] == "queued":
                    job["status"] = "cancelled"
                    job["billing"] = expansion.billing("refunded", 0, job["credits"])
                    return self.reply(200, {"status": "cancelled", "credits_refunded": job["credits"]})
                return self.error(409, "not_cancellable")
            if self.path.endswith("/jobs"):
                if "film" in data and CONTROL.get("official_slot_full"):
                    return self.reply(429, {"error": {"code": "too_many_jobs", "message": "Test account slots are full.", "limit": 3, "running": 3}})
                if "film" in data:
                    error = OFFICIAL.submit(data, self.account(), CONTROL)
                    if error:
                        return self.error(503 if error == "recipe_unavailable" else 400, error)
                key = (self.account(), data["idempotency_key"])
                pool = "audio" if data["kind"] in AUDIO_KINDS and CONTROL.get("me_audio_jobs", 8) is not None else "default"
                if key not in KEYS and CONTROL.get("pool_full", {}).get(pool, 0) > 0:
                    # 别处（网页、别的电脑）占满了这个池：回一次 429，App 拿着槽等 15 秒、用同一个 key 再交。
                    CONTROL["pool_full"][pool] -= 1
                    return self.reply(429, {"error": {"code": "too_many_jobs", "message": "Test account slots are full.",
                                                      "pool": pool, "limit": 1, "running": 1}})
                if key in KEYS:
                    job = JOBS[KEYS[key]]
                else:
                    identity = "local-" + str(len(JOBS) + 1)
                    held = bool(CONTROL.get("hold")) or data["kind"] in CONTROL.get("hold_kinds", [])
                    job = dict(job_id=identity, status="queued" if held else "running",
                               account=self.account(), held=held, params=data.get("params") or {},
                               kind=data["kind"], model=data["model"], prompt=data.get("prompt", ""), poll_after_seconds=2,
                               plan=(data.get("params") or {}).get("plan"),
                               credits=data.get("max_credits", 2.5 if data["kind"] == "voice_clone" else 1))
                    JOBS[identity], KEYS[key] = job, identity
                    # 冒烟让第几批「中途换了备用」/「备用要先建 MiniMax 版」：按交上来的先后从 voice_job_outcomes 里取。
                    if data["kind"] in voice_fixtures.READING and CONTROL.get("voice_job_outcomes"):
                        job["outcome"] = CONTROL["voice_job_outcomes"].pop(0)
                    if data["model"].startswith("seedance") and CONTROL.get("refuse_seedance"):
                        job["refuse"] = True
                        if CONTROL.get("submit_refusal"):
                            media_fixtures.refuse(job, True)
                            return self.reply(502, {"error": {**job["error"], "job_id": identity}, "billing": job["billing"]})
                    elif not held:
                        threading.Thread(target=synthesize, args=(job,), daemon=True).start()
                    if CONTROL.get("unknown_submission"):
                        return self.reply(502, {"unexpected": "submission outcome unknown"})
                return self.reply(202, {"job_id": job["job_id"], "status": job["status"], "poll_after_seconds": 2})
        self.error(404, "unknown_route")


expansion.prepare(ROOT, ROOT.parent / "work", FFMPEG)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
