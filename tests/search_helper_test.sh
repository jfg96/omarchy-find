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
touch "$test_root/Documents/fresh-foo*bar.md"
touch "$test_root/Documents/fresh-file?.md"
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

literal_star=$(run_helper --query 'foo*bar' --kind f --extensions md --max-results 20)
[[ $literal_star == *"fresh-foo*bar.md"* ]]

literal_question=$(run_helper --query 'file?.md' --kind f --extensions md --max-results 20)
[[ $literal_question == *"fresh-file?.md"* ]]

hidden=$(run_helper --query fresh --kind f --extensions md --hidden --max-results 20)
[[ $hidden == *"fresh-note.md"* ]]
[[ $hidden == *"fresh-hidden.md"* ]]

excluded=$(run_helper --query fresh --kind f --extensions md --hidden --exclude node_modules --max-results 20)
[[ $excluded == *"fresh-note.md"* ]]
[[ $excluded != *"fresh-vendor.md"* ]]

system=$(run_helper --query fresh --kind d --hidden --system-folders --max-results 20)
[[ $system == *".config/tool/fresh-dir"* ]]
[[ $system != *"Documents"* ]]

# Normal indexed passes must use plocate's substring/glob mode with literal
# user input. Only the final fuzzy fallback may opt into the linear regex mode.
fake_plocate="$test_root/fake-plocate"
plocate_log="$test_root/plocate.args"
printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\n" --- "$@" >> "$OMARCHY_FIND_PLOCATE_LOG"' > "$fake_plocate"
chmod +x "$fake_plocate"

OMARCHY_FIND_PLOCATE="$fake_plocate" \
OMARCHY_FIND_FD=/usr/bin/false \
OMARCHY_FIND_PLOCATE_LOG="$plocate_log" \
  "$helper" --home "$test_root" --query '[literal] foo*bar file?.md' --kind f --max-results 20 >/dev/null

mapfile -t special_args < "$plocate_log"
[[ ${special_args[0]} == --- ]]
[[ ${special_args[1]} == -0 && ${special_args[2]} == -i && ${special_args[3]} == --basename && ${special_args[4]} == -- ]]
[[ ${special_args[5]} == '\[literal\]' ]]
[[ ${special_args[6]} == 'foo\*bar' ]]
[[ ${special_args[7]} == 'file\?.md' ]]
[[ ${special_args[8]} == --- ]]
[[ ${special_args[9]} == -0 && ${special_args[10]} == -i && ${special_args[11]} == -- ]]
[[ ${special_args[12]} == '\[literal\]' ]]
[[ ${special_args[13]} == 'foo\*bar' ]]
[[ ${special_args[14]} == 'file\?.md' ]]
[[ $(grep -cFx -- '--regex' "$plocate_log") -eq 1 ]]

: > "$plocate_log"
OMARCHY_FIND_PLOCATE="$fake_plocate" \
OMARCHY_FIND_FD=/usr/bin/false \
OMARCHY_FIND_PLOCATE_LOG="$plocate_log" \
  "$helper" --home "$test_root" --query omfind --kind f --max-results 20 >/dev/null
[[ $(grep -cFx -- '--regex' "$plocate_log") -eq 1 ]]
grep -Fx -- 'o.*m.*f.*i.*n.*d' "$plocate_log" >/dev/null

# Candidate sources retain their relevance order: basename, full path, fresh
# fd results, and only then fuzzy plocate results.
ordered_plocate="$test_root/ordered-plocate"
ordered_fd="$test_root/ordered-fd"
ordered_basename="$test_root/Documents/order-basename.md"
ordered_path="$test_root/Documents/order-path.md"
ordered_fresh="$test_root/Documents/order-fresh.md"
ordered_fuzzy="$test_root/Documents/order-fuzzy.md"
touch "$ordered_basename" "$ordered_path" "$ordered_fresh" "$ordered_fuzzy"
printf '%s\n' \
  '#!/bin/bash' \
  'basename=false' \
  'fuzzy=false' \
  'for arg in "$@"; do' \
  '  [[ $arg != --basename ]] || basename=true' \
  '  [[ $arg != --regex ]] || fuzzy=true' \
  'done' \
  'if $fuzzy; then' \
  '  printf "%s\0" "$OMARCHY_FIND_ORDER_FUZZY"' \
  'elif $basename; then' \
  '  printf "%s\0" "$OMARCHY_FIND_ORDER_BASENAME"' \
  'else' \
  '  printf "%s\0" "$OMARCHY_FIND_ORDER_PATH"' \
  'fi' > "$ordered_plocate"
printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\0" "$OMARCHY_FIND_ORDER_FRESH"' > "$ordered_fd"
chmod +x "$ordered_plocate" "$ordered_fd"

ordered_output=$(
  OMARCHY_FIND_PLOCATE="$ordered_plocate" \
  OMARCHY_FIND_FD="$ordered_fd" \
  OMARCHY_FIND_ORDER_BASENAME="$ordered_basename" \
  OMARCHY_FIND_ORDER_PATH="$ordered_path" \
  OMARCHY_FIND_ORDER_FRESH="$ordered_fresh" \
  OMARCHY_FIND_ORDER_FUZZY="$ordered_fuzzy" \
    "$helper" --home "$test_root" --query order --kind f --max-results 10
)
mapfile -t ordered_results <<< "$ordered_output"
[[ ${ordered_results[0]} == "$ordered_basename" ]]
[[ ${ordered_results[1]} == "$ordered_path" ]]
[[ ${ordered_results[2]} == "$ordered_fresh" ]]
[[ ${ordered_results[3]} == "$ordered_fuzzy" ]]

# Reaching the result limit must consume one complete NUL-delimited record and
# terminate the producer without waiting for a large stdout chunk or EOF.
limited_plocate="$test_root/limited-plocate"
limited_pid_file="$test_root/limited-plocate.pid"
limited_output="$test_root/limited.out"
limited_target="$test_root/Documents/limit-result.md"
touch "$limited_target"
printf '%s\n' \
  '#!/bin/bash' \
  'trap "exit 0" TERM INT' \
  'printf "%s\n" "$$" > "$OMARCHY_FIND_CHILD_PID_FILE"' \
  'printf "%s\0" "$OMARCHY_FIND_LIMIT_TARGET"' \
  'while true; do sleep 0.1; done' > "$limited_plocate"
chmod +x "$limited_plocate"

OMARCHY_FIND_PLOCATE="$limited_plocate" \
OMARCHY_FIND_CHILD_PID_FILE="$limited_pid_file" \
OMARCHY_FIND_LIMIT_TARGET="$limited_target" \
  "$helper" --home "$test_root" --query limit --kind f --max-results 1 >"$limited_output" &
helper_pid=$!

for _ in {1..100}; do
  kill -0 "$helper_pid" 2>/dev/null || break
  sleep 0.02
done
if kill -0 "$helper_pid" 2>/dev/null; then
  echo "limited search did not stop its producer promptly" >&2
  exit 1
fi
wait "$helper_pid"
helper_pid=""
[[ $(<"$limited_output") == "$limited_target" ]]
[[ -s $limited_pid_file ]]
limited_pid=$(<"$limited_pid_file")
if kill -0 "$limited_pid" 2>/dev/null; then
  echo "limited search left child process $limited_pid running" >&2
  exit 1
fi

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

echo "12 search helper integration tests passed"
