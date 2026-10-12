#!/usr/bin/env python3
"""Compare classic and indexed benchmark runs on one dataset.

Usage: analyze.py HOME CLASSIC.json INDEX.json HELPER

* Parity: when neither engine hit the candidate cap, the candidate sets must
  be identical.
* Ranking quality: when a cap was hit, the visible top 60 of each engine is
  compared with the ideal top 60, obtained by running the classic helper with
  no cap (every match, an oracle independent of the index) and ranking with
  FindBackend.rankResults.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from bench_classic import argv_for  # noqa: E402
from cases import FILTER_NAMES  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def rank(cases: list[dict]) -> list[dict]:
    out = subprocess.run(["node", os.path.join(HERE, "rank.js"), "60"], input=json.dumps(cases).encode(),
                         capture_output=True, check=True).stdout
    return json.loads(out)


def uncapped(home: str, helper: str, query: str, filt: int) -> dict:
    argvs = argv_for(home, helper, query, filt)
    out = {}
    for kind, argv in argvs.items():
        argv = list(argv)
        argv[argv.index("--max-results") + 1] = "100000000"
        text = subprocess.run(argv, capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape")
        out[kind] = [l for l in text.split("\n") if l]
    return out


def main() -> int:
    home, classic_path, index_path, helper = sys.argv[1:5]
    classic = json.load(open(classic_path))
    index_doc = json.load(open(index_path))
    index = index_doc["results"]
    rows, quality = [], []
    mismatches = []
    for c, i in zip(classic, index):
        assert c["query"] == i["query"] and c["filter"] == i["filter"]
        capped = any(len(v) >= 2000 for v in c["outputs"].values()) or any(len(v) >= 2000 for v in i["outputs"].values())
        parity = None
        if not capped:
            parity = all(sorted(c["outputs"].get(k, [])) == sorted(i["outputs"].get(k, [])) for k in ("dirs", "files"))
            if not parity:
                for k in ("dirs", "files"):
                    a, b = set(c["outputs"].get(k, [])), set(i["outputs"].get(k, []))
                    if a != b:
                        mismatches.append((c["query"], c["filter"], k, sorted(a - b)[:3], sorted(b - a)[:3]))
        rows.append((c, i, capped, parity))
        if capped:
            full = uncapped(home, helper, c["query"], c["filter"])
            r = rank([
                {"query": c["query"], "home": home, **full},
                {"query": c["query"], "home": home, **c["outputs"]},
                {"query": c["query"], "home": home, **i["outputs"]},
            ])
            ideal = r[0]["top"]
            quality.append({
                "query": c["query"], "filter": c["filter"],
                "matches": sum(len(v) for v in full.values()),
                "classic_overlap": len(set(r[1]["top"]) & set(ideal)),
                "index_overlap": len(set(r[2]["top"]) & set(ideal)),
                "classic_exact_order": r[1]["top"] == ideal,
                "index_exact_order": r[2]["top"] == ideal,
                "ideal_len": len(ideal),
                "rank_ms_v8": r[1]["rank_ms"],
            })

    print(f"{'query':18} {'filter':7} {'classic':>9} {'index':>7} {'engine':>7} {'speedup':>8} {'cpu c':>8} {'cpu i':>6}  parity")
    for c, i, capped, parity in rows:
        print(f"{c['query']:18} {FILTER_NAMES[c['filter']]:7} {c['median_ms']:9.1f} {i['median_ms']:7.2f} {i['engine_ms']:7.2f} "
              f"{c['median_ms'] / i['median_ms']:7.0f}x {c['cpu_ms']:8.0f} {i['cpu_ms']:6.1f}  "
              f"{'capped' if capped else ('same' if parity else 'DIFF')}")
    cm = [r[0]["median_ms"] for r in rows]
    im = [r[1]["median_ms"] for r in rows]
    cc = [r[0]["cpu_ms"] for r in rows]
    ic = [r[1]["cpu_ms"] for r in rows]
    summary = {
        "cases": len(rows),
        "classic_median_of_medians_ms": statistics.median(cm),
        "index_median_of_medians_ms": statistics.median(im),
        "classic_max_ms": max(cm), "index_max_ms": max(im),
        "classic_p95_case_ms": sorted(cm)[int(len(cm) * .95) - 1],
        "index_p95_case_ms": sorted(im)[int(len(im) * .95) - 1],
        "classic_cpu_median_ms": statistics.median(cc), "index_cpu_median_ms": statistics.median(ic),
        "classic_cpu_total_ms": sum(cc), "index_cpu_total_ms": sum(ic),
        "parity_checked": sum(1 for r in rows if r[3] is not None),
        "parity_same": sum(1 for r in rows if r[3]),
        "capped_cases": sum(1 for r in rows if r[2]),
        "ready_ms": index_doc["ready_ms"], "daemon_status": index_doc["status"],
    }
    print(json.dumps(summary, indent=1))
    for m in mismatches:
        print("MISMATCH", m)
    print(f"{'capped query':18} {'filter':7} {'matches':>8} {'classic∩ideal':>14} {'index∩ideal':>12} order(c/i)")
    for q in quality:
        print(f"{q['query']:18} {FILTER_NAMES[q['filter']]:7} {q['matches']:8} {q['classic_overlap']:>10}/{q['ideal_len']} "
              f"{q['index_overlap']:>9}/{q['ideal_len']}  {q['classic_exact_order']}/{q['index_exact_order']}")
    json.dump({"summary": summary, "quality": quality, "mismatches": mismatches},
              open(index_path.replace(".json", ".analysis.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
