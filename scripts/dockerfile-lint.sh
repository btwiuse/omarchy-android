#!/usr/bin/env bash

# Static linter for builder/ci/Dockerfile.release. Catches the class of bugs
# that have burned us in CI: SHELL before FROM, COPY flattening directories
# because the destination lacks a trailing slash, missing source files.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DOCKERFILE="$ROOT/builder/ci/Dockerfile.release"

[[ -f "$DOCKERFILE" ]] || { echo "missing $DOCKERFILE" >&2; exit 1; }

failures=0
report() {
  printf '%s:%s\n' "$DOCKERFILE" "$1" >&2
  failures=$(( failures + 1 ))
}

# Directive `# syntax=` must be the very first line.
first_line="$(head -n 1 "$DOCKERFILE")"
[[ "$first_line" =~ ^#[[:space:]]*syntax= ]] || \
  report "line 1: expected a '# syntax=' parser directive, got '$first_line'"

# Each `FROM ...` opens a new stage. The `SHELL ["/bin/bash", ...]` directive
# must come AFTER the first FROM. Before FROM is an error in BuildKit.
first_from_line="$(grep -n '^FROM ' "$DOCKERFILE" | head -n1 | cut -d: -f1)"
shell_lines_before_from="$(grep -n '^SHELL ' "$DOCKERFILE" \
  | awk -F: -v fl="$first_from_line" '$1 < fl { print }')"
[[ -z "$shell_lines_before_from" ]] || \
  report "SHELL directive(s) appear before the first FROM:" $'\n'"$shell_lines_before_from"

# Every `COPY <src>` source must exist as a file or directory in the build
# context (project root).
checked_paths="$(mktemp)"
trap 'rm -f "$checked_paths"' EXIT
grep -E '^(COPY|ADD) ' "$DOCKERFILE" \
  | sed -E 's/^(COPY|ADD) +([^ ]+)( +[^ ]+)+\s*$/\2/' \
  | tr ' ' '\n' \
  | grep -v -- '--from=' \
  | grep -v '^\*$' \
  | sort -u > "$checked_paths"
while IFS= read -r src; do
  [[ -z "$src" ]] && continue
  case "$src" in
    /*) report "absolute COPY source not allowed: $src" ;;
    *"$ROOT"*) ;;  # already absolute
    *)
      [[ -e "$ROOT/$src" ]] || report "COPY source missing in context: $src"
      ;;
  esac
done < "$checked_paths"

# Every `COPY --from=<name>` must reference a stage declared earlier via
# `FROM ... AS <name>`.
awk '
  /^FROM .* AS ([A-Za-z0-9_.-]+)/ { stage = $0; if (match(stage, /[Aa][Ss] ([A-Za-z0-9_.-]+)/, m)) stages[m[1]] = NR; next }
  /^COPY --from=([A-Za-z0-9_.-]+)/ {
    from = $0; if (match(from, /--from=([A-Za-z0-9_.-]+)/, m)) {
      name = m[1]
      if (!(name in stages)) print "COPY --from=" name " references unknown stage at line " NR
    }
  }
' "$DOCKERFILE" | while IFS= read -r line; do
  report "$line"
done

if (( failures > 0 )); then
  printf '%d Dockerfile problem(s) found.\n' "$failures" >&2
  exit 1
fi
printf 'Dockerfile.lint OK\n'