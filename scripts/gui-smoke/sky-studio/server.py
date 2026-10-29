"""本机 Sky Studio 合同夹具：假 Key、原生 say 写文件、无外网、无积分。"""
import datetime
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, ROOT, FFMPEG = int(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
ROOT.mkdir(parents=True, exist_ok=True)
BASE = f"http://127.0.0.1:{PORT}"
KEY = "sk-" + "S" * 43
LOCK = threading.RLock()
JOBS, KEYS, LOG, CONTROL = {}, {}, [], {}


def stamp(seconds=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).isoformat()


def synthesize(job):
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
    with LOCK:
        job.update(status="done", result={"url": BASE + "/files/" + target.name,
                   "content_type": "audio/wav", "duration": duration,
                   "words": chunks if job["kind"] == "voice" else None}, credits_charged=job["credits"])


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
        (ROOT / "upload.wav").write_bytes(data)
        with LOCK:
            LOG.append({"method": "PUT", "path": self.path, "bytes": len(data), "has_auth": "Authorization" in self.headers})
        self.reply(200, {})

    def do_GET(self):
        if self.path.startswith("/files/"):
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
        if not self.authorized():
            return
        if self.path.endswith("/me"):
            return self.reply(200, {"account": {"id": "local-smoke"}, "credits": {"balance": 1000},
                "skycut": {"plan": "pro", "features": {"mcp": True, "watermark": False},
                           "valid_until": stamp(86400), "max_running_jobs": 3}, "server_time": stamp()})
        if self.path.endswith("/models"):
            return self.reply(200, {"models": [
                {"id": "local-narrator", "kind": "voice", "title": "Local narrator fixture", "limits": {"max_characters": 100}},
                {"id": "local-clone", "kind": "voice_clone", "title": "Local clone fixture",
                 "params": {"language": ["en_us", "cmn"]}, "limits": {"max_characters_by_language": {"en_us": 80, "cmn": 20}}}]})
        with LOCK:
            job = JOBS.get(self.path.split("/")[-1])
            if job:
                public = {k: v for k, v in job.items() if k not in ("prompt", "credits")}
                return self.reply(200, public)
        self.error(404, "unknown_job")

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer " + KEY:
            return True
        self.error(401, "invalid_key")
        return False

    def do_POST(self):
        data = json.loads(self.body() or b"{}")
        if self.path == "/__control":
            with LOCK:
                CONTROL.update(data)
            return self.reply(200, CONTROL)
        if not self.authorized():
            return
        with LOCK:
            LOG.append({"method": "POST", "path": self.path, "body": data, "has_auth": True})
            if self.path.endswith("/quote"):
                if CONTROL.get("quote_error"):
                    return self.error(503, "unavailable")
                return self.reply(200, {"credits": 2.5 if data["kind"] == "voice_clone" else 1, "typical_seconds": 5})
            if self.path.endswith("/uploads"):
                return self.reply(200, {"upload_url": BASE + "/put", "file_url": BASE + "/files/upload.wav", "headers": {}})
            if self.path.endswith("/cancel"):
                job = JOBS.get(self.path.split("/")[-2])
                if job and job["status"] == "queued":
                    job["status"] = "cancelled"
                    return self.reply(200, {"status": "cancelled", "credits_refunded": job["credits"]})
                return self.error(409, "not_cancellable")
            if self.path.endswith("/jobs"):
                key = data["idempotency_key"]
                if key in KEYS:
                    job = JOBS[KEYS[key]]
                else:
                    identity = "local-" + str(len(JOBS) + 1)
                    job = dict(job_id=identity, status="queued" if CONTROL.get("hold") else "running",
                               kind=data["kind"], prompt=data["prompt"], poll_after_seconds=2,
                               credits=2.5 if data["kind"] == "voice_clone" else 1)
                    JOBS[identity], KEYS[key] = job, identity
                    if not CONTROL.get("hold"):
                        threading.Thread(target=synthesize, args=(job,), daemon=True).start()
                return self.reply(202, {"job_id": job["job_id"], "status": job["status"], "poll_after_seconds": 2})
        self.error(404, "unknown_route")


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
