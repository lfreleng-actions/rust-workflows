#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Cases for tests/check-repository-metadata-pin.sh.
#
# Each case writes three lane fixtures, one call per lane unless the
# case adds one, and expects the check to pass or fail on them. A
# check that passes everything, or fails everything, fails here.
#
# Usage: bash tests/test-repository-metadata-pin.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
check="${script_dir}/check-repository-metadata-pin.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ACTION='lfreleng-actions/repository-metadata-action'
SHA='f4417bda9e73aa169709682d07d6083453275c58'
NEWER='0123456789abcdef0123456789abcdef01234567'
# The check's full diagnostics, so a truncated message fails a case.
PLAIN="is not a plain 'uses: $ACTION@<40-hex commit SHA>  # vX.Y.Z'"
COUNT="call(s) in its YAML but 1 line(s) naming it;"
COUNT+=" write each call as a plain 'uses:' line"

failed=0
pass() { echo "✅ $1"; }
miss() { echo "::error::$1"; failed=1; }

# step <ref and comment>: one workflow step calling the action.
step() {
  printf '      - name: Gather repository metadata\n'
  printf '        uses: %s@%s\n' "$ACTION" "$1"
}

# lane <file> <ref and comment>...: a workflow with one step per ref.
lane() {
  local file="$1"
  shift
  {
    printf 'jobs:\n  repository-metadata:\n    steps:\n'
    for ref in "$@"; do
      step "$ref"
    done
  } > "$work/$file"
}

# run <want: pass|fail> <label> [<error>]: check the three lane
# fixtures; a failure must report <error>.
run() {
  local rc=0 log
  log="$(bash "$check" "$work/a.yaml" "$work/b.yaml" "$work/c.yaml" 2>&1)" \
    || rc=$?
  if { [ "$1" = 'pass' ] && [ "$rc" -eq 0 ]; } \
    || { [ "$1" = 'fail' ] && [ "$rc" -eq 1 ] \
      && [[ "$log" == *"::error::"*"$3"* ]]; }; then
    pass "$2: $1"
  else
    miss "$2 gave exit $rc, expected $1: $log"
  fi
}

# same <ref and comment>: every lane calls the action once at it.
same() {
  lane a.yaml "$1"
  lane b.yaml "$1"
  lane c.yaml "$1"
}

same "$SHA  # v0.5.5"
run pass 'Every lane at the current pin'

same "$SHA  # v0.5.4"
run pass 'Every lane at the floor'

same "$NEWER  # v0.6.0"
run pass 'Every lane moved together to a newer pin'

same "$NEWER  # v1.0.0"
run pass 'Every lane moved together to a new major'

same "$SHA  # v0.5.5"
lane a.yaml "$SHA  # v0.5.5" "$SHA  # v0.5.5"
run pass 'A second call at the same pin'

same "$SHA  # v0.5.5"
lane a.yaml "$SHA  # v0.5.5" "$NEWER  # v0.6.0"
run fail 'A second call in one lane at a different pin' 'as elsewhere'

same "$SHA  # v0.5.5"
lane c.yaml "$NEWER  # v0.6.0"
run fail 'One lane at a different pin' 'as elsewhere'

same "$SHA  # v0.5.5"
lane c.yaml "$SHA  # v0.6.0"
run fail 'One lane with a different version comment' 'as elsewhere'

same "$SHA  # v0.3.3"
run fail 'Every lane below the floor' 'older than v0.5.4'

same "$SHA  # v0.5.3"
run fail 'Every lane one patch below the floor' 'older than v0.5.4'

same "$NEWER  # v0.5.10"
run pass 'A two-digit patch above the floor'

same "$SHA"
run fail 'No version comment' "$PLAIN"

same "$SHA  # 0.5.5"
run fail 'A version comment without its v' "$PLAIN"

same 'v0.5.5'
run fail 'A tag' "$PLAIN"

same 'main  # v0.5.5'
run fail 'A branch' "$PLAIN"

same 'f4417bd  # v0.5.5'
run fail 'A short SHA' "$PLAIN"

same "${SHA^^}  # v0.5.5"
run fail 'An upper-case SHA' "$PLAIN"

# extra <text>: append a raw step to lane a, after its pinned call.
extra() {
  same "$SHA  # v0.5.5"
  printf '%s\n' "$1" >> "$work/a.yaml"
}

extra "      # uses: $ACTION@main names the action in a comment"
run pass 'A whole-line comment naming the action'

extra "      - \"uses\": $ACTION@main"
run fail 'A second call under a double-quoted key' "$PLAIN"

extra "      - 'uses': $ACTION@main"
run fail 'A second call under a single-quoted key' "$PLAIN"

extra "      - {name: Metadata, uses: $ACTION@main}"
run fail 'A second call in a flow mapping' "$PLAIN"

extra "      - {\"uses\": \"$ACTION@$SHA\"}  # v0.5.5"
run fail 'A second call in a quoted flow mapping' "$PLAIN"

extra "      - uses: \"$ACTION@main\""
run fail 'A second call with a quoted value' "$PLAIN"

extra "      - uses: >-
          $ACTION@main"
run fail 'A second call with a folded value' "$PLAIN"

extra "      - uses: LFReleng-Actions/repository-metadata-action@main"
run fail 'A second call naming the action in another case' "$PLAIN"

extra "      - \"uses\": \"lfreleng\\x2dactions/repository-metadata-action@main\""
run fail 'A second call with an escaped value' "$COUNT"

extra "      - uses: \"lfreleng\\x2dactions/repository-metadata-action@$SHA\""
run fail 'A second call at the pin with an escaped value' "$COUNT"

same "$SHA  # v0.5.5"
printf 'jobs:\n  a: [\n' > "$work/b.yaml"
run fail 'A lane that is not YAML' 'does not parse'

same "$SHA  # v0.5.5"
printf 'jobs:\n  other:\n    steps:\n      - run: true\n' > "$work/b.yaml"
run fail 'One lane never calls the action' 'never calls'

same "$SHA  # v0.5.5"
rm "$work/c.yaml"
run fail 'A missing lane' 'not found'

exit "$failed"
