"""Launch and clean up an isolated SkyCut, then run production MCP workflows."""

from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

from fixture_license import KEY, license_server
from mix_export import make_media, verify_mix_export

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP


def bridge_paths(bundle_id):
    # Match MCPBridge.swift, which deliberately ignores HOME for the interprocess bridge.
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    support = home / "Library/Application Support" / bundle_id
    socket = support / "mcp.sock"
    if len(os.fsencode(socket)) >= 104:
        stable = 0xCBF29CE484222325
        for byte in bundle_id.encode():
            stable = ((stable ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        socket = Path(f"/tmp/srtflow-mcp-{os.getuid()}-{stable % 100000}.sock")
    return support, socket


@contextmanager
def app_process(bundle, ffmpeg, base):
    root = bundle.parent
    bundle_id = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    assert bundle_id.startswith("com.srtflow.e2e") and bundle_id.endswith(".skystudiosmoke"), bundle_id
    support, socket = bridge_paths(bundle_id)
    assert not socket.exists() and not socket.is_symlink(), f"Fixture socket already exists: {socket}"
    support.parent.mkdir(parents=True, exist_ok=True)
    support.mkdir(mode=0o700)
    try:
        for folder in ("home", "tmp"):
            (root / folder).mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SRTFLOW_")}
        environment.update(
            HOME=str(root / "home"),
            CFFIXED_USER_HOME=str(root / "home"),
            TMPDIR=str(root / "tmp"),
            SRTFLOW_FFMPEG=str(ffmpeg),
            SRTFLOW_SMOKE_MUTE="1",
            SRTFLOW_SMOKE_CACHE_DIR=str(root / "optimized"),
            SRTFLOW_VERSIONS_ROOT=str(root / "versions"),
            SRTFLOW_SKYSTUDIO_API_BASE=base,
            SRTFLOW_SMOKE_SKYSTUDIO_KEY=KEY,
        )
        executable = bundle / "Contents/MacOS/SrtFlow"
        log = root / "app.log"
        with log.open("w") as output:
            app = subprocess.Popen([str(executable), "-ApplePersistenceIgnoreState", "YES",
                                    "-optimizedMedia.previewMode", "original", "-appLanguage", "en"],
                                   cwd=root, env=environment, stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
            try:
                wait_for_bridge(app, socket)
                yield socket
            except BaseException:
                print(f"SkyCut E2E app log (exit {app.poll()})\n" + "\n".join(log.read_text(
                    errors="replace").splitlines()[-60:]), file=sys.stderr)
                raise
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait(timeout=5)
    finally:
        socket.unlink(missing_ok=True)
        shutil.rmtree(support)
        # AppKit's ignored restoration state uses the system's real per-user temp directory.
        saved_state = Path(tempfile.gettempdir()) / f"{bundle_id}.savedState"
        if saved_state.exists():
            shutil.rmtree(saved_state)


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

    def call(self, tool, **arguments):
        data, error = self.client.call(tool, arguments, timeout=40)
        assert not error and isinstance(data, dict), f"{tool} {arguments} failed: {data}"
        assert not data.get("needs_confirmation"), f"{tool} unexpectedly asked for confirmation: {data}"
        return data

    def edit(self, tool, **arguments):
        assert self.project is not None
        return self.call(tool, project=self.project, **arguments)

    def job(self, started):
        deadline = time.monotonic() + 60
        job_id = started["job_id"]
        while True:
            job = self.call("get_job", job_id=job_id, wait_seconds=5)
            if job["status"] == "done":
                return job
            assert job["status"] in {"queued", "running"} and not job.get("waiting_for_user"), job
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Job {job_id} still {job['status']} after 60 seconds")

    def new_project(self, work, name):
        self.call("open_folder", path=str(work))
        self.call("set_view", mode="background")
        created = self.call("new_project", name=name, version="E2E")
        self.project = created["project"]
        path = Path(created["created"]).resolve()
        assert path.is_relative_to(work) and path.is_file(), created
        return path

    def authorized(self):
        deadline = time.monotonic() + 20
        while True:
            plan = self.call("get_status")["skycut_plan"]
            if plan["source"] == "sky_studio" and plan["ai_tools"] and not plan["export_watermark"]:
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Isolated SkyCut did not read the fixture license: {plan}")
            time.sleep(0.1)


def main(bundle, ffmpeg):
    work = bundle.parent / "work"
    work.mkdir()
    make_media(work, ffmpeg)
    with license_server() as base, app_process(bundle, ffmpeg, base) as socket:
        environment = dict(os.environ, SRTFLOW_MCP_SOCKET=str(socket), SRTFLOW_MCP_NO_LAUNCH="1",
                           SRTFLOW_MCP_APP=str(bundle))
        environment.pop("SRTFLOW_MCP_PROVIDERS", None)
        client = MCP(str(bundle / "Contents/Helpers/skycut-mcp"), environment)
        try:
            session = Session(client)
            session.authorized()
            verify_mix_export(session, work, ffmpeg)
        finally:
            client.close()


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("E2E assertions require Python without optimization")
    started = time.monotonic()
    main(*(Path(value).resolve(strict=True) for value in sys.argv[1:]))
    print(f"E2E fixture and workflows completed in {time.monotonic() - started:.1f}s")
