// Loads FindBackend.js the way the unit tests do, so benchmarks use the exact
// argv construction and ranking that Find.qml runs.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "FindBackend.js"), "utf8")
  .replace(/^\.pragma library\s*/, "")
const backend = { console }
vm.createContext(backend)
vm.runInContext(source, backend)
module.exports = backend

if (require.main === module) {
  // argv <home> <helper> <query> <filterIndex> -> JSON {dirs, files}
  const [home, helper, query, filterIndex] = process.argv.slice(2)
  const filter = backend.FILTERS[Number(filterIndex)]
  const out = {}
  if (filter.dirs) out.dirs = backend.buildArgv(query, Number(filterIndex), true, home, helper)
  if (filter.files) out.files = backend.buildArgv(query, Number(filterIndex), false, home, helper)
  process.stdout.write(JSON.stringify(out))
}
