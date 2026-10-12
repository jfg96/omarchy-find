#!/usr/bin/env python3
"""Start a daemon on HOME and print engine phases for a few (query, filter) cases."""
import json, sys, time
sys.path.insert(0, __import__("os").path.dirname(__file__))
from bench_index import Conn, request_for, start_daemon
home, binary = sys.argv[1], sys.argv[2]
sock = f"/run/user/1000/ofind-probe-{__import__('os').getpid()}.sock"
proc, ready = start_daemon(binary, home, sock, [])
conn = Conn(sock)
for spec in sys.argv[3:]:
    q, f = spec.rsplit(":", 1)
    req = request_for(q, int(f), 300)
    for _ in range(3):
        rt, r = conn.ask(req)
    print(f"{q!r:14} f{f} rt {rt:6.2f} engine {r['engine_us']/1000:6.2f} phases(us) prepare/scan/select/emit {r['phases_us']} matched {r['matched_dirs']}/{r['matched_files']}")
proc.terminate(); proc.wait(); print(proc.stderr.read().decode())
