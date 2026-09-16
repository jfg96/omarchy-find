#!/bin/bash

set -euo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$plugin_root/bin/omarchy-find-search"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/Documents" "$test_root/.secret" "$test_root/.config/tool/fresh-dir"
touch "$test_root/Documents/fresh-note.md"
touch "$test_root/Documents/fresh-image.png"
touch "$test_root/Documents/fresh-[literal].md"
touch "$test_root/.secret/fresh-hidden.md"

run_helper() {
  OMARCHY_FIND_PLOCATE=/usr/bin/false "$helper" --home "$test_root" "$@"
}

docs=$(run_helper --query fresh --kind f --extensions md --max-results 20)
[[ $docs == *"fresh-note.md"* ]]
[[ $docs != *"fresh-image.png"* ]]
[[ $docs != *"fresh-hidden.md"* ]]

literal=$(run_helper --query '[literal]' --kind f --extensions md --max-results 20)
[[ $literal == *"fresh-[literal].md"* ]]

hidden=$(run_helper --query fresh --kind f --extensions md --hidden --max-results 20)
[[ $hidden == *"fresh-note.md"* ]]
[[ $hidden == *"fresh-hidden.md"* ]]

system=$(run_helper --query fresh --kind d --hidden --system-folders --max-results 20)
[[ $system == *".config/tool/fresh-dir"* ]]
[[ $system != *"Documents"* ]]

echo "4 search helper integration tests passed"
