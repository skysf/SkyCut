"""真起假的 MCP 小程序，验证冒烟客户端不会把断线 / 协议错误当成功；不连 App、不碰网络。"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/gui-smoke/fal"))
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


if __name__ == "__main__":
    unittest.main()
