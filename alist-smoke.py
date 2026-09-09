"""Build-time integration check: real AList and Nginx with disposable data."""
import importlib.util
import json
import os
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location("prepare", "/app/alist-prepare.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def read(url):
    with opener.open(url, timeout=3) as response:
        return response.headers.get("Content-Type", ""), response.read()


with tempfile.TemporaryDirectory(prefix="alist-smoke-") as directory:
    config = Path(directory) / "config.json"
    module.prepare(config)
    environment = dict(os.environ, ALIST_SITE_URL="https://koyeb.idkwhn.ccwu.cc/alist")
    processes = []
    try:
        processes.append(subprocess.Popen(
            ["/opt/alist/alist", "server", "--data", directory], cwd=directory,
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        processes.append(subprocess.Popen(
            ["nginx", "-c", "/etc/nginx/nginx.conf", "-g", "daemon off;"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for attempt in range(60):
            try:
                content_type, body = read("http://127.0.0.1:8080/alist/api/public/settings")
                assert "application/json" in content_type
                assert json.loads(body)["code"] == 200
                break
            except Exception:
                if any(p.poll() is not None for p in processes) or attempt == 59:
                    raise
                time.sleep(1)
        content_type, body = read("http://127.0.0.1:8080/alist/")
        assert "text/html" in content_type
        assert b"/alist" in body
        _, pong = read("http://127.0.0.1:8080/alist/ping")
        assert pong == b"pong", pong
        print("PASS: AList page, JSON API and ping through Nginx at /alist")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
