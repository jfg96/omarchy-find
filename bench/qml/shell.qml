// Headless driver for Find.qml: never opens the overlay (no surface, no
// keyboard grab), types queries into the real component and reports what it
// would show. Run through bench/qml_driver.sh.
import Quickshell
import QtQuick
import "plugin"
import "plugin/FindBackend.js" as Backend

ShellRoot {
  id: driver

  readonly property string engine: Quickshell.env("DRIVER_ENGINE") || "index"
  readonly property var cases: JSON.parse(Quickshell.env("DRIVER_CASES") || "[]")
  readonly property int repeats: Number(Quickshell.env("DRIVER_REPEATS") || "5")
  property int caseIndex: -1
  property int round: 0
  property bool waiting: false
  property double started: 0
  property int startGen: 0
  property var timings: []

  Find { id: find }

  function emit(obj) { console.log("DRIVER " + JSON.stringify(obj)) }

  Timer {
    id: boot
    interval: 50
    repeat: true
    running: true
    property int ticks: 0
    onTriggered: {
      ticks++
      if (ticks === 1) find.applySearchConfig(JSON.stringify({ engine: driver.engine }))
      var ready = driver.engine === "fd" || find.indexActive
      if (ready || ticks > 200) {
        stop()
        driver.emit({ event: "ready", engine: driver.engine, indexActive: find.indexActive, after_ms: ticks * 50 })
        driver.nextCase()
      }
    }
  }

  function nextCase() {
    caseIndex++
    round = 0
    timings = []
    if (caseIndex >= cases.length) {
      if (Quickshell.env("DRIVER_MODES") === "1" && modes.step === 0) {
        modes.restart()
        return
      }
      emit({ event: "done" })
      Qt.quit()
      return
    }
    find.setActiveFilter(cases[caseIndex].filter)
    settle.restart()
  }

  // Lets the category change settle before measuring the query itself.
  Timer {
    id: settle
    interval: 400
    onTriggered: driver.type()
  }

  function type() {
    var c = cases[caseIndex]
    // Typing: every prefix of the query, 70 ms apart, like a fast typist.
    if (c.typed) {
      var prefixes = []
      for (var i = 1; i <= c.query.length; i++) prefixes.push(c.query.slice(0, i))
      typer.prefixes = prefixes
      typer.restart()
      return
    }
    find.setFilter("")
    clearDelay.restart()
  }

  Timer {
    id: clearDelay
    interval: 300
    onTriggered: {
      driver.waiting = true
      driver.started = Date.now()
      driver.startGen = find.searchGen
      find.setFilter(driver.cases[driver.caseIndex].query)
    }
  }

  Timer {
    id: typer
    interval: 70
    repeat: true
    property var prefixes: []
    onTriggered: {
      var next = prefixes.shift()
      driver.waiting = prefixes.length === 0
      if (driver.waiting) {
        driver.started = Date.now()
        driver.startGen = find.searchGen
      }
      find.setFilter(next)
      if (prefixes.length === 0) stop()
    }
  }

  // "go …" and "ai …" prefixes must never reach a search engine.
  Timer {
    id: modes
    interval: 500
    repeat: true
    property int step: 0
    onTriggered: {
      step++
      if (step === 1) {
        find.setFilter("go hola mundo")
      } else if (step === 2) {
        driver.emit({ event: "mode", mode: "google", isGoogle: find.isGoogleSearch, searching: find.searching,
          indexPending: find.indexPendingGen, state: JSON.parse(find.debugState()) })
        find.setFilter("ai hola mundo")
      } else if (step === 3) {
        driver.emit({ event: "mode", mode: "ai", isAi: find.isAiMode, searching: find.searching,
          indexPending: find.indexPendingGen, state: JSON.parse(find.debugState()) })
        stop()
        driver.emit({ event: "done" })
        Qt.quit()
      }
    }
  }

  Connections {
    target: find
    function onRawItemsChanged() {
      // Only a search started after the last keystroke counts; results of an
      // earlier prefix may still land after it.
      if (!driver.waiting || find.searching || find.searchGen <= driver.startGen) return
      var c = driver.cases[driver.caseIndex]
      if (find.filterText !== c.query) return
      driver.waiting = false
      driver.timings.push(Date.now() - driver.started)
      driver.round++
      if (driver.round < (c.typed ? 1 : driver.repeats)) {
        driver.type()
        return
      }
      var top = Backend.rankResults(find.rawItems, c.query, 60, find.home, "relevance")
      driver.emit({
        event: "case", query: c.query, filter: c.filter, typed: !!c.typed,
        engine: driver.engine, indexActive: find.indexActive,
        timings_ms: driver.timings,
        raw: find.rawItems.map(function(i) { return (i.isDir ? "d:" : "f:") + i.path }).sort(),
        top: top.map(function(i) { return i.path })
      })
      driver.nextCase()
    }
  }
}
