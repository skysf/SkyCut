from pathlib import Path
import os
import json
import signal
import subprocess
import sys
import time

# 合成命令可能派生后代；只逐 PID 清理本次 CLI 的暂停子树，不按名称或进程组杀。
def stop_owned_tree(process):
    try:
        os.kill(process.pid, signal.SIGSTOP)
    except ProcessLookupError:
        return []
    owned = {process.pid}
    try:
        while True:
            lines = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True, timeout=2)
            rows = [tuple(map(int, line.split())) for line in lines.splitlines() if len(line.split()) == 2]
            expanded = owned | {pid for pid, parent in rows if parent in owned}
            if expanded == owned:
                break
            # 其父已暂停，不会回收子 PID；先暂停新发现的孩子，再看下一层。
            for pid in expanded - owned:
                try:
                    os.kill(pid, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
            owned = expanded
        for pid in owned - {process.pid}:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    finally:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)
    return sorted(owned)

def run(binary, log_directory):
    began = time.monotonic()
    process = subprocess.Popen([str(binary)], start_new_session=True)
    try:
        result = process.wait(timeout=30)
        print('PROBE: CLI lifetime %.3f s, exit %d' % (time.monotonic() - began, result), flush=True)
        return result
    except subprocess.TimeoutExpired:
        trace = Path(log_directory) / 'watchdog.sample.txt'
        try:
            with (Path(log_directory) / 'watchdog-sample-command.log').open('w') as output:
                subprocess.run(['/usr/bin/arch', '-arm64', '/usr/bin/sample', str(process.pid), '1', '1', '-file', str(trace)],
                               timeout=4, stdout=output, stderr=subprocess.STDOUT)
        except subprocess.TimeoutExpired:
            pass
        finally:
            owned = stop_owned_tree(process)
            (Path(log_directory) / 'watchdog-owned-pids.json').write_text(json.dumps(owned))
        print('FAIL: owned synthetic probe checks exceeded the independent 30-second watchdog', flush=True)
        print('Native timeout trace: ' + str(trace), flush=True)
        return 1

if __name__ == '__main__':
    sys.exit(run(Path(sys.argv[1]), Path(sys.argv[1]).parent))
