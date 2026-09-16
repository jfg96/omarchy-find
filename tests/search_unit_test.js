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

const pluginDir = "/home/test/.config/omarchy/plugins/jesseburlamaque.omarchy-find"
const indexed = backend.buildArgv("project notes", 3, false, "/home/test", pluginDir)
assert(indexed[0] === pluginDir + "/bin/omarchy-find-search", "non-empty queries use indexed helper")
assert(indexed.includes("--extensions"), "document category passes extensions")
assert(!indexed.includes("--follow"), "indexed search never follows symlinks")

const browse = backend.buildArgv("", 0, true, "/home/test", pluginDir)
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

console.log(`${passed} search backend tests passed`)
