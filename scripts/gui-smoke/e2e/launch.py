"""Supervise one staged E2E suite with a clean environment and a read-only real home."""

import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import time


# Multiple healthy fixture jobs can take more than three minutes on a shared Mac.
SUITE_TIMEOUT = 300
HOME_PROFILE = '(version 1) (allow default) (deny file-write* (subpath (param "REAL_HOME")))'


def isolated_environment(root, ffmpeg):
    for name in ("home", "tmp"):
        (root / name).mkdir(mode=0o700)
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "HOME": str(root / "home"),
        "CFFIXED_USER_HOME": str(root / "home"),
        # cfprefsd lives outside this sandbox and writes to the login home. Use the fixture home in-process.
        "__CFPREFERENCES_AVOID_DAEMON": "1",
        "TMPDIR": str(root / "tmp"),
        "SRTFLOW_FFMPEG": str(ffmpeg),
        "SRTFLOW_SMOKE_MUTE": "1",
        "SRTFLOW_VERSIONS_ROOT": str(root / "versions"),
    }


def sandbox_command(real_home, command):
    return ["/usr/bin/sandbox-exec", "-p", HOME_PROFILE, "-D", f"REAL_HOME={real_home}", *command]


def assert_no_home_artifacts(real_home, bundle_id):
    # The sandbox covers this process tree. Check the per-bundle paths that macOS services can write on its behalf.
    library = real_home / "Library"
    paths = [library / name / bundle_id for name in ("Application Support", "Caches", "Containers", "WebKit", "HTTPStorages")]
    paths += [library / "Preferences" / f"{bundle_id}.plist",
              library / "Saved Application State" / f"{bundle_id}.savedState"]
    escaped = [str(path) for path in paths if os.path.lexists(path)]
    if escaped:
        raise RuntimeError(f"E2E state escaped to the real home: {escaped}")


def output_tail(path, maximum=60):
    if path.is_file():
        lines = path.read_text(errors="replace").splitlines()
        print(f"{path.name} ({len(lines)} lines, last {maximum} below)\n" + "\n".join(lines[-maximum:]), flush=True)


def stop_group(check):
    # Give the MCP driver a chance to print the last job phase and stop its App.
    check.send_signal(signal.SIGINT)
    try:
        check.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(check.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    check.wait()


def supervise(command, env, root):
    log = root / "suite.log"
    started = time.monotonic()
    with log.open("w") as output:
        check = subprocess.Popen(command, env=env, cwd=root, stdin=subprocess.DEVNULL, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = check.wait(timeout=SUITE_TIMEOUT)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            stop_group(check)
            output_tail(log)
            output_tail(root / "app.log")
            raise
    print(log.read_text(errors="replace"), end="", flush=True)
    if code:
        output_tail(root / "app.log")
        raise SystemExit(f"E2E check exited with status {code}")
    return time.monotonic() - started


def main(suite, bundle, ffmpeg, extra):
    root = bundle.parent
    own_files = Path(__file__).resolve().parent
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)
    identities = {"gui": r"com\.srtflow\.e2egui[0-9]+", "mcp": r"com\.srtflow\.e2e[0-9]+\.skystudiosmoke"}
    bundle_id = info["CFBundleIdentifier"]
    if (suite not in identities or not re.fullmatch(identities[suite], bundle_id)
            or not root.is_relative_to(Path("/tmp").resolve()) or root.is_relative_to(real_home)):
        raise RuntimeError("E2E suite needs its own staged bundle in the temporary directory")
    system_tmp = Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
    staged_ffmpeg = root / "ffmpeg"
    shutil.copy2(ffmpeg, staged_ffmpeg)
    env = isolated_environment(root, staged_ffmpeg)
    if suite == "mcp":
        if "--update-goldens" in extra and os.environ.get("CI"):
            raise SystemExit("Golden candidates may only be generated on a developer Mac")
        command = [sys.executable, "-B", "-u", str(own_files / "run.py"), str(bundle), str(staged_ffmpeg), *extra]
    elif suite == "gui" and not extra:
        (root / "work").mkdir()
        env["SRTFLOW_WEB_MOTION_HELPER"] = str(bundle / "Contents/Helpers/skycut-web-motion")
        command = [str(bundle / "Contents/MacOS" / info["CFBundleExecutable"]), str(root / "work"),
                   str(own_files / "ink-plate.html")]
    else:
        raise SystemExit(f"Unknown E2E invocation: {suite} {extra}")
    try:
        elapsed = supervise(sandbox_command(real_home, command), env, root)
    finally:
        assert_no_home_artifacts(real_home, bundle_id)
        saved_state = system_tmp / f"{bundle_id}.savedState"
        if os.path.lexists(saved_state):
            raise RuntimeError(f"E2E window restoration escaped to the login session temp directory: {saved_state}")
    print(f"E2E check completed in {elapsed:.1f}s", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal.getsignal(signal.SIGINT))
    suite, bundle, ffmpeg, *extra = sys.argv[1:]
    main(suite, Path(bundle).resolve(strict=True), Path(ffmpeg).resolve(strict=True), extra)
