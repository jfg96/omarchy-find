#!/bin/bash

set -euo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$plugin_root/bin/omarchy-find-search"
test_root=$(mktemp -d)
helper_pid=""
fake_child_pid=""
cleanup() {
  [[ -z $helper_pid ]] || kill "$helper_pid" 2>/dev/null || true
  [[ -z $fake_child_pid ]] || kill "$fake_child_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/Documents" "$test_root/.secret" "$test_root/.config/tool/fresh-dir" "$test_root/node_modules"
touch "$test_root/Documents/fresh-note.md"
touch "$test_root/Documents/fresh-image.png"
touch "$test_root/Documents/fresh-[literal].md"
touch "$test_root/.secret/fresh-hidden.md"
touch "$test_root/node_modules/fresh-vendor.md"

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

excluded=$(run_helper --query fresh --kind f --extensions md --hidden --exclude node_modules --max-results 20)
[[ $excluded == *"fresh-note.md"* ]]
[[ $excluded != *"fresh-vendor.md"* ]]

system=$(run_helper --query fresh --kind d --hidden --system-folders --max-results 20)
[[ $system == *".config/tool/fresh-dir"* ]]
[[ $system != *"Documents"* ]]

# A cancelled helper must also terminate the fd/plocate child it is currently
# reading from; otherwise rapid category changes can leak collectors.
fake_fd="$test_root/fake-fd"
child_pid_file="$test_root/fake-fd.pid"
printf '%s\n' \
  '#!/bin/bash' \
  'trap "exit 0" TERM INT' \
  'printf "%s\\n" "$$" > "$OMARCHY_FIND_CHILD_PID_FILE"' \
  'while true; do sleep 0.1; done' > "$fake_fd"
chmod +x "$fake_fd"

OMARCHY_FIND_PLOCATE=/usr/bin/false \
OMARCHY_FIND_FD="$fake_fd" \
OMARCHY_FIND_CHILD_PID_FILE="$child_pid_file" \
  "$helper" --home "$test_root" --query cancel --kind f --max-results 20 >/dev/null &
helper_pid=$!

for _ in {1..50}; do
  [[ ! -s $child_pid_file ]] || break
  sleep 0.02
done
[[ -s $child_pid_file ]]
fake_child_pid=$(<"$child_pid_file")

kill -TERM "$helper_pid"
status=0
wait "$helper_pid" || status=$?
helper_pid=""
[[ $status -eq 143 ]]

for _ in {1..50}; do
  kill -0 "$fake_child_pid" 2>/dev/null || break
  sleep 0.02
done
if kill -0 "$fake_child_pid" 2>/dev/null; then
  echo "cancelled helper left child process $fake_child_pid running" >&2
  exit 1
fi
fake_child_pid=""

echo "6 search helper integration tests passed"
