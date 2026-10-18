#!/usr/bin/env node
// Keyboard and pointer interaction in Find.qml. The real QML handler bodies
// are extracted from the source and run against stubs, and the terminal
// command runs in bash against stub terminals; Quickshell is not launched.

const fs = require("fs")
const os = require("os")
const path = require("path")
const vm = require("vm")
const { spawnSync } = require("child_process")

const root = path.join(__dirname, "..")
const qml = fs.readFileSync(path.join(root, "Find.qml"), "utf8")
const backendSource = fs.readFileSync(path.join(root, "FindBackend.js"), "utf8")
  .replace(/^\.pragma library\s*/, "")

let passed = 0
function assert(condition, message) {
  if (!condition) throw new Error(message)
  passed++
}

// Text inside the braces of the first block that starts at `marker`.
function block(marker) {
  const start = qml.indexOf(marker)
  if (start < 0) throw new Error("not found in Find.qml: " + marker)
  const open = qml.indexOf("{", start)
  let depth = 0
  for (let i = open; i < qml.length; i++) {
    if (qml[i] === "{") depth++
    else if (qml[i] === "}" && --depth === 0) return qml.slice(open + 1, i)
  }
  throw new Error("unbalanced block: " + marker)
}

const backend = { console }
vm.createContext(backend)
vm.runInContext(backendSource, backend)

// Qt's modifier values.
const Qt = { NoModifier: 0, ShiftModifier: 0x02000000, ControlModifier: 0x04000000, AltModifier: 0x08000000, KeypadModifier: 0x20000000 }

// A still pointer must not steal the selection: rows slide under it when the
// overlay opens beneath it, when results arrive and when the keyboard scrolls
// the list. Only real pointer movement selects the row under it.
{
  const ctx = { Backend: backend, root: { selectedIndex: 0, lastPointer: null } }
  vm.createContext(ctx)
  const hover = block("onPositionChanged: function(mouse)")
  vm.runInContext("function hoverRow(index, x, y) { var rowRoot = { index: index };" +
    " var mapToItem = function(_, mx, my) { return { x: mx, y: my } }; var mouse = { x: x, y: y };" + hover + "}", ctx)
  ctx.hoverRow(3, 400, 560)
  assert(ctx.root.selectedIndex === 0, "the row under a still pointer stays unselected after opening")
  ctx.hoverRow(4, 400, 560)
  assert(ctx.root.selectedIndex === 0, "rows sliding under a still pointer do not take the selection")
  ctx.hoverRow(4, 400, 572)
  assert(ctx.root.selectedIndex === 4, "moving the pointer selects the row under it")
  assert(!/onContainsMouseChanged:[^\n]*selectedIndex/.test(qml), "entering a row's area alone never selects it")
  assert(/root\.lastPointer = null/.test(block("function open(payloadJson)")), "opening forgets the previous pointer position")
}

// Enter (and Alt+Enter, Ctrl+C, Ctrl+T) while the typed query's search is
// pending waits for its results instead of acting on the previous query's.
function makeList() {
  const ctx = {
    Backend: backend,
    acted: [],
    debounce: { running: false },
    root: { expanded: true, searching: false, pendingAction: "", selectedIndex: 0 },
  }
  vm.createContext(ctx)
  vm.runInContext(`
    root.activateIndex = function(i) { acted.push("open " + i) }
    root.openEnclosingFolder = function(i) { acted.push("folder " + i) }
    root.copyPathToClipboard = function(i) { acted.push("copy " + i) }
    root.openInTerminal = function(i) { acted.push("terminal " + i) }
    root.requestAction = function(kind) {` + block("function requestAction(kind)") + `}
    root.flushPendingAction = function() {` + block("function flushPendingAction()") + `}
    root.runAction = function(kind) {` + block("function runAction(kind)") + `}
  `, ctx)
  return ctx
}
{
  const ctx = makeList()
  ctx.debounce.running = true
  ctx.root.requestAction("open")
  assert(ctx.acted.length === 0, "Enter during the debounce does not open the previous query's result")
  ctx.debounce.running = false
  ctx.root.searching = true
  ctx.root.flushPendingAction()
  assert(ctx.acted.length === 0, "the action keeps waiting while the search runs")
  ctx.root.searching = false
  ctx.root.flushPendingAction()
  assert(ctx.acted.join() === "open 0", "the action runs once the typed query's results are shown")
  ctx.root.flushPendingAction()
  assert(ctx.acted.length === 1, "a pending action runs only once")

  ctx.acted.length = 0
  ctx.root.requestAction("terminal")
  assert(ctx.acted.join() === "terminal 0", "with no search pending the action runs at once")

  ctx.acted.length = 0
  ctx.root.expanded = false
  ctx.debounce.running = true
  ctx.root.requestAction("open")
  assert(ctx.acted.join() === "open 0" && ctx.root.pendingAction === "", "a collapsed overlay never queues an action for a later list")
}
assert(/root\.flushPendingAction\(\)\s*\n\s*}/.test(block("function presentResults(items, mtimesKnown)") + "\n}"), "showing results runs a pending action")
for (const fn of ["function setFilter(nextFilter)", "function cancelProcs()", "function setActiveFilter(index)"])
  assert(/root\.pendingAction = ""/.test(block(fn)), fn + " drops a pending action")
assert(/pendingAction = ""/.test(block("if (!root.expanded || root.isGoogleSearch || root.isAiMode)")), "a search that will not run drops a pending action")

