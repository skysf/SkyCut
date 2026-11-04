"""真起假的 MCP 小程序，验证冒烟客户端不会把断线 / 协议错误当成功；不连 App、不碰网络。"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/gui-smoke"))
from mcpclient import MCP


class SmokeClientChecks(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
            client.p.wait(timeout=3)
        self.scratch.cleanup()

    def client(self, mode):
        helper = Path(self.scratch.name) / mode
        helper.write_text(f"#!{sys.executable}\n" + """
import json, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    rid = request['id']
    if request['method'] == 'initialize':
        answer = {'result': {}}
    elif MODE == 'exit':
        sys.exit(7)
    elif MODE == 'malformed':
        print('not JSON', flush=True)
        continue
    elif MODE == 'silent':
        time.sleep(5)
        continue
    elif MODE in ['id_list', 'id_object', 'id_boolean']:
        rid = {'id_list': [], 'id_object': {}, 'id_boolean': True}[MODE]
        answer = {'result': {}}
    elif MODE == 'rpc_error':
        answer = {'error': {'code': -32603, 'message': 'fixture failure'}}
    else:
        answer = {'result': {'content': [{'type': 'text', 'text': '{"status":"ok"}'}]}}
    print(json.dumps({'jsonrpc': '2.0', 'id': rid, **answer}), flush=True)
""".replace("MODE", repr(mode)))
        helper.chmod(0o700)
        client = MCP(str(helper))
        self.clients.append(client)
        return client

    def test_success(self):
        self.assertEqual(self.client("success").call("get_status", timeout=1), ({"status": "ok"}, False))

    def test_json_rpc_error_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, "fixture failure"):
            self.client("rpc_error").call("generate_media", timeout=0.5)

    def test_eof_wakes_waiter(self):
        with self.assertRaisesRegex(RuntimeError, "closed|exited"):
            self.client("exit").call("generate_media", timeout=0.5)

    def test_malformed_response_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, "JSON|protocol"):
            self.client("malformed").call("get_status", timeout=0.5)

    def test_invalid_response_id_wakes_waiter(self):
        for mode in ['id_list', 'id_object', 'id_boolean']:
            with self.subTest(mode=mode):
                client = self.client(mode)
                with self.assertRaisesRegex(RuntimeError, "JSON|protocol"):
                    client.call("get_status", timeout=0.2)
                self.assertEqual(client.waiting, {})

    def test_timeout_names_call_and_removes_waiter(self):
        client = self.client("silent")
        with self.assertRaisesRegex(TimeoutError, "generate_media"):
            client.call("generate_media", timeout=0.1)
        self.assertEqual(client.waiting, {})

    def test_logged_runner_preserves_failure(self):
        log = Path(self.scratch.name) / "run.log"
        runner = ROOT / "scripts/gui-smoke/run-logged.sh"
        result = subprocess.run(["/bin/bash", str(runner), str(log), sys.executable, "-c",
                                 "print('fixture failed'); raise SystemExit(7)"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn("fixture failed", log.read_text())

    def test_cleanup_preserves_unrelated_process(self):
        # 真起无关子进程；所有机器级清理都隔离，不能删掉正在验收的同 bundle MCP socket。
        folder = Path(self.scratch.name)
        cleanup = folder / "cleanup"
        cleanup.mkdir()
        fakebin = folder / "bin"
        fakebin.mkdir()
        for name in ["security", "defaults", "pkill"]:
            command = fakebin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o700)
        removed = folder / "remove.jsonl"
        remover = fakebin / "rm"
        remover.write_text(f"#!{sys.executable}\n" + f"""
import json, sys
from pathlib import Path
root, owned, log = Path({str(folder)!r}), Path({str(cleanup)!r}), Path({str(removed)!r})
for argument in sys.argv[1:]:
    if argument.startswith('-'): continue
    path = Path(argument).resolve()
    action = 'blocked'
    # 外层测试沙箱即使在反向验证时也保留，绝不触碰真实 Application Support。
    if path.is_relative_to(root.resolve()):
        if path.parent == owned.resolve() and path.name in ('app.pid', 'server.pid'):
            path.unlink(missing_ok=True)
            action = 'removed'
    with log.open('a') as output:
        output.write(json.dumps({{'path': str(path), 'action': action}}) + '\\n')
""")
        remover.chmod(0o700)
        protected = folder / "mcp.sock"
        sentinel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(sentinel.close)
        sentinel.bind(str(protected))
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            for name in ["app.pid", "server.pid"]:
                (cleanup / name).write_text(str(child.pid))
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/gui-smoke/sky-studio/run.sh"), "stop"],
                                    env={**os.environ, "SKYSTUDIO_SMOKE_DIR": str(cleanup),
                                         "PATH": str(fakebin) + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIsNone(child.poll(), "stale test PID must not terminate another command")
            for name in ["app.pid", "server.pid"]:
                self.assertFalse((cleanup / name).exists(), "the fixture must still exercise owned PID cleanup")
            rows = [json.loads(line) for line in removed.read_text().splitlines()]
            support = Path(os.environ["HOME"]) / "Library/Application Support/com.srtflow.SrtFlow.skystudiosmoke"
            for name in ["mcp-providers.json", "mcp.sock"]:
                self.assertIn({"path": str((support / name).resolve()), "action": "blocked"}, rows,
                              "shared smoke support cleanup must be intercepted")
            subprocess.run([str(remover), "-f", str(protected)], check=True, timeout=5)
            self.assertTrue(protected.is_socket(), "cleanup must preserve another live socket outside its owned directory")
        finally:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
