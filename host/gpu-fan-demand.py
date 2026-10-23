#!/usr/bin/env python3
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os

LISTEN_ADDR = os.environ.get("GPU_FAN_DEMAND_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("GPU_FAN_DEMAND_PORT", "80"))

current_duty = 10
duty_lock = threading.Lock()

def gpu_duty():
    global current_duty
    result = subprocess.run(
        [
            "/usr/bin/nvidia-smi",
            "--query-gpu=temperature.gpu,utilization.gpu,power.draw",
            "--format=csv,noheader,nounits",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=3,
    )
    rows = []
    for line in result.stdout.splitlines():
        values = [value.strip() for value in line.split(",")]
        if len(values) != 3:
            raise ValueError("unexpected nvidia-smi output")
        rows.append(tuple(float(value) for value in values))
    if len(rows) != 2:
        raise ValueError("expected two GPUs")

    hottest = max(row[0] for row in rows)
    busy = any(row[1] >= 10 or row[2] >= 60 for row in rows)

    with duty_lock:
        # Raise immediately, but require a 2C drop before each thermal step
        # releases so the fans do not hunt as temperature crosses a boundary.
        if hottest >= 80 or (current_duty >= 100 and hottest >= 78):
            current_duty = 100
        elif hottest >= 78 or (current_duty >= 60 and hottest >= 76):
            current_duty = 60
        elif hottest >= 75 or (current_duty >= 40 and hottest >= 73):
            current_duty = 40
        elif hottest >= 71 or (current_duty >= 30 and hottest >= 69):
            current_duty = 30
        elif busy or (current_duty >= 20 and hottest >= 64):
            current_duty = 20
        else:
            current_duty = 10
        return current_duty


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/duty":
            self.send_error(404)
            return
        try:
            body = f"{gpu_duty()}\n".encode()
        except Exception:
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler).serve_forever()
