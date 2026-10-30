#!/usr/bin/env node
// lince daemon lifecycle in Find.qml. The real QML function bodies are
// extracted from the source and run against stubs for the Process, Socket
// and Timer objects they touch, so this does not launch Quickshell.

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.join(__dirname, "..")
const qml = fs.readFileSync(path.join(root, "Find.qml"), "utf8")
const backendSource = fs.readFileSync(path.join(root, "FindBackend.js"), "utf8")
  .replace(/^\.pragma library\s*/, "")

let passed = 0
function assert(condition, message) {
  if (!condition) throw new Error(message)
  passed++
}

// Text between the brace that follows `marker` and its matching brace.
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

function property(name) {
  const match = qml.match(new RegExp("property \\w+ " + name + ": (.+)\\n"))
  if (!match) throw new Error("property not found: " + name)
  return match[1]
}

function makeShell(env) {
  const warnings = []
  const ctx = {
    console: { log: console.log, warn: (text) => warnings.push(text) },
    warnings,
    Quickshell: { env: (name) => env[name] },
    launches: 0,
  }
  vm.createContext(ctx)
  vm.runInContext("var Backend = (function() {" + backendSource +
    "; return { DEFAULT_ENGINE: DEFAULT_ENGINE, LINCE_MISSING: LINCE_MISSING, parseSearchConfig: parseSearchConfig," +
    " buildIndexDaemonArgv: buildIndexDaemonArgv, indexSocketPath: typeof indexSocketPath === 'function' ? indexSocketPath : undefined," +
    " searchConfigChanges: typeof searchConfigChanges === 'function' ? searchConfigChanges : undefined," +
    " indexRelaunchOnDisconnect: typeof indexRelaunchOnDisconnect === 'function' ? indexRelaunchOnDisconnect : undefined," +
    " indexPrivateSocketPath: indexPrivateSocketPath, INDEX_STATUS_REQUEST: INDEX_STATUS_REQUEST, indexServesHome: indexServesHome," +
    " logTail: logTail } })()", ctx)
  vm.runInContext(`
    var indexDaemon = {
      _running: false, command: [],
      get running() { return this._running },
      set running(v) { if (v && !this._running) launches++; this._running = v }
    }
    var indexSocket = {
      connected: false, sent: [],
      write: function(text) { this.sent.push(text) }, flush: function() {}
    }
    var indexRestart = { running: false, restart: function() { this.running = true }, stop: function() { this.running = false } }
    var root = {
      home: "/home/test",
      indexBinaryPath: "/p/bin/lince-launcher",
      searchEngine: Backend.DEFAULT_ENGINE,
      searchConfigApplied: false,
      indexMissing: false,
      indexRestartDelay: 2000,
      indexDaemonLog: [],
      daemonLogged: function(line) {` + block("onRead: function(line) { root.indexDaemonLog") + `},
      indexFallback: function() {},
      indexVerified: false,
      indexConnected: function() {` + block("function indexConnected()") + `},
      indexStatusAnswered: function(resp) {` + block("function indexStatusAnswered(resp)") + `},
      indexResponse: function(line) {` + block("function indexResponse(line)") + `},
      ensureIndexDaemon: function() {` + block("function ensureIndexDaemon()") + `},
      applySearchConfig: function(text) {` + block("function applySearchConfig(text)") + `},
      disconnected: function() { var connected = false;` + block("onConnectionStateChanged:") + `},
      daemonExited: function(exitCode) {` + block("onExited: function(exitCode) {\n      if (exitCode !== 0 && root.indexDaemonLog") + `}
    }
    root.indexSocketPath = ` + property("indexSocketPath") + `
    root.indexPrivateSocketPath = ` + property("indexPrivateSocketPath") + `
  `, ctx)
  return ctx
}

// The config watchdog reloads search.json every five seconds. While a lince
// that crashed or could not be downloaded waits out its backoff, those reloads
// must not relaunch it.
{
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  shell.root.applySearchConfig(null)
  assert(shell.launches === 1, "the first search.json load starts lince")
  shell.indexDaemon.running = false
  shell.root.daemonExited(1)
  assert(shell.indexRestart.running, "a failed lince schedules a restart")
  for (let tick = 0; tick < 12; tick++) shell.root.applySearchConfig(null)
  assert(shell.launches === 1, "watchdog reloads leave the restart to its backoff (" + shell.launches + " launches)")
  shell.root.applySearchConfig('{"engine":"fd"}')
  shell.root.applySearchConfig(null)
  assert(shell.launches === 2, "a real engine change restarts lince at once")
  assert(!shell.indexRestart.running && shell.root.indexRestartDelay === 2000, "an engine change resets the backoff")
}

// Another daemon (a systemd user service, the previous shell's) already holds
// the socket: our lince exits 0 and we use theirs. Reloads must not keep
// spawning launchers that exit at once, and when that daemon goes away ours
// must come back.
{
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  shell.root.applySearchConfig(null)
  shell.indexSocket.connected = true
  shell.indexDaemon.running = false
  shell.root.daemonExited(0)
  assert(!shell.indexRestart.running, "nothing to restart while another daemon serves")
  for (let tick = 0; tick < 12; tick++) shell.root.applySearchConfig(null)
  assert(shell.launches === 1, "watchdog reloads do not respawn lince next to a serving daemon (" + shell.launches + " launches)")
  shell.indexSocket.connected = false
  shell.root.disconnected()
  assert(shell.indexRestart.running, "losing the other daemon schedules our own lince")
}

