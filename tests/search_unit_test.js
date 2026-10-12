#!/usr/bin/env node

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "FindBackend.js"), "utf8")
  .replace(/^\.pragma library\s*/, "")
const backend = { console }
vm.createContext(backend)
vm.runInContext(source, backend)

let passed = 0
function assert(condition, message) {
  if (!condition) throw new Error(message)
  passed++
}

const helperPath = "/opt/custom plugins/renamed-find/bin/omarchy-find-search"
const search = backend.buildArgv("project notes", 3, false, "/home/test", helperPath)
assert(search[0] === helperPath, "non-empty queries use the resolved helper path verbatim")
assert(search.includes("--extensions"), "document category passes extensions")
assert(!search.includes("--follow"), "search never follows symlinks")

const browse = backend.buildArgv("", 0, true, "/home/test", helperPath)
assert(browse[0] === "fd", "empty browse uses fd")
assert(!browse.includes("--follow"), "empty browse never follows symlinks")
assert(browse.includes("--max-results") && browse.includes("2000"), "candidate budget is applied")

const fuzzyScore = backend.scoreItem(
  { name: "omarchy-find", path: "/home/test/.config/omarchy-find" },
  "omfind"
)
assert(fuzzyScore >= 0, "subsequence query is accepted by relevance ranking")

const exactScore = backend.scoreItem(
  { name: "notes.md", path: "/home/test/Documents/notes.md" },
  "notes"
)
assert(exactScore < fuzzyScore, "exact filename match outranks fuzzy match")

// Indexed engine plumbing.
const req = backend.buildIndexRequest("  cancion  ", 3, 7, "/home/test")
assert(req.id === 7 && req.query === "cancion", "index request carries id and trimmed query")
assert(req.kinds.join() === "f", "documents ask for files only")
assert(req.extensions.includes("pdf") && req.hidden === false, "documents keep their extensions and hide dotfiles")
assert(req.max_results === backend.MAX_RESULTS && req.mtimes === 300, "same budget and stat window as the fd path")
assert(req.roots.join() === "/home/test" && req.scopes.length === 0 && req.max_depth === null, "searches the whole home")
const sys = backend.buildIndexRequest("hypr", 2, 1, "/home/test")
assert(sys.hidden && sys.kinds.join() === "d", "system folders request")
assert(sys.scopes.join() === ".config,.local/share" && sys.max_depth === 3, "system folders scope like fd's search paths and --max-depth 3")
assert(sys.exclude.includes("*Cache*") && sys.exclude.includes(".git"), "system folders add their excludes to the base ones")
assert(!backend.buildIndexRequest("x", 0, 1).exclude.includes("*Cache*"), "other categories only use the base excludes")
assert(backend.buildIndexRequest("", 0, 1).kinds.join() === "d,f", "empty query browses both kinds")

assert(backend.parseSearchConfig(null).engine === backend.DEFAULT_ENGINE, "missing search.json uses the default engine")
assert(backend.parseSearchConfig('{"engine":"fd"}').engine === "fd", "search.json can select fd")
assert(backend.parseSearchConfig('{"engine":"turbo"}').engine === backend.DEFAULT_ENGINE, "unknown engines are ignored")
assert(backend.parseSearchConfig("{nope").engine === backend.DEFAULT_ENGINE, "invalid JSON is ignored")

const daemon = backend.buildIndexDaemonArgv("/p/bin/lince", "/run/s.sock", "/home/test")
assert(daemon[0] === "sh" && daemon[4] === "/p/bin/lince", "the launcher prefers the plugin's own copy")
assert(daemon[2].includes("command -v lince") && daemon[2].includes("exit " + backend.LINCE_MISSING), "then PATH, else a distinct exit status")
assert(daemon[5] === "serve" && daemon.includes("--exit-with-parent"), "daemon is tied to the shell")
assert(daemon.filter(a => a === "--exclude").length === backend.EXCLUDES.length, "daemon indexes with the base excludes")

const items = backend.itemsFromPaths(["/home/test/.config/hypr/", "relative", "/home/test/a.md"], true, "/home/test")
assert(items.length === 2 && items[0].name === "hypr" && items[0].isSystem, "index paths become the same items as fd lines")
assert(JSON.stringify(backend.parseLines("/home/test/a.md\n", false, "/home/test")) ===
  JSON.stringify(backend.itemsFromPaths(["/home/test/a.md"], false, "/home/test")), "parseLines and itemsFromPaths agree")

assert(backend.debounceMs(false, "hyprland") === backend.FD_DEBOUNCE_MS, "fd keeps its debounce")
assert(backend.debounceMs(true, "hyp") === backend.INDEX_DEBOUNCE_MS, "index answers longer queries quickly")
assert(backend.debounceMs(true, " h ") === backend.INDEX_SHORT_DEBOUNCE_MS, "one or two characters wait a bit longer")

console.log(`${passed} search backend tests passed`)
