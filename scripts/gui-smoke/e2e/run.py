"""Launch and clean up an isolated SkyCut, then run production MCP workflows."""

import argparse
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

from fixture_license import KEY, license_server
from mix_export import make_media, verify_mix_export
from reference_edits import add_picture, add_titles, check_delivery_marks, check_freeze_and_ripple, check_save_and_versions, edit_sound
from reference_media import make_reference_media
from reference_output import check_reference_output

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP


# The bridge itself gives a healthy call up to 120 s. The fixture jobs have a separate deadline: the
# 18-frame reference motion can take 96 s in the helper, plus the 10 s App backstop and 3 s teardown.
CALL_TIMEOUT = 125
JOB_TIMEOUT = 120


@contextmanager
def app_process(bundle, base, socket):
    root = bundle.parent
    bundle_id = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    assert bundle_id.startswith("com.srtflow.e2e") and bundle_id.endswith(".skystudiosmoke"), bundle_id
    assert Path(os.environ["CFFIXED_USER_HOME"]) == root / "home", "Use the isolated E2E launcher"
    environment = dict(os.environ, SRTFLOW_SMOKE_CACHE_DIR=str(root / "optimized"),
                       SRTFLOW_SKYSTUDIO_API_BASE=base, SRTFLOW_SMOKE_SKYSTUDIO_KEY=KEY)
    executable = bundle / "Contents/MacOS/SrtFlow"
    with (root / "app.log").open("w") as output:
        app = subprocess.Popen([str(executable), "-ApplePersistence", "NO",
                                "-optimizedMedia.previewMode", "original", "-appLanguage", "en"],
                               cwd=root, env=environment, stdin=subprocess.DEVNULL, stdout=output,
                               stderr=subprocess.STDOUT)
        try:
            print("Waiting for the isolated SkyCut app and its MCP bridge", flush=True)
            wait_for_bridge(app, socket)
            yield
        finally:
            app.terminate()
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=3)


def wait_for_bridge(app, socket):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError(f"Isolated SkyCut exited before starting its bridge ({app.returncode})")
        if socket.is_socket():
            return
        time.sleep(0.1)
    raise TimeoutError("Isolated SkyCut did not start its MCP socket within 30 seconds")


