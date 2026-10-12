#!/usr/bin/env python3
"""Measure the classic fd engine exactly as Find.qml drives it.

For every (query, filter) case both helper processes (dirs and files) start
concurrently and the measurement stops when both have exited, which is when
Find.qml can rank. CPU is the rusage of the helper trees (helper + fd).

Usage: bench_classic.py HOME HELPER REPEATS OUT.json
"""

from __future__ import annotations

import json
import os
import resource
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from cases import FILTERS, QUERIES  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def argv_for(home: str, helper: str, query: str, filt: int) -> dict:
    out = subprocess.run(["node", os.path.join(HERE, "backend.js"), home, helper, query, str(filt)],
                         capture_output=True, check=True).stdout
    return json.loads(out)


def run_once(argvs: dict) -> tuple[float, float, dict]:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    procs = {k: subprocess.Popen(v, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) for k, v in argvs.items()}
    outputs = {k: p.communicate()[0] for k, p in procs.items()}
    wall = (time.perf_counter() - start) * 1000
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)) * 1000
    return wall, cpu, {k: [l for l in v.decode("utf-8", "surrogateescape").split("\n") if l] for k, v in outputs.items()}


def main() -> int:
    home, helper, repeats, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    results = []
    for query, label in QUERIES:
        for filt in FILTERS:
            argvs = argv_for(home, helper, query, filt)
            first_wall, first_cpu, outputs = run_once(argvs)
            walls, cpus = [], []
            for _ in range(repeats):
                wall, cpu, _ = run_once(argvs)
                walls.append(wall)
                cpus.append(cpu)
            walls.sort()
            results.append({
                "query": query, "label": label, "filter": filt,
                "first_ms": first_wall,
                "median_ms": statistics.median(walls),
                "p95_ms": walls[max(0, int(len(walls) * 0.95) - 1)],
                "cpu_ms": statistics.median(cpus),
                "counts": {k: len(v) for k, v in outputs.items()},
                "outputs": outputs,
            })
            print(f"{query!r:22} f{filt} median {results[-1]['median_ms']:7.1f} ms  cpu {results[-1]['cpu_ms']:7.1f} ms  "
                  f"counts {results[-1]['counts']}", flush=True)
    with open(out_path, "w") as fh:
        json.dump(results, fh)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