// A disconnect while our own lince is still running or already scheduled
// leaves the restart to onExited.
{
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  shell.root.applySearchConfig(null)
  shell.root.disconnected()
  assert(!shell.indexRestart.running, "a running lince is restarted by its own exit, not by the disconnect")
  shell.root.applySearchConfig('{"engine":"fd"}')
  shell.indexDaemon.running = false
  shell.root.disconnected()
  assert(!shell.indexRestart.running, "the fd engine never relaunches lince")
}

// Without XDG_RUNTIME_DIR there is no private place for the socket.
{
  const shell = makeShell({})
  assert(shell.root.indexSocketPath === "", "no socket path under a shared /tmp (got " + shell.root.indexSocketPath + ")")
  shell.root.applySearchConfig(null)
  assert(shell.launches === 0, "lince is not started without a private socket directory")
  const ok = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000/" })
  assert(ok.root.indexSocketPath === "/run/user/1000/lince/lince.sock", "lince's default socket under XDG_RUNTIME_DIR first")
  assert(ok.root.indexPrivateSocketPath === "/run/user/1000/oma-find/lince.sock", "and a socket of our own beside it")
  assert(makeShell({ XDG_RUNTIME_DIR: "relative" }).root.indexSocketPath === "", "a relative XDG_RUNTIME_DIR is ignored")
}

// A daemon on lince's default socket is asked what it indexes before any
// search goes to it. One that indexes $HOME (ours, or a systemd user
// service) is used as is.
{
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  shell.indexSocket.connected = true
  shell.root.indexConnected()
  assert(!shell.root.indexVerified, "a daemon on the default socket is not trusted before it answers")
  assert(shell.indexSocket.sent.length === 1 && JSON.parse(shell.indexSocket.sent[0]).op === "status", "it is asked its status")
  shell.root.indexResponse(JSON.stringify({ v: 1, roots: ["/mnt/data", "/home/test/"] }))
  assert(shell.root.indexVerified, "a daemon that indexes $HOME is used")
  assert(shell.root.indexSocketPath === "/run/user/1000/lince/lince.sock", "on the shared socket")
  assert(shell.warnings.length === 0, "without a word in the log")
}

// One over other roots, of another protocol version, or that cannot answer,
// is left alone, and ours starts on our own socket, trusted at once.
for (const answer of [
  JSON.stringify({ v: 1, roots: ["/mnt/data"] }),
  JSON.stringify({ v: 2, roots: ["/home/test"] }),
  JSON.stringify({ v: 1, error: "unknown op" }),
  "not json",
]) {
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  shell.root.applySearchConfig(null)
  shell.indexDaemon.running = false // it found the socket served and exited 0
  shell.indexSocket.connected = true
  shell.root.indexConnected()
  shell.root.indexResponse(answer)
  assert(!shell.root.indexVerified && !shell.indexSocket.connected, "the foreign daemon is dropped: " + answer)
  assert(shell.root.indexSocketPath === "/run/user/1000/oma-find/lince.sock", "for our own socket: " + answer)
  assert(shell.indexDaemon.running && shell.indexDaemon.command.indexOf("/run/user/1000/oma-find/lince.sock") > 0, "where ours starts: " + answer)
  assert(shell.warnings.length === 1, "saying so once: " + answer)
  shell.indexSocket.connected = true
  shell.indexSocket.sent = []
  shell.root.indexConnected()
  assert(shell.root.indexVerified && shell.indexSocket.sent.length === 0, "our own socket needs no status: " + answer)
}

// lince's stderr stays out of the shell log while it runs, and its last lines
// reach it when it fails.
{
  const shell = makeShell({ XDG_RUNTIME_DIR: "/run/user/1000" })
  for (let i = 1; i <= 25; i++) shell.root.daemonLogged("lince: line " + i)
  assert(shell.warnings.length === 0, "a running lince logs nothing")
  assert(shell.root.indexDaemonLog.length === 20, "only the last 20 lines are kept")
  shell.root.daemonExited(1)
  assert(shell.warnings.length === 1 && /exited 1/.test(shell.warnings[0]), "a failed lince is reported once")
  assert(/line 25$/.test(shell.warnings[0]) && !/line 5\n/.test(shell.warnings[0]), "with its last lines")
  assert(shell.root.indexDaemonLog.length === 0, "the kept lines go with the exit")
  shell.root.daemonLogged("lince: already running on /run/user/1000/lince/lince.sock")
  shell.root.daemonExited(0)
  assert(shell.warnings.length === 1, "a lince that found another one serving logs nothing")
}

// Each opening starts with no remembered dates, so they do not pile up.
assert(/root\.opened = true\n\s*root\.mtimesMap = \(\{\}\)/.test(qml), "open() clears the mtime cache")

// Re-sorting or changing the display limit reuses the mtimes it already has.
assert(!/presentResults\(root\.rawItems\)/.test(qml), "sort and limit changes pass the known mtimes")

console.log(`${passed} lince lifecycle tests passed`)
