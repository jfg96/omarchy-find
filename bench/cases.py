"""Benchmark query set shared by every engine.

Filter indexes follow FindBackend.FILTERS: 0 all, 1 folders, 2 system folders,
3 documents, 4 images, 7 code.
"""

QUERIES = [
    ("hypr", "config term"),
    ("omarchy find", "two terms"),
    ("cancion", "accent folding"),
    ("informe", "spanish word"),
    ("config", "broad"),
    ("a", "one letter, huge"),
    ("pdf", "extension-like"),
    ("projects/omarchy", "path with slash"),
    ("omfind", "fuzzy fallback"),
    ("xyzzyq", "no match (all passes)"),
    ("bases datos", "two terms, folders"),
    ("main rs", "two short terms"),
]
FILTERS = [0, 1, 2, 3, 4, 7]
FILTER_NAMES = {0: "all", 1: "folders", 2: "system", 3: "docs", 4: "images", 7: "code"}
