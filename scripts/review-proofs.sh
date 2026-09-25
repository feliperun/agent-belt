#!/usr/bin/env bash
# review-proofs.sh: runs the proof of every finding in docs/review/*.md and
# stops at the first one that does not hold. Each findings file records, per
# finding, a line
#
#   - **proof:** command: `<command>`
#
# whose command exits 0 only while that finding stays fixed. The commands are
# read from the files at run time, so a finding cannot be added without its
# proof joining this run. See docs/review/README.md for the index.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

only="${1:-}"   # optional: run one finding (review-proofs.sh R7) or one area prefix

# "### <ID>. <title>" carries the id; the command is the first backticked span
# of the proof line, so a trailing note after it is not part of the command.
list=$(awk '
  FNR == 1 { file = FILENAME; sub(/.*\//, "", file); sub(/\.md$/, "", file) }
  /^### / { id = $2; sub(/\.$/, "", id) }
  /^- \*\*proof:\*\* command: `/ {
    i = index($0, "`"); rest = substr($0, i + 1); j = index(rest, "`")
    printf "%s\t%s\t%s\n", id, file, substr(rest, 1, j - 1)
  }' $(ls docs/review/*.md | grep -v '/README\.md$'))

[ -n "$list" ] || { echo "review-proofs: no proofs found in docs/review/" >&2; exit 1; }

total=0
passed=0
while IFS=$'\t' read -r id area cmd; do
  [ -n "$id" ] || continue
  case "$id" in ${only}*) ;; *) continue ;; esac
  total=$((total + 1))
  printf '%-8s %-26s ' "$id" "$area"
  if output=$(bash -c "$cmd" 2>&1); then
    passed=$((passed + 1))
    echo "ok"
  else
    echo "FAILED"
    printf '\n%s\n  command: %s\n' "$id does not hold." "$cmd" >&2
    [ -n "$output" ] && printf '  output:\n%s\n' "$output" | tail -n 20 >&2
    printf '\nFix the code (or the proof, if the proof is wrong). Never drop the finding.\n' >&2
    exit 1
  fi
done <<< "$list"

# A filter that matches nothing must not look like success.
[ "$total" -gt 0 ] || { echo "review-proofs: no finding matches '$only'" >&2; exit 1; }

echo
echo "$passed/$total proofs hold."
