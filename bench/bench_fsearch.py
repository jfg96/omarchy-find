#!/usr/bin/env python3
"""Compare the index with FSearch's engine on the same tree and queries.

Usage: bench_fsearch.py ROOT FSBENCH INDEX_BIN REPEATS OUT.json

FSBENCH is a small harness linked against FSearch's libfsearch that builds a
database for ROOT and times searches from queuing the work to its
"search-finished" signal. Categories map to FSearch as: all → no flag,
folders → folders-only, documents/images/code → files-only plus an
"ext:" term with the same extension list Find uses. FSearch matches names
only (paths for terms with "/"), has no path pass, fuzzy fallback or accent
folding, and cannot hide dotfiles per query, so counts are reported side by
side, not compared for equality.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from bench_index import Conn, cpu_ms, request_for, rss_kib, start_daemon  # noqa: E402
from cases import QUERIES  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FILTERS = {0: "all", 1: "folders", 3: "docs", 4: "images", 7: "code"}


def ext_lists() -> dict:
    out = subprocess.run(["node", "-e",
                          "const b=require(process.argv[1]);process.stdout.write(JSON.stringify({3:b.DOCS_EXTS,4:b.IMAGES_EXTS,7:b.CODE_EXTS}))",
                          os.path.join(HERE, "backend.js")], capture_output=True, check=True).stdout
    return {int(k): v for k, v in json.loads(out).items()}


def main() -> int:
    root, fsbench, binary, repeats, out_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
    exts = ext_lists()
    cases = []
    for q, _ in QUERIES:
        for f in FILTERS:
            if f == 0:
                cases.append((q, f, "a", q))
            elif f == 1:
                cases.append((q, f, "d", q))
            else:
                cases.append((q, f, "f", f"{q} ext:{';'.join(exts[f])}"))

    # FSearch
    db = os.path.join(os.path.dirname(out_path), "fsearch-bench.db")
    t = time.perf_counter()
    proc = subprocess.run([fsbench, root, db, str(repeats)], input="".join(f"{k}\t{text}\n" for _, _, k, text in cases),
                          capture_output=True, text=True)
    fs_log = proc.stderr
    fs_rows = [l.split("\t") for l in proc.stdout.splitlines()]
    print(fs_log.strip())

    # Index
    sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), f"ofind-fs-{os.getpid()}.sock")
    daemon, ready = start_daemon(binary, root, sock, [])
    conn = Conn(sock)
    ix_rows = []
    for q, f, _, _ in cases:
        req = request_for(q, f, 0)
        if os.environ.get("INDEX_SELECT"):
            req["select"] = os.environ["INDEX_SELECT"]
        first, resp = conn.ask(req)
        walls, engines = [], []
        c0 = cpu_ms(daemon.pid)
        for _ in range(repeats):
            w, r = conn.ask(req)
            walls.append(w)
            engines.append(r["engine_us"] / 1000)
        ix_rows.append({"first": first, "median": statistics.median(walls), "engine": statistics.median(engines),
                        "cpu": (cpu_ms(daemon.pid) - c0) / repeats,
                        "matched": resp["matched_dirs"] + resp["matched_files"]})
    ix_rss = rss_kib(daemon.pid)
    daemon.terminate()
    daemon.wait()

    rows = []
    print(f"{'query':18} {'filter':8} {'FSearch ms':>10} {'index rt':>9} {'index eng':>9} {'cpu FS':>7} {'cpu ix':>7} {'hits FS':>8} {'hits ix':>8}")
    for (q, f, _, _), fs, ix in zip(cases, fs_rows, ix_rows):
        fs_med, fs_cpu, fs_hits = float(fs[3]), float(fs[4]), int(fs[5]) + int(fs[6])
        rows.append({"query": q, "filter": FILTERS[f], "fsearch_first_ms": float(fs[2]), "fsearch_ms": fs_med,
                     "fsearch_cpu_ms": fs_cpu, "fsearch_hits": fs_hits, "index_ms": ix["median"],
                     "index_engine_ms": ix["engine"], "index_cpu_ms": ix["cpu"], "index_hits": ix["matched"]})
        print(f"{q:18} {FILTERS[f]:8} {fs_med:10.2f} {ix['median']:9.2f} {ix['engine']:9.2f} {fs_cpu:7.1f} {ix['cpu']:7.1f} {fs_hits:8} {ix['matched']:8}")
    summary = {
        "fsearch_median_ms": statistics.median(r["fsearch_ms"] for r in rows),
        "index_median_ms": statistics.median(r["index_ms"] for r in rows),
        "index_engine_median_ms": statistics.median(r["index_engine_ms"] for r in rows),
        "fsearch_max_ms": max(r["fsearch_ms"] for r in rows),
        "index_max_ms": max(r["index_ms"] for r in rows),
        "fsearch_cpu_median_ms": statistics.median(r["fsearch_cpu_ms"] for r in rows),
        "index_cpu_median_ms": statistics.median(r["index_cpu_ms"] for r in rows),
        "fsearch_log": fs_log, "index_ready_ms": ready, "index_rss_kib": ix_rss,
    }
    print(json.dumps({k: v for k, v in summary.items() if k != "fsearch_log"}, indent=1))
    json.dump({"summary": summary, "rows": rows}, open(out_path, "w"), indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
