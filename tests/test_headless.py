"""Background start on Windows (pythonw) has no console: output must go to a log file."""
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_headless_server_logs_to_file(tmp_path):
    port = _free_port()
    data = tmp_path / "data"
    code = ("import sys; sys.stdout = None; sys.stderr = None; sys.path.insert(0, %r)\n"
            "from navcoach.main import run; run()\n" % str(ROOT))
    proc = subprocess.Popen([sys.executable, "-c", code], cwd=tmp_path,
                            env={**os.environ, "NAV_DATA_DIR": str(data), "NAV_PORT": str(port)},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ok = False
        for _ in range(60):
            time.sleep(0.25)
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=2) as r:
                    ok = r.status == 200
                    break
            except OSError:
                continue
        assert ok, "server did not start without a console"
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    log = (data / "navcoach.log").read_text(encoding="utf-8")
    assert "Nav Coaching started" in log and "GET /api/health" in log
