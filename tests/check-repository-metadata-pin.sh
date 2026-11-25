#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Check the repository-metadata-action pin across the lanes.
#
# Every file given must call repository-metadata-action at least once,
# and every call, across all the files, must hold one and the same
# pin: a full 40-hex commit SHA with a '# vX.Y.Z' comment on its line,
# naming a release no older than FLOOR. The pin itself is not named
# here, so a Dependabot bump that moves every call together passes.
#
# A call is checked twice. Every line that names the action, in any
# case and outside a whole-line comment, must be a plain
# 'uses: <action>@<sha>  # vX.Y.Z', so a call in any other form (a
# quoted key, a flow mapping, a quoted or folded value) fails. Then yq
# lists every 'uses' value that names the action, whatever its YAML
# form or escapes, and each must hold the shared SHA, one per line
# checked, so no call escapes the line check.
#
# Usage: bash tests/check-repository-metadata-pin.sh <workflow>...
#
# Requires yq (mikefarah, v4).

set -euo pipefail

ACTION='lfreleng-actions/repository-metadata-action'
# v0.5.4: the oldest release that takes every dependency-change input
# the lanes pass (detection itself first shipped in v0.4.0).
FLOOR='v0.5.4'

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <workflow>..." >&2
  exit 2
fi

failed=0
pass() { echo "✅ $1"; }
miss() { echo "::error::$*"; failed=1; }

# Print a vX.Y.Z version as a zero-padded number for comparison.
vnum() {
  local major minor patch
  IFS=. read -r major minor patch <<< "${1#v}"
  printf '%06d%06d%06d' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
}

line_re="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+${ACTION}@"
line_re+="([0-9a-f]{40})[[:space:]]+#[[:space:]]+(v[0-9]+\.[0-9]+\.[0-9]+)"
line_re+="[[:space:]]*$"
# Every 'uses' value naming the action, read as YAML.
uses_expr='[.. | select(tag == "!!map" and has("uses")) | .uses'
uses_expr+=' | select(tag == "!!str")'
uses_expr+=' | select(downcase | test("^'"${ACTION}"'([/@]|$)"))] | .[]'
first=''
for file in "$@"; do
  if [ ! -f "$file" ]; then
    miss "$file not found"
    continue
  fi
  calls=0
  while IFS= read -r line; do
    calls=$((calls + 1))
    if [[ ! "$line" =~ $line_re ]]; then
      miss "$file: '${line#"${line%%[![:space:]]*}"}' is not a plain" \
        "'uses: $ACTION@<40-hex commit SHA>  # vX.Y.Z'"
      continue
    fi
    pin="${BASH_REMATCH[2]}  # ${BASH_REMATCH[3]}"
    if [ -z "$first" ]; then
      first="$pin"
      if [ "$(vnum "${BASH_REMATCH[3]}")" \< "$(vnum "$FLOOR")" ]; then
        miss "$file pins $ACTION at ${BASH_REMATCH[3]}, older than $FLOOR"
      fi
    elif [ "$pin" != "$first" ]; then
      miss "$file pins $ACTION at '$pin', not '$first' as elsewhere"
    fi
  done < <(grep -i -F "$ACTION" "$file" | grep -v -E '^[[:space:]]*#' || true)
  if ! values="$(yq "$uses_expr" "$file" 2>&1)"; then
    miss "$file does not parse as YAML: $values"
    continue
  fi
  parsed=0
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    parsed=$((parsed + 1))
    if [ -z "$first" ] || [ "$value" != "$ACTION@${first%% *}" ]; then
      miss "$file calls $ACTION as '$value', not at the SHA checked above"
    fi
  done <<< "$values"
  if [ "$parsed" -ne "$calls" ]; then
    miss "$file has $parsed $ACTION call(s) in its YAML but $calls" \
      "line(s) naming it; write each call as a plain 'uses:' line"
  elif [ "$calls" -ge 1 ]; then
    pass "$file calls $ACTION $calls time(s)"
  else
    miss "$file never calls $ACTION"
  fi
done

if [ "$failed" -eq 0 ]; then
  pass "Every call pins $ACTION at '$first', no older than $FLOOR"
fi
exit "$failed"