// Typing: the numeric keypad types digits; shortcuts never type.
assert(backend.isTypedText("7", Qt.KeypadModifier, Qt.ShiftModifier | Qt.KeypadModifier), "keypad digits are typed")
assert(backend.isTypedText("A", Qt.ShiftModifier, Qt.ShiftModifier | Qt.KeypadModifier), "shifted letters are typed")
assert(backend.isTypedText("ñ", Qt.NoModifier, Qt.ShiftModifier | Qt.KeypadModifier), "plain letters are typed")
assert(!backend.isTypedText("c", Qt.ControlModifier, Qt.ShiftModifier | Qt.KeypadModifier), "Ctrl shortcuts are not typed")
assert(!backend.isTypedText("x", Qt.AltModifier | Qt.KeypadModifier, Qt.ShiftModifier | Qt.KeypadModifier), "Alt shortcuts are not typed")
assert(!backend.isTypedText("\r", Qt.KeypadModifier, Qt.ShiftModifier | Qt.KeypadModifier), "keypad Enter is not typed")
assert(/Backend\.isTypedText\(event\.text, event\.modifiers, Qt\.ShiftModifier \| Qt\.KeypadModifier\)/.test(qml), "the key handler types through isTypedText")

// Shortcuts that only make sense for the file list.
const keys = block("Keys.onPressed: function(event)")
assert(/Key_S\) \{\s*\/\/[^\n]*\n\s*if \(!root\.isAiMode && !root\.isGoogleSearch\) root\.cycleSortMode\(\)/.test(keys), "Ctrl+S does nothing in AI and Google modes")
assert(/Key_L\) \{\s*if \(!root\.isAiMode && !root\.isGoogleSearch\) root\.cycleDisplayLimit\(\)/.test(keys), "Ctrl+L does nothing in AI and Google modes")
assert(/if \(!root\.isAiMode && !root\.isGoogleSearch\) root\.requestAction\("terminal"\)/.test(keys), "Ctrl+T does nothing in AI and Google modes")
assert(/AltModifier\) && !root\.isGoogleSearch\) \{\s*root\.requestAction\("folder"\)/.test(keys), "Alt+Enter on the Google row opens the search, not google.com")

// Re-sorting keeps the selected entry, not its row number.
{
  const rows = ["/h/a", "/h/b", "/h/c"]
  const ctx = {
    root: { selectedIndex: 2 },
    displayModel: { get count() { return rows.length }, get: (i) => ({ path: rows[i] }) },
    resultList: { positionViewAtIndex: () => {} },
    ListView: { Contain: 0 },
  }
  vm.createContext(ctx)
  vm.runInContext(`
    root.selectedPath = function() {` + block("function selectedPath()") + `}
    root.reselectPath = function(path) {` + block("function reselectPath(path)") + `}
    root.presentResults = function() { rows.reverse() }
    root.setSortMode = function(mode) {` + block("function setSortMode(mode)") + `}
  `, Object.assign(ctx, { rows }))
  ctx.root.setSortMode("name_desc")
  assert(rows[ctx.root.selectedIndex] === "/h/c", "the same entry stays selected after re-sorting")
}
assert(/root\.reselectPath\(path\)/.test(block("function cycleDisplayLimit()")), "changing the limit keeps the selected entry")

// Pasting.
assert(backend.pastedText("one\ntwo\r\n\tthree") === "one two three", "pasted lines become one query")
assert(backend.pastedText("a\u0007b\u007f") === "ab", "pasted control characters are dropped")
assert(/Key_V\) \{\s*root\.pasteClipboard\(\)/.test(keys), "Ctrl+V pastes")
assert(/"wl-paste", "--no-newline", "--type", "text"/.test(qml), "paste reads text from wl-paste")

// Terminal: the first available terminal runs, and only that one, even when
// it exits non-zero; the directory is passed as an argument, never quoted
// into the script.
{
  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "omarchy-find-term-"))
  const bin = path.join(sandbox, "bin")
  const log = path.join(sandbox, "log")
  const dir = path.join(sandbox, "it's a \"dir\" $(touch pwned)")
  fs.mkdirSync(bin)
  fs.mkdirSync(dir)
  const stub = (name, code) => {
    fs.writeFileSync(path.join(bin, name), `#!/bin/sh\necho "${name} $(pwd)" >> "${log}"\nexit ${code}\n`)
    fs.chmodSync(path.join(bin, name), 0o755)
  }
  const run = (env) => {
    fs.rmSync(log, { force: true })
    // Without -l: a login shell's profile would put the real terminals back
    // on PATH, next to the stubs.
    const argv = backend.terminalArgv(dir)
    assert(argv[1] === "-lc", "the terminal starts from a login shell, with the user's PATH")
    const r = spawnSync("/bin/bash", ["-c"].concat(argv.slice(2)), { env: Object.assign({ PATH: bin, WAYLAND_DISPLAY: "", DISPLAY: "", HOME: sandbox }, env) })
    return { status: r.status, log: fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : [] }
  }
  stub("xdg-terminal-exec", 1)
  stub("kitty", 0)
  let r = run({})
  assert(r.log.length === 1 && r.log[0] === "xdg-terminal-exec " + dir, "a terminal exiting non-zero does not start a second one (" + r.log.join(" | ") + ")")
  fs.rmSync(path.join(bin, "xdg-terminal-exec"))
  r = run({ TERMINAL: "" })
  assert(r.log.join() === "kitty " + dir, "an unset $TERMINAL is skipped and the next terminal runs")
  fs.rmSync(path.join(bin, "kitty"))
  r = run({})
  assert(r.status === 127 && r.log.length === 0, "no terminal at all fails cleanly")
  assert(!fs.existsSync(path.join(sandbox, "pwned")) && !fs.existsSync(path.join(dir, "pwned")), "the directory name is never run as shell code")
  fs.rmSync(sandbox, { recursive: true, force: true })
}
assert(/Quickshell\.execDetached\(Backend\.terminalArgv\(target\)\)/.test(qml), "Ctrl+T uses terminalArgv")

console.log(`${passed} interaction tests passed`)
