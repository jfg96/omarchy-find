// stdin: JSON [{query, home, dirs, files}] -> stdout: JSON [top paths] using
// FindBackend.parseLines + rankResults, exactly as Find.qml ranks.
const backend = require("./backend.js")
const cases = JSON.parse(require("fs").readFileSync(0, "utf8"))
const limit = Number(process.argv[2] || 60)
const out = cases.map(c => {
  const items = backend.parseLines((c.dirs || []).join("\n"), true, c.home)
    .concat(backend.parseLines((c.files || []).join("\n"), false, c.home))
  const t = process.hrtime.bigint()
  const ranked = backend.rankResults(items, c.query, limit, c.home, "relevance")
  const ms = Number(process.hrtime.bigint() - t) / 1e6
  return { top: ranked.map(i => i.path), rank_ms: ms, items: items.length }
})
process.stdout.write(JSON.stringify(out))
