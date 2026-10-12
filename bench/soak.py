#!/usr/bin/env python3
"""RSS and CPU of the daemon over many mixed queries, then idle.
Usage: soak.py HOME BIN QUERIES"""
import random, sys, time
sys.path.insert(0, __import__("os").path.dirname(__file__))
from bench_index import Conn, cpu_ms, request_for, rss_kib, start_daemon
from cases import FILTERS, QUERIES
home, binary, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
sock = f"/run/user/1000/ofind-soak-{__import__('os').getpid()}.sock"
proc, ready = start_daemon(binary, home, sock, [])
conn = Conn(sock)
reqs = [request_for(q, f, 300) for q, _ in QUERIES for f in FILTERS]
rng = random.Random(1)
# Typing-like prefixes as well, the realistic load with a 30 ms debounce.
for q, _ in QUERIES:
    for i in range(1, len(q)):
        r = dict(reqs[0]); r["query"] = q[:i]; reqs.append(r)
print(f"ready {ready:.0f} ms, rss after crawl {rss_kib(proc.pid)} KiB", flush=True)
c0 = cpu_ms(proc.pid); t0 = time.perf_counter(); samples = []
for i in range(n):
    conn.ask(rng.choice(reqs))
    if i % (n // 5) == 0: samples.append(rss_kib(proc.pid))
wall = time.perf_counter() - t0
print(f"{n} queries in {wall:.1f} s, daemon cpu {cpu_ms(proc.pid) - c0:.0f} ms, rss samples KiB {samples} -> {rss_kib(proc.pid)}", flush=True)
c1 = cpu_ms(proc.pid); time.sleep(30)
print(f"idle 30 s: cpu {cpu_ms(proc.pid) - c1:.0f} ms, rss {rss_kib(proc.pid)} KiB")
proc.terminate(); proc.wait()
