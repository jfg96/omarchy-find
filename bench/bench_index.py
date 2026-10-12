#!/usr/bin/env python3
"""Measure the indexed engine over a persistent Unix socket, as Find.qml's
Socket would use it, with the same (query, filter) cases as bench_classic.

Usage: bench_index.py HOME BIN REPEATS OUT.json [--mtimes N]

Reports per case: round trip on a persistent connection (client-perceived
engine + IPC + JSON), the engine time the daemon measured itself, the first
(cold-cache-for-this-query) round trip, and daemon CPU.
"""

from __future__ import annotations

import json
import os
import socket
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from cases import FILTERS, QUERIES  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
EXCLUDES = json.loads(subprocess.run(
    ["node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1]).EXCLUDES))",
     os.path.join(HERE, "backend.js")], capture_output=True, check=True).stdout)


def request_for(query: str, filt: int, mtimes: int) -> dict:
    out = subprocess.run(
        ["node", "-e",
         "const b=require(process.argv[1]);process.stdout.write(JSON.stringify(b.buildIndexRequest(process.argv[2],Number(process.argv[3]),1)))",
         os.path.join(HERE, "backend.js"), query, str(filt)], capture_output=True, check=True).stdout
    req = json.loads(out)
    req["mtimes"] = mtimes
    return req


def cpu_ms(pid: int) -> float:
    fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) * 1000 / os.sysconf("SC_CLK_TCK")


def rss_kib(pid: int) -> int:
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


class Conn:
    def __init__(self, path: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.file = self.sock.makefile("rb")

    def ask(self, req: dict) -> tuple[float, dict]:
        data = (json.dumps(req) + "\n").encode()
        start = time.perf_counter()
        self.sock.sendall(data)
        line = self.file.readline()
        resp = json.loads(line)
        return (time.perf_counter() - start) * 1000, resp


def start_daemon(binary: str, home: str, sock: str, extra: list[str]) -> tuple[subprocess.Popen, float]:
    snap = os.path.join(os.path.dirname(sock), os.path.basename(sock) + ".lnc")
    argv = [binary, "serve", "--socket", sock, "--root", home, "--snapshot", snap] + extra
    for pattern in EXCLUDES:
        argv += ["--exclude", pattern]
    start = time.perf_counter()
    proc = subprocess.Popen(argv, stderr=subprocess.PIPE)
    while True:
        try:
            conn = Conn(sock)
            conn.ask({"id": 0, "op": "status"})
            break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.002)
    return proc, (time.perf_counter() - start) * 1000


def main() -> int:
    home, binary, repeats, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    mtimes = int(sys.argv[sys.argv.index("--mtimes") + 1]) if "--mtimes" in sys.argv else 300
    sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), f"ofind-bench-{os.getpid()}.sock")
    proc, ready_ms = start_daemon(binary, home, sock, [])
    conn = Conn(sock)
    _, status = conn.ask({"id": 0, "op": "status"})
    print(f"daemon ready in {ready_ms:.1f} ms (spawn + crawl + watches): {status}", flush=True)
    results = []
    for query, label in QUERIES:
        for filt in FILTERS:
            req = request_for(query, filt, mtimes)
            first, resp = conn.ask(req)
            walls, engines = [], []
            cpu0 = cpu_ms(proc.pid)
            for _ in range(repeats):
                wall, r = conn.ask(req)
                walls.append(wall)
                engines.append(r["engine_us"] / 1000)
            cpu = (cpu_ms(proc.pid) - cpu0) / repeats
            walls.sort()
            results.append({
                "query": query, "label": label, "filter": filt,
                "first_ms": first,
                "median_ms": statistics.median(walls),
                "p95_ms": walls[max(0, int(len(walls) * 0.95) - 1)],
                "engine_ms": statistics.median(engines),
                "cpu_ms": cpu,
                "counts": {"dirs": len(resp["dirs"]), "files": len(resp["files"])},
                "matched": {"dirs": resp["matched_dirs"], "files": resp["matched_files"]},
                "outputs": {k: resp[k] for k in ("dirs", "files") if k[0] in "".join(req["kinds"]) or resp[k]},
            })
            r = results[-1]
            print(f"{query!r:22} f{filt} rt {r['median_ms']:6.2f} ms engine {r['engine_ms']:6.2f} ms "
                  f"first {first:6.2f} cpu {cpu:5.2f} ms counts {r['counts']} matched {r['matched']}", flush=True)
    _, status = conn.ask({"id": 0, "op": "status"})
    print(f"final status: {status}")
    proc.terminate()
    proc.wait()
    with open(out_path, "w") as fh:
        json.dump({"ready_ms": ready_ms, "status": status, "rss_kib": status.get("rss_kib"), "results": results}, fh)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
