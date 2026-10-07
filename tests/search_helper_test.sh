#!/bin/bash

set -euo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$plugin_root/bin/omarchy-find-search"
test_root=$(mktemp -d)
helper_pid=""
child_pids_file=""
cleanup() {
  [[ -z $helper_pid ]] || kill "$helper_pid" 2>/dev/null || true
  if [[ -n $child_pids_file && -s $child_pids_file ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$child_pids_file"
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT

passed=0
check() {
  if ! "$@"; then
    echo "FAILED (line ${BASH_LINENO[0]}): $*" >&2
    exit 1
  fi
  passed=$((passed + 1))
}
contains() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

home="$test_root/home"
mkdir -p "$home/Documents" "$home/.secret" "$home/.config/tool/fresh-dir" "$home/node_modules" \
  "$home/orderdir" "$home/Música"
touch "$home/Documents/fresh-note.md" "$home/Documents/fresh-image.png" \
  "$home/Documents/fresh-[literal].md" "$home/Documents/fresh-foo*bar.md" "$home/Documents/fresh-file?.md" \
  "$home/.secret/fresh-hidden.md" "$home/node_modules/fresh-vendor.md" \
  "$home/Documents/canción.md" "$home/Documents/espana.md" "$home/Música/tema.mp3" \
  "$home/Documents/omarchy-find.md" "$home/order-file.md" "$home/orderdir/child.md"

run_helper() {
  "$helper" --home "$home" "$@"
}

# Category filters: extensions, hidden files and excluded directories.
docs=$(run_helper --query fresh --kind f --extensions md)
check contains "$docs" "fresh-note.md"
check lacks "$docs" "fresh-image.png"
check lacks "$docs" "fresh-hidden.md"

hidden=$(run_helper --query fresh --kind f --extensions md --hidden)
check contains "$hidden" "fresh-hidden.md"

excluded=$(run_helper --query fresh --kind f --extensions md --hidden --exclude node_modules)
check contains "$excluded" "fresh-note.md"
check lacks "$excluded" "fresh-vendor.md"

system=$(run_helper --query fresh --kind d --hidden --system-folders)
check contains "$system" ".config/tool/fresh-dir"
check lacks "$system" "Documents"

# Regex metacharacters typed by the user are matched literally.
check contains "$(run_helper --query '[literal]' --kind f)" "fresh-[literal].md"
check contains "$(run_helper --query 'foo*bar' --kind f)" "fresh-foo*bar.md"
check contains "$(run_helper --query 'file?.md' --kind f)" "fresh-file?.md"
check lacks "$(run_helper --query 'file?.md' --kind f)" "fresh-foo*bar.md"

# Accent-insensitive in both directions, for names and parent folders.
check contains "$(run_helper --query cancion --kind f)" "canción.md"
check contains "$(run_helper --query españa --kind f)" "espana.md"
check contains "$(run_helper --query musica --kind d)" "Música"
check contains "$(run_helper --query 'musica tema' --kind f)" "Música/tema.mp3"

# A term that only occurs in the home path itself must not match everything.
check test -z "$(run_helper --query "$(basename "$test_root")" --kind f)"

# A term containing "/" matches against the path below $HOME.
check contains "$(run_helper --query Documents/fresh-note --kind f)" "fresh-note.md"

# Filename matches come before path matches, so a matching parent directory
# cannot fill the candidate budget with its descendants.
mapfile -t ordered < <(run_helper --query order --kind f)
check test "${ordered[0]}" == "$home/order-file.md"
check test "${ordered[1]}" == "$home/orderdir/child.md"
check test "$(run_helper --query order --kind f --max-results 1)" == "$home/order-file.md"

# Fuzzy subsequence matching is the fallback when nothing else matches.
check contains "$(run_helper --query omfind --kind f)" "omarchy-find.md"

# Reaching the result limit must consume one complete NUL-delimited record and
# terminate every fd pass without waiting for a large stdout chunk or EOF.
child_pids_file="$test_root/children.pid"
fake_fd="$test_root/fake-fd"
printf '%s\n' \
  '#!/bin/bash' \
  'trap "exit 0" TERM INT' \
  'printf "%s\n" "$$" >> "$OMARCHY_FIND_CHILD_PIDS"' \
  '[[ -z ${OMARCHY_FIND_EMIT:-} ]] || printf "%s\0" "$OMARCHY_FIND_EMIT"' \
  'while true; do sleep 0.1; done' > "$fake_fd"
chmod +x "$fake_fd"

wait_for_exit() {
  for _ in {1..100}; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.02
  done
  return 1
}
children_stopped() {
  local pid
  while read -r pid; do
    wait_for_exit "$pid" || return 1
  done < "$child_pids_file"
}

limited_output="$test_root/limited.out"
OMARCHY_FIND_FD="$fake_fd" \
OMARCHY_FIND_CHILD_PIDS="$child_pids_file" \
OMARCHY_FIND_EMIT="$home/order-file.md" \
  "$helper" --home "$home" --query limit --kind f --max-results 1 >"$limited_output" &
helper_pid=$!
check wait_for_exit "$helper_pid"
wait "$helper_pid"
helper_pid=""
check test "$(<"$limited_output")" == "$home/order-file.md"
check test "$(wc -l < "$child_pids_file")" -eq 2
check children_stopped

# A cancelled helper must terminate every fd pass it started; otherwise rapid
# category changes can leak collectors.
: > "$child_pids_file"
OMARCHY_FIND_FD="$fake_fd" \
OMARCHY_FIND_CHILD_PIDS="$child_pids_file" \
  "$helper" --home "$home" --query cancel --kind f --max-results 20 >/dev/null &
helper_pid=$!
for _ in {1..50}; do
  [[ $(wc -l < "$child_pids_file") -lt 2 ]] || break
  sleep 0.02
done
check test "$(wc -l < "$child_pids_file")" -eq 2

kill -TERM "$helper_pid"
status=0
wait "$helper_pid" || status=$?
helper_pid=""
check test "$status" -eq 143
check children_stopped

echo "$passed search helper integration tests passed"
