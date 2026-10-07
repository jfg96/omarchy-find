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

console.log(`${passed} search backend tests passed`)
