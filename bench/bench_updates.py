#!/usr/bin/env python3
"""Incremental update tests for the indexed engine.

Usage: [SEED=n STEPS=n WIDTH=n] bench_updates.py BIN WORKDIR

1. read-your-writes: create / rename / delete a file, then query at once;
   the change must be visible in the very next response.
2. random stress: thousands of mixed operations (files and directories,
   moves inside, into and out of the tree, renames to excluded and hidden
   names, populating freshly created directories); afterwards the full index
   must equal a fresh fd listing.
3. directory rename with many descendants (O(1) in a parent-reference index).
4. bulk creation large enough to overflow the inotify queue, recovered by
   ctime validation.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from bench_index import EXCLUDES, Conn, start_daemon  # noqa: E402

FULL = {"id": 9, "query": "", "kinds": ["d", "f"], "max_results": 10**8, "hidden": True,
        "exclude": EXCLUDES, "mtimes": 0, "select": "first"}


def fd_listing(root: str) -> set[str]:
    argv = ["fd", "-0", "--no-ignore", "--hidden", "--color=never"]
    for p in EXCLUDES:
        argv += ["-E", p]
    out = set()
    for kind in ("d", "f"):
        raw = subprocess.run(argv + ["--type", kind, ".", root], capture_output=True, check=True).stdout
        out |= {os.path.normpath(os.fsdecode(r)) for r in raw.split(b"\0") if r}
    return out


def index_listing(conn: Conn) -> set[str]:
    _, r = conn.ask(FULL)
    return set(r["dirs"]) | set(r["files"])


def find(conn: Conn, name: str) -> list[str]:
    _, r = conn.ask({"id": 1, "query": name, "kinds": ["d", "f"], "hidden": True, "exclude": EXCLUDES, "mtimes": 0})
    return r["dirs"] + r["files"]


def main() -> int:
    binary, work = sys.argv[1], sys.argv[2]
    root = os.path.join(work, "home")
    outside = os.path.join(work, "outside")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(root)
    os.makedirs(outside)
    width = int(os.environ.get("WIDTH", "50"))
    for i in range(width):
        os.makedirs(os.path.join(root, f"d{i}", "sub"))
        for j in range(20):
            open(os.path.join(root, f"d{i}", f"f{j}.txt"), "w").close()
    sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), f"ofind-upd-{os.getpid()}.sock")
    proc, ready = start_daemon(binary, root, sock, [])
    conn = Conn(sock)
    report = {"ready_ms": ready}

    # 1. read-your-writes
    misses, times = 0, []
    for i in range(300):
        name = f"ryw_{i}_zq.md"
        path = os.path.join(root, f"d{i % 50}", name)
        open(path, "w").close()
        t = time.perf_counter()
        hit = any(p == path for p in find(conn, name))
        times.append((time.perf_counter() - t) * 1000)
        misses += not hit
        new = path.replace("ryw_", "ren_")
        os.rename(path, new)
        hits = find(conn, f"{i}_zq.md")
        misses += not (new in hits and path not in hits)
        os.unlink(new)
        misses += any(p == new for p in find(conn, f"ren_{i}_zq.md"))
    times.sort()
    report["read_your_writes"] = {"operations": 900, "stale_answers": misses,
                                  "query_after_change_median_ms": times[len(times) // 2]}
    print("read-your-writes:", report["read_your_writes"], flush=True)

    # 2. random stress
    rng = random.Random(int(os.environ.get("SEED", "7")))
    ops = {}
    dirs = [os.path.join(root, f"d{i}") for i in range(width)]

    def any_dir() -> str:
        live = [d for d in dirs if os.path.isdir(d)]
        return rng.choice(live) if live else root

    t0 = time.perf_counter()
    for step in range(int(os.environ.get("STEPS", "4000"))):
        op = rng.choice(["mkfile"] * 4 + ["mkdir_populate"] * 3 + ["rm", "rename", "rename", "move_dir",
                         "move_out", "move_in", "move_in", "to_excluded", "to_hidden", "rmtree"])
        ops[op] = ops.get(op, 0) + 1
        try:
            if op == "mkfile":
                open(os.path.join(any_dir(), f"s{step}.dat"), "w").close()
            elif op == "mkdir_populate":
                d = os.path.join(any_dir(), f"n{step}")
                os.makedirs(os.path.join(d, "x", "y"))
                for k in range(5):
                    open(os.path.join(d, "x", "y", f"k{k}"), "w").close()
                dirs.append(d)
            elif op in ("rm", "rename"):
                base = any_dir()
                files = [f for f in os.listdir(base) if os.path.isfile(os.path.join(base, f))]
                if files:
                    f = os.path.join(base, rng.choice(files))
                    if op == "rm":
                        os.unlink(f)
                    else:
                        os.rename(f, os.path.join(any_dir(), f"r{step}_" + os.path.basename(f)))
            elif op == "move_dir":
                src, dst = any_dir(), any_dir()
                if src != root and not dst.startswith(src):
                    target = os.path.join(dst, f"m{step}")
                    os.rename(src, target)
                    dirs = [target + d[len(src):] if d == src or d.startswith(src + "/") else d for d in dirs]
            elif op == "move_out":
                src = any_dir()
                if src != root and rng.random() < 0.5:
                    os.rename(src, os.path.join(outside, f"o{step}"))
            elif op == "move_in":
                kids = os.listdir(outside)
                if kids:
                    target = os.path.join(any_dir(), f"i{step}")
                    os.rename(os.path.join(outside, rng.choice(kids)), target)
                    dirs.append(target)
            elif op == "to_excluded":
                src = any_dir()
                if src != root:
                    os.rename(src, os.path.join(os.path.dirname(src), "node_modules"))
            elif op == "to_hidden":
                src = any_dir()
                if src != root:
                    target = os.path.join(os.path.dirname(src), f".h{step}")
                    os.rename(src, target)
                    dirs.append(target)
            elif op == "rmtree":
                src = any_dir()
                if src != root and rng.random() < 0.15:
                    shutil.rmtree(src)
        except OSError:
            pass
        if step % 500 == 0:
            index_listing(conn)  # interleave queries with the event stream
    ops_ms = (time.perf_counter() - t0) * 1000
    t = time.perf_counter()
    got = index_listing(conn)
    sync_ms = (time.perf_counter() - t) * 1000
    want = fd_listing(root)
    report["stress"] = {"operations": int(os.environ.get("STEPS", "4000")), "by_type": ops, "ops_wall_ms": ops_ms,
                        "first_query_after_ms": sync_ms, "index_entries": len(got), "fd_entries": len(want),
                        "missing": sorted(want - got)[:5], "extra": sorted(got - want)[:5],
                        "identical": got == want}
    print("stress:", report["stress"], flush=True)

    # 3. directory rename with many descendants
    big = os.path.join(root, "bigdir")
    os.makedirs(big)
    for i in range(100):
        sub = os.path.join(big, f"s{i}")
        os.makedirs(sub)
        for j in range(100):
            open(os.path.join(sub, f"leaf{j}"), "w").close()
    index_listing(conn)
    t = time.perf_counter()
    os.rename(big, os.path.join(root, "bigdir_renamed"))
    hits = find(conn, "bigdir_renamed/s99/leaf99")
    rename_ms = (time.perf_counter() - t) * 1000
    report["dir_rename_10k"] = {"descendants": 10100, "rename_plus_query_ms": rename_ms,
                                "found": any(h.endswith("bigdir_renamed/s99/leaf99") for h in hits)}
    print("dir rename:", report["dir_rename_10k"], flush=True)

    # 4. wide directory: many creations in one directory while the daemon
    # keeps up (child lookups must not degrade with directory size).
    wide = os.path.join(root, "wide")
    os.makedirs(wide)
    index_listing(conn)
    t = time.perf_counter()
    for i in range(20000):
        open(os.path.join(wide, f"w{i}"), "w").close()
    create_ms = (time.perf_counter() - t) * 1000
    t = time.perf_counter()
    got = index_listing(conn)
    report["wide_dir"] = {"files": 20000, "create_wall_ms": create_ms,
                          "catch_up_query_ms": (time.perf_counter() - t) * 1000,
                          "identical": got == fd_listing(root)}
    print("wide dir:", report["wide_dir"], flush=True)

    # 5. queue overflow: freeze the daemon so the kernel queue fills up and
    # drops events, then let it recover through ctime validation.
    limit = int(open("/proc/sys/fs/inotify/max_queued_events").read())
    burst = os.path.join(root, "burst")
    os.makedirs(burst)
    index_listing(conn)
    os.kill(proc.pid, 19)  # SIGSTOP
    for i in range(limit + 5000):
        open(os.path.join(burst, f"b{i}"), "w").close()
    shutil.rmtree(wide)
    os.rename(os.path.join(root, "d1"), os.path.join(root, "d1_after_overflow")) if os.path.isdir(os.path.join(root, "d1")) else None
    os.kill(proc.pid, 18)  # SIGCONT
    t = time.perf_counter()
    got = index_listing(conn)
    recover_ms = (time.perf_counter() - t) * 1000
    want = fd_listing(root)
    report["overflow"] = {"files_created": limit + 5000, "queue_limit": limit, "recover_query_ms": recover_ms,
                          "identical": got == want, "missing": len(want - got), "extra": len(got - want)}
    print("overflow:", report["overflow"], flush=True)

    _, status = conn.ask({"id": 0, "op": "status"})
    report["status"] = status
    proc.terminate()
    proc.wait()
    print(proc.stderr.read().decode(errors="replace"))
    json.dump(report, open(os.path.join(os.path.dirname(work), "updates.json"), "w"), indent=1)
    shutil.rmtree(work, ignore_errors=True)
    ok = report["stress"]["identical"] and report["overflow"]["identical"] and report["wide_dir"]["identical"]
    return 0 if ok and not misses else 1


if __name__ == "__main__":
    raise SystemExit(main())
