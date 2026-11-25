#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Check a shared action pin across workflows.
#
# Every file given must call the action at least once, and every call
# must use the same full 40-hex commit SHA with a '# vX.Y.Z' comment
# naming a release no older than FLOOR. A Dependabot bump that moves
# every call together passes.
#
# A call is checked twice. Every line with an action ref outside a
# whole-line comment must be a plain
# 'uses: <action>@<sha>  # vX.Y.Z', so a call in any other form (a
# quoted key, a flow mapping, a quoted or folded value) fails. The parser
# lists every 'uses' value that names the action, whatever its YAML
# form or escapes, and matches each to its checked source line.
#
# Usage: bash tests/check-repository-metadata-pin.sh \
#          [--pyyaml] [--action <owner/repo> --floor <vX.Y.Z>] <workflow>...
#
# Uses yq (mikefarah, v4) by default. With --pyyaml, it uses the
# PyYAML already installed for the Grype contract hook.

set -euo pipefail

ACTION='lfreleng-actions/repository-metadata-action'
# v0.5.4: the oldest release that takes every dependency-change input
# the lanes pass (detection itself first shipped in v0.4.0).
FLOOR='v0.5.4'

usage() {
  echo "Usage: $0 [--pyyaml] [--action <owner/repo> --floor <vX.Y.Z>] <workflow>..." >&2
  exit 2
}

use_pyyaml=false
if [[ "${1:-}" == --pyyaml ]]; then
  use_pyyaml=true
  shift
fi
if [[ "${1:-}" == --action ]]; then
  if [[ "$#" -lt 5 || "$3" != --floor ||
        ! "$2" =~ ^[a-z0-9_-]+/[a-z0-9_.-]+$ ||
        ! "$4" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    usage
  fi
  ACTION="$2"
  FLOOR="$4"
  shift 4
fi
if [ "$#" -eq 0 ]; then
  usage
fi
if [[ "$use_pyyaml" == true ]]; then
  if ! python3 -I -c 'import yaml' 2>/dev/null; then
    echo "::error::$0 requires python3 with PyYAML importable under -I" >&2
    exit 2
  fi
elif ! command -v yq >/dev/null; then
  echo "::error::$0 requires yq (mikefarah, v4)" >&2
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

action_re="${ACTION//./\\.}"
line_re="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+${action_re}@"
line_re+="([0-9a-f]{40})[[:space:]]+#[[:space:]]+(v[0-9]+\.[0-9]+\.[0-9]+)"
line_re+="[[:space:]]*$"
# Every 'uses' value naming the action, read as YAML.
uses_expr='[.. | select(tag == "!!map" and has("uses")) | .uses'
uses_expr+=' | select(tag == "!!str")'
uses_expr+=' | select(downcase | test("^'"${action_re//\\/\\\\}"'([/@]|$)"))]'
uses_expr+=' | .[] | [line, .] | @tsv'

read_uses() {
  if [[ "$use_pyyaml" == false ]]; then
    yq "$uses_expr" "$1"
    return
  fi
  python3 -I - "$ACTION" "$1" <<'PYEOF'
import re
import sys

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

action, path = sys.argv[1:]
ref = re.compile(re.escape(action) + r"([/@]|$)", re.IGNORECASE | re.ASCII)
escapes = str.maketrans({"\\": r"\\", "\n": r"\n", "\r": r"\r", "\t": r"\t"})


def uses(node, ancestors=frozenset()):
    if node in ancestors:
        raise ValueError(f"recursive alias at {node.start_mark}")
    if isinstance(node, MappingNode):
        for key, value in node.value:
            if (isinstance(key, ScalarNode) and key.value == "uses"
                    and isinstance(value, ScalarNode)
                    and value.tag == "tag:yaml.org,2002:str"
                    and ref.match(value.value)):
                yield value
            yield from uses(value, ancestors | {node})
    elif isinstance(node, SequenceNode):
        for child in node.value:
            yield from uses(child, ancestors | {node})


try:
    with open(path, encoding="utf-8") as workflow:
        for node in uses(yaml.compose(workflow, Loader=yaml.SafeLoader)):
            print(f"{node.start_mark.line + 1}\t{node.value.translate(escapes)}")
except (yaml.YAMLError, ValueError) as error:
    sys.exit(str(error))
PYEOF
}

first=''
sites=()
declare -A refs
for file in "$@"; do
  if [ ! -f "$file" ]; then
    miss "$file not found"
    continue
  fi
  calls=0
  refs=()
  while IFS=: read -r lineno line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    calls=$((calls + 1))
    site="$file:$lineno"
    shown="${line#"${line%%[![:space:]]*}"}"
    sites+=("$site: $shown")
    refs["$lineno"]=''
    if [[ ! "$line" =~ $line_re ]]; then
      miss "$site: '$shown' is not a plain" \
        "'uses: $ACTION@<40-hex commit SHA>  # vX.Y.Z'"
      continue
    fi
    refs["$lineno"]="$ACTION@${BASH_REMATCH[2]}"
    pin="${BASH_REMATCH[2]}  # ${BASH_REMATCH[3]}"
    if [ "$(vnum "${BASH_REMATCH[3]}")" \< "$(vnum "$FLOOR")" ]; then
      miss "$site pins $ACTION at ${BASH_REMATCH[3]}, older than $FLOOR"
    fi
    if [ -z "$first" ]; then
      first="$pin"
    elif [ "$pin" != "$first" ]; then
      miss "$site pins $ACTION at '$pin', not '$first' as elsewhere"
    fi
  done < <(grep -inF "$ACTION@" "$file" || true)
  if ! values="$(read_uses "$file" 2>&1)"; then
    miss "$file does not parse as YAML: $values"
    continue
  fi
  parsed=0
  while IFS=$'\t' read -r lineno value; do
    [ -n "$lineno" ] || continue
    parsed=$((parsed + 1))
    if [[ ! -v refs[$lineno] ]]; then
      sites+=("$file:$lineno: uses: $value")
    fi
    if [ "$value" != "${refs[$lineno]-}" ]; then
      miss "$file:$lineno calls $ACTION as '$value', not as a checked 'uses:' line"
    fi
    # One parsed call per source line, even when YAML aliases reuse a node.
    unset 'refs[$lineno]'
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
elif [ "${#sites[@]}" -ne 0 ]; then
  printf 'Call sites for %s:\n' "$ACTION"
  printf '  %s\n' "${sites[@]}"
fi
exit "$failed"
