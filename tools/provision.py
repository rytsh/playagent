#!/usr/bin/env python3
"""Serve a PlayAgent configuration to the Playdate over the LAN.

Typing API keys and passwords on the Playdate's crank keyboard is painful.
Instead:

  1. Run this script once. It creates `playagent-config.json` next to it
     if missing -- edit that file with your keys/servers.
  2. Run the script again: it prints your LAN IP and serves the config.
  3. On the Playdate: Settings -> "Import config (Wi-Fi)" -> type the IP
     and the short PIN this script prints. Everything (API key, MCP
     servers, opencode remotes) is imported in one shot. The server exits
     after a successful transfer.

The reverse direction works too: `--receive` waits for the Playdate to POST
its current configuration (Settings -> "Export config (Wi-Fi)" on the
device) and writes it to the config file, backing up any existing file to
`<file>.bak`.

Options:
  --file FILE      config file to serve/write (default: playagent-config.json)
  --port PORT      port to listen on   (default: 9393)
  --password PIN   use a fixed PIN instead of a random one
  --no-auth        serve without authentication
  --forever        keep serving instead of exiting after the first transfer
  --receive        receive the config FROM the device instead of serving it

Security: the config travels as plain HTTP on your LAN. Use it on a trusted
network; the random PIN and the exit-after-one-transfer default keep the
window small.
"""

import argparse
import base64
import http.server
import json
import os
import random
import socket
import subprocess
import sys

TEMPLATE = {
    "api": {
        "host": "api.openai.com",
        "port": 443,
        "ssl": True,
        "basePath": "/v1",
        "key": "sk-REPLACE-ME",
        "model": "gpt-4o-mini",
    },
    "stt": {
        "model": "whisper-1",
        "externalModel": "Systran/faster-whisper-small",
        "maxSeconds": 15,
        "language": "",
        # dedicated STT server is ignored unless explicitly enabled
        "useExternal": False,
        "host": "",
        "port": 8000,
        "ssl": False,
        "basePath": "/v1",
        "key": "",
    },
    "mcpServers": [
        {
            "name": "example",
            "host": "mcp.example.com",
            "port": 443,
            "ssl": True,
            "path": "/mcp",
            "enabled": False,
        }
    ],
    "remotes": [
        {
            "name": "dev-pc",
            "host": "192.168.1.20",
            "port": 4096,
            "username": "opencode",
            "password": "",
        }
    ],
    "personaId": "assistant",
}


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "<your-lan-ip>"


def is_wsl():
    return os.path.exists("/mnt/c/Windows/System32/netsh.exe")


def windows_lan_ips():
    """LAN IPs of the Windows host (the ones the Playdate can actually reach
    when running under WSL2's NAT network)."""
    try:
        out = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "(Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway"
             " -ne $null}).IPv4Address.IPAddress"],
            capture_output=True, text=True, timeout=15).stdout
        return [ip.strip() for ip in out.splitlines()
                if ip.strip() and not ip.strip().startswith("169.254.")]
    except Exception:
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default=os.path.join(os.path.dirname(__file__),
                                                   "playagent-config.json"))
    ap.add_argument("--port", type=int, default=9393)
    ap.add_argument("--password", default=None,
                    help="fixed PIN (default: random 6 digits)")
    ap.add_argument("--no-auth", action="store_true")
    ap.add_argument("--forever", action="store_true")
    ap.add_argument("--receive", action="store_true",
                    help="receive the config from the Playdate instead of serving it")
    args = ap.parse_args()

    pin = None
    if not args.no_auth:
        pin = args.password or f"{random.SystemRandom().randrange(0, 1000000):06d}"
        expected = "Basic " + base64.b64encode(f"playagent:{pin}".encode()).decode()

    payload = None
    if not args.receive:
        if not os.path.exists(args.file):
            example = os.path.join(os.path.dirname(__file__),
                                   "playagent-config.example.json")
            if os.path.exists(example):
                with open(example) as src, open(args.file, "w") as dst:
                    dst.write(src.read())
            else:
                with open(args.file, "w") as f:
                    json.dump(TEMPLATE, f, indent=2)
            print(f"Created template: {args.file}")
            print("Edit it with your API key / servers, then run this script again.")
            sys.exit(0)

        with open(args.file) as f:
            try:
                payload = json.dumps(json.load(f)).encode()
            except json.JSONDecodeError as e:
                print(f"error: {args.file} is not valid JSON: {e}")
                sys.exit(1)

    served = False

    class Handler(http.server.BaseHTTPRequestHandler):
        def _authorized(self):
            if pin is None or self.headers.get("Authorization") == expected:
                return True
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="playagent"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            print(f"-> rejected request from {self.client_address[0]} (bad/missing PIN)")
            return False

        def _reply(self, status, text):
            body = text.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            nonlocal served
            if not self._authorized():
                return
            if args.receive or payload is None:
                self._reply(404, "running in --receive mode; POST /config\n")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            served = True
            print(f"-> served config to {self.client_address[0]}")

        def do_POST(self):
            nonlocal served
            if not self._authorized():
                return
            if not args.receive:
                self._reply(404, "not in --receive mode\n")
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
            except json.JSONDecodeError as e:
                self._reply(400, f"invalid JSON: {e}\n")
                print(f"-> rejected config from {self.client_address[0]}: invalid JSON")
                return
            if os.path.exists(args.file):
                backup = args.file + ".bak"
                os.replace(args.file, backup)
                print(f"-> existing {args.file} backed up to {backup}")
            with open(args.file, "w") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
            served = True
            self._reply(200, "ok\n")
            print(f"-> received config from {self.client_address[0]} -> {args.file}")

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("0.0.0.0", args.port), Handler)
    srv.timeout = 1
    suffix = f":{args.port}" if args.port != 9393 else ""
    if args.receive:
        print(f"Waiting to receive the device config into {args.file}")
        print(f"On the Playdate: Settings -> Export config (Wi-Fi)")
    else:
        print(f"Serving {args.file}")
        print(f"On the Playdate: Settings -> Import config (Wi-Fi)")
    if is_wsl():
        wips = windows_lan_ips()
        if wips:
            print(f"  address: {wips[0]}{suffix}"
                  + (f"   (or: {', '.join(wips[1:])})" if len(wips) > 1 else ""))
        else:
            print(f"  address: <windows-lan-ip>{suffix}")
        print(f"  NOTE: running under WSL. The Playdate must reach the")
        print(f"  Windows host; forward the port once with:")
        print(f"    make wsl-forward" + (f" PORT={args.port}" if args.port != 9393 else ""))
    else:
        print(f"  address: {lan_ip()}{suffix}")
    if pin is not None:
        print(f"  PIN:     {pin}")
    else:
        print("  PIN:     (none - leave empty)")
    print("Waiting... (Ctrl+C to stop)")
    try:
        while args.forever or not served:
            srv.handle_request()
    except KeyboardInterrupt:
        pass
    srv.server_close()
    if served:
        print("Done.")


if __name__ == "__main__":
    main()