class Session:
    """Assert application responses and keep every edit on the returned project id."""

    def __init__(self, client):
        self.client = client
        self.project = None
        self.last_call = "initialize"
        self.last_job = None
        self.view = "startup"

    def call(self, tool, **arguments):
        data, _ = self.response(tool, arguments)
        return data

    def response(self, tool, arguments, timeout=CALL_TIMEOUT):
        self.last_call = tool
        data, error, content = self.client.call_with_content(tool, arguments, timeout=timeout)
        assert not error and isinstance(data, dict), f"{tool} {arguments} failed: {data}"
        assert data.get("status") != "needs_confirmation", f"{tool} unexpectedly asked for confirmation: {data}"
        return data, content

    def edit(self, tool, **arguments):
        assert self.project is not None
        return self.call(tool, project=self.project, **arguments)

    def job(self, started):
        result, _ = self.wait_job(started)
        return result

    def wait_job(self, started):
        begin = time.monotonic()
        deadline = begin + JOB_TIMEOUT
        job_id = started["job_id"]
        self.last_job = started
        print(f"Waiting for MCP job {job_id}", flush=True)
        while (remaining := deadline - time.monotonic()) > 0:
            job, content = self.response("get_job", {"job_id": job_id, "wait_seconds": min(5, remaining)},
                                         timeout=remaining)
            self.last_job = job
            if job["status"] == "done":
                print(f"MCP job {job_id} finished in {time.monotonic() - begin:.1f}s after submission", flush=True)
                return job, content
            assert job["status"] in {"queued", "running"} and not job.get("waiting_for_user"), job
        raise TimeoutError(f"MCP job {job_id} exceeded {JOB_TIMEOUT}s")

    def diagnose(self):
        job = self.last_job or {}
        fields = ("job_id", "kind", "status", "phase", "phase_seconds", "queue_position", "progress", "message")
        last = {key: job[key] for key in fields if key in job}
        print(f"Last MCP call: {self.last_call}. Last job phase: {last}. Editor view: {self.view}.",
              file=sys.stderr, flush=True)
        try:
            status, error = self.client.call("get_status", timeout=2)
            if not error:
                windows = [(row["id"], row["shown_in"], row["view"]) for row in status["projects"]]
                print(f"SkyCut project window state: {windows}", file=sys.stderr, flush=True)
        except (OSError, RuntimeError):
            print("SkyCut did not return its project window state", file=sys.stderr, flush=True)

    def look(self, **arguments):
        result, content = self.response("look", {"project": self.project, **arguments})
        if "job_id" in result:
            finished, content = self.wait_job(result)
            result = finished["result"]
        image, = [item for item in content if item["type"] == "image"]
        return result, base64.b64decode(image["data"], validate=True)

    def new_project(self, work, name):
        self.call("open_folder", path=str(work))
        self.call("set_view", mode="background")
        self.view = "background"
        created = self.call("new_project", name=name, version="E2E")
        self.project = created["project"]
        path = Path(created["created"]).resolve()
        assert path.is_relative_to(work) and path.is_file(), created
        return path

    def authorized(self):
        # Sky Studio's loopback request gets 20 s in the App. Leave room for launch and the last reply.
        deadline = time.monotonic() + 30
        plan = None
        while (remaining := deadline - time.monotonic()) > 0:
            data, _ = self.response("get_status", {}, timeout=remaining)
            plan = data["skycut_plan"]
            if plan["source"] == "sky_studio" and plan["ai_tools"] and not plan["export_watermark"]:
                return
            time.sleep(0.1)
        raise TimeoutError(f"Isolated SkyCut did not read the fixture license: {plan}")


def main(bundle, ffmpeg, update_goldens):
    work = bundle.parent / "work"
    work.mkdir()
    make_media(work, ffmpeg)
    reference = work / "reference"
    reference.mkdir()
    make_reference_media(reference, ffmpeg)
    socket = bundle.parent / "bridge/mcp.sock"
    marker = socket.with_name("mcp-providers.json")
    with license_server() as base, app_process(bundle, base, socket):
        environment = dict(os.environ, SRTFLOW_MCP_SOCKET=str(socket), SRTFLOW_MCP_NO_LAUNCH="1",
                           SRTFLOW_MCP_PROVIDERS=str(marker), SRTFLOW_MCP_APP=str(bundle))
        client = MCP(str(bundle / "Contents/Helpers/skycut-mcp"), environment)
        session = Session(client)
        try:
            session.authorized()
            assert json.loads(marker.read_text())["providers"] == ["skystudio"], "Expected the isolated provider marker"
            verify_mix_export(session, work, ffmpeg)
            session.edit("close_project")
            run_reference(session, reference, ffmpeg, update_goldens)
        except BaseException:
            session.diagnose()
            raise
        finally:
            client.close()


def run_reference(session, work, ffmpeg, update_goldens):
    document = session.new_project(work, "Reference")
    picture = add_picture(session)
    check_delivery_marks(session)
    check_freeze_and_ripple(session, picture)
    print("MCP reference cut: source reminders, intentional findings and ripple passed", flush=True)
    edit_sound(session, picture)
    add_titles(session)
    check_save_and_versions(session, document)
    print("MCP reference cut: sound edits, motion and saved versions passed", flush=True)
    check_reference_output(session, work, ffmpeg, update_goldens)


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("E2E assertions require Python without optimization")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("ffmpeg", type=Path)
    parser.add_argument("--update-goldens", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    main(args.bundle.resolve(strict=True), args.ffmpeg.resolve(strict=True), args.update_goldens)
    print(f"E2E fixture and workflows completed in {time.monotonic() - started:.1f}s")
