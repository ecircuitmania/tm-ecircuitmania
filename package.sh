#!/usr/bin/env bash

set -euo pipefail

# Builds the release package for the release workflow: src/, vendor/ and
# info.toml, with dev-only code left out:
# - files in DEV_ONLY_FILES are not shipped;
# - every #if DEV ... #endif block is replaced with blank lines, so line numbers
#   in players' error reports still match the repo.
# Packaging fails if shipped code still names anything declared in a dev-only
# file, because the plugin would not compile without DEV.
#
# USAGE: ./package.sh <out.op>

DEV_ONLY_FILES=( src/DevTrace.as )

if [[ $# -ne 1 || $1 == -* ]]; then
  echo "usage: $0 <out.op>" >&2
  exit 2
fi
out=$(realpath -m "$1")

cd "$(dirname "$0")"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp -RL src vendor info.toml "$stage/"
for f in "${DEV_ONLY_FILES[@]}"; do rm "$stage/$f"; done

# DEV is never defined in a release, so blank out its blocks here rather than
# ship them. #else/#elif on an #if DEV block is rejected, not guessed at.
while IFS= read -r -d '' f; do
  awk -v file="${f#"$stage"/}" '
    !depth && /^[ \t]*#if[ \t]+DEV[ \t]*$/ { depth = 1; print ""; next }
    depth && /^[ \t]*#if/                  { depth++; print ""; next }
    depth == 1 && /^[ \t]*#(else|elif)/ {
      printf "%s:%d: #else/#elif on an #if DEV block is not supported\n", file, FNR > "/dev/stderr"
      failed = 1; exit 1
    }
    depth && /^[ \t]*#endif/               { depth--; print ""; next }
    depth                                  { print ""; next }
                                           { print }
    END {
      if (!failed && depth) { printf "%s: #if DEV is never closed\n", file > "/dev/stderr"; exit 1 }
    }
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
done < <(find "$stage/src" -name '*.as' -print0)

# Top-level functions and globals declared in the dev-only files.
dev_names=$(sed -nE 's/^[A-Za-z][^(=;]*[^A-Za-z0-9_]([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[(=;].*/\1/p' "${DEV_ONLY_FILES[@]}" | sort -u | paste -sd '|' -)
if [[ -n $dev_names ]]; then
  leaks=$(cd "$stage" && find src -name '*.as' -print0 | xargs -0r grep -HnwE "$dev_names" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  if [[ -n $leaks ]]; then
    echo "Shipped code uses dev-only declarations outside #if DEV:" >&2
    echo "$leaks" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$out")"
rm -f "$out"
(cd "$stage" && zip -qr "$out" src/ vendor/ info.toml)
echo "Packaged $out ($(wc -c < "$out") bytes)"
