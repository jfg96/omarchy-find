# Benchmarks: fd helper vs lince

These scripts compare Omarchy Find's two search engines on the same trees, queries and categories: the fd helper (`bin/omarchy-find-search`) and [lince](https://github.com/jfg96/lince). They measured the engine that became lince; its design is documented in lince's README.

## Measurements

Warm cache, 28 threads, btrfs. Each figure is the median over 72 (query, category) cases. Raw summaries are in `bench/results/`.

| Tree | Entries | fd helper | lince | CPU per search (fd → index) |
|---|---:|---:|---:|---:|
| synthetic | 97k | 79 ms | 2.0 ms | 325 → 5 ms |
| real home | 314k | 109 ms | 3.7 ms | 1349 → 10 ms |
| synthetic | 964k | 108 ms | 11 ms | 1798 → 32 ms |

- **Perceived latency** in `Find.qml`, from keystroke to results, debounce included: 308 ms → 41 ms (median, 75 cases).
- **Same candidates:** whenever neither engine hits the 2000 cap, the candidate sets are identical. When the cap is hit, the visible top 60 equals the ideal ranking in every case with lince; for fd it drops as low as 0–1 of 60.
- **Resources (real home):** about 110 ms to start, 28 MB of index, 38–60 MB RSS, about 34k inotify watches, a 5.6 MB snapshot (20 ms to load, 18 ms to validate) and no CPU when idle.
- **Updates:** 0 stale answers over 900 change-then-query rounds. After 4k and 20k random operations (moves in and out of the tree, renames to excluded or hidden names) the index equals a fresh fd listing. A forced inotify overflow and a killed daemon both recover.

## Compared with FSearch 0.3.2

FSearch was built from source (release, LTO). `bench/fsearch/fsbench.c`, a small harness linked against its `libfsearch`, times each search from queuing it to the `search-finished` signal. Both engines get the same trees, excludes, queries and categories; the extension categories use FSearch's `ext:` with Find's lists. Medians over 60 (query, category) cases:

| | FSearch | lince |
|---|---:|---:|
| Home (314k): search | 3.3 ms | 4.1 ms (3.3 ms without relevance selection) |
| Home: CPU per search | 36 ms | 11.5 ms |
| Home: build (warm cache) | 650 ms (3.6 s first run) | 120 ms |
| Home: RSS | 51 → 68 MB after searching | 41–44 MB |
| 1M: search | 14.1 ms | 12.6 ms |
| 1M: CPU per search | 204 ms | 34 ms |
| 1M: build | 2.7 s | 0.37 s |
| 1M: RSS | 143 → 179 MB | 119 MB |

FSearch scans the whole name array on every core for each query, so its wall time on a small tree is excellent at about 3x the CPU. Most of lince's extra wall time on broad one-letter queries goes into relevance selection over hundreds of thousands of candidates, which FSearch does not do (it returns every match sorted by name). FSearch indexes with a single-threaded walk that `fstatat`s every entry, because it also stores sizes and dates. lince reads only `d_type` and stats nothing but the results it returns.

Its semantics are narrower than Find's: it matches names only (paths only for terms containing `/`), with no path pass, no fuzzy fallback and no accent folding (`cancion` does not find `canción`), and it cannot hide dotfiles per query. On a path term (`projects/omarchy`) both return exactly the same 869 matches.

## Known differences between lince and the fd helper

- Folding strips every combining mark, so NFD names and letters such as `å` match consistently. The fd helper uses fixed accent classes.
- The anchored exclude `.local/share/Trash` also applies under *System Folders*. fd anchors excludes to its first search root and misses it there.
- Over-budget candidate sets are the best-ranked ones, chosen deterministically.

## Running them

```sh
python3 bench/make_datasets.py mirror ~ /var/tmp/ofind-bench/mirror   # or: synth 100000 DIR
python3 bench/bench_classic.py DIR bin/omarchy-find-search 10 classic.json
python3 bench/bench_index.py DIR "$(command -v lince)" 20 index.json
python3 bench/analyze.py DIR classic.json index.json bin/omarchy-find-search
python3 bench/bench_updates.py "$(command -v lince)" /var/tmp/ofind-bench/upd/work
bench/qml_driver.sh HOME index CASES_JSON 3 out.log    # real Find.qml, hidden instance
```

`analyze.py` checks parity and ranking quality against an uncapped fd oracle. `bench_fsearch.py` needs FSearch built from source with `fsearch/fsbench.c` added to its tests (that harness links against GPL code and is only built locally). Summaries of the runs above are in `results/`.
