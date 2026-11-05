#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Contract check for the Grype input validation.
#
# Each lane's gerrit-validate job validates the grype_* inputs by
# running grype-scan-action in validate-only mode, so the rules are the
# action's own and the shell re-implementation they replace cannot
# drift. For each lane this checks that:
#
# - gerrit-validate holds one 'Validate Grype inputs' step and the
#   grype job one 'grype-audit' step, both running grype-scan-action at
#   the one PIN, each 'uses:' line carrying the '# vX.Y.Z' comment, and
#   no other reference to the action in the file;
# - the scan passes each policy input the lane exposes today as that
#   grype_* input, verbatim, so dropping a mapping such as the
#   remediation window's fails here rather than silently losing
#   adopters a setting with every run still green;
# - the validator passes validate-only as the string 'true' and, for
#   every input the scan passes as one of the lane's grype_* inputs or
#   as a fixed value, the identical expression, read from the scan
#   step's with: and not from a list here, so an input added to the
#   scan alone fails; it passes nothing else, so no sbom or target,
#   which validate-only rejects, and no input the scan takes from the
#   run rather than the caller;
# - the validator runs on every call, is the job's one action (no
#   checkout, no harden-runner), and the job waits on nothing;
# - no run: step of gerrit-validate reads a grype_* input the action
#   owns: grype_dependency_ecosystems and grype_dependency_patterns
#   belong to repository-metadata-action and stay shell checks;
# - every other job of the lane waits, directly or through its needs,
#   on gerrit-validate, so a rejected input stops the run before any
#   build job starts.
#
# testing.yaml's grype-validate-check job proves the rejection itself,
# running the verify lane's validator with a gate-when the action does
# not know, so this also checks that job passes the validator's exact
# input set as fixed values and reads the step's outcome.
#
# It first checks the real workflows, then mutates a copy of the verify
# lane in each way the check must catch and expects each mutant to
# fail, so a check that silently passes everything fails here too. It
# also expects positive controls to pass and runs text fixtures through
# the pin rules, which the parsed mutants cannot carry.
#
# Usage: bash tests/test-grype-validate-inputs.sh [<workflows-dir>]
#
# Needs python3 with PyYAML importable under -I, which excludes the
# user site: a venv or uv environment on PATH, as the prek hook and
# testing.yaml's grype-validate-wiring job supply (uv run --with).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflows="${1:-${repo_root}/.github/workflows}"

if [ ! -d "${workflows}" ]; then
  echo "ERROR: workflows directory not found: ${workflows}" >&2
  exit 1
fi

# The same -I as the run below, so the guard cannot pass on a user-site
# PyYAML the run then fails to import.
if ! python3 -I -c 'import yaml' 2>/dev/null; then
  echo "ERROR: python3 -I cannot import yaml; install PyYAML" >&2
  exit 1
fi

# '-I' keeps the working directory off sys.path.
python3 -I - "${workflows}" <<'PYEOF'
import copy
import pathlib
import re
import sys

import yaml

ACTION = "lfreleng-actions/grype-scan-action"
# v0.6.2: validate-only (v0.6.0), escaped log values (v0.6.1) and a
# retried Grype install (v0.6.2).
PIN = "f65dca2762823cfc8f376e32fee9baa6f3292696"
VERSION = "v0.6.2"
USES = f"{ACTION}@{PIN}"
# The pin with its version comment, as each 'uses:' line must hold it.
PIN_LINE = f"uses: {USES}  # {VERSION}"

LANES = ("build-test.yaml", "build-test-release.yaml", "merge.yaml")
VERIFY = LANES[0]
TESTING = "testing.yaml"
VALIDATE_JOB = "gerrit-validate"
VALIDATOR = "Validate Grype inputs"
SCAN_JOB = "grype"
SCAN_ID = "grype-audit"
CHECK_JOB = "grype-validate-check"
GATE_WHEN = ("always", "dependencies-changed")

# What validate-only needs neither of and rejects.
TARGETS = ("sbom", "target")
# The policy inputs each lane exposes today, which its scan must pass
# as the lane's own grype_* input. The verify lane alone exposes the
# gate-when, the remediation window and the database cache; the
# release and merge lanes gate every finding and restore the cache
# without saving it.
COMMON = frozenset({
    "fail-on", "dependency-policy", "transitive-fail-on", "only-fixed",
    "bypass-repository",
})
REQUIRED = {
    VERIFY: COMMON | {
        "gate-when", "remediation-window-days", "remediation-window-start",
        "cache-db",
    },
    LANES[1]: COMMON,
    LANES[2]: COMMON,
}
# A scan input passed as one of the lane's grype_* inputs, verbatim.
LANE_INPUT = re.compile(r"\$\{\{ inputs\.grype_[a-z_]+ \}\}\Z")
# Any reference to a grype_* input, in an env value or a script.
GRYPE_INPUT = re.compile(r"inputs\.(grype_[A-Za-z0-9_]+)")
# Inputs of repository-metadata-action, not of grype-scan-action, which
# the lanes still check in shell.
NOT_OWNED = frozenset(
    {"grype_dependency_ecosystems", "grype_dependency_patterns"}
)

# One grype-scan-action 'uses:' line of the raw text, with any comment.
USES_LINE = re.compile(
    r"^(?P<lead>[ \t]*(?:-[ \t]+)?)uses:[ \t]*"
    + re.escape(ACTION)
    + r"@(?P<sha>[^\s'\"#]+)(?:[ \t]+#[^\n]*)?[ \t]*$",
    re.MULTILINE,
)


def text(value):
    return "" if value is None else str(value)


def jobs_of(doc):
    return (doc.get("jobs") or {}) if isinstance(doc, dict) else {}


def steps_of(job):
    return list((job or {}).get("steps") or [])


def scalars(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from scalars(item)
    elif isinstance(value, list):
        for item in value:
            yield from scalars(item)
    elif value is not None:
        yield value


def needs_of(job):
    needs = (job or {}).get("needs")
    if isinstance(needs, str):
        return [needs]
    return list(needs or [])


def waits_on(jobs, job_id, target):
    """Whether job_id needs target, directly or through its needs."""
    seen = set()
    pending = [job_id]
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        for need in needs_of(jobs.get(current)):
            if need == target:
                return True
            pending.append(need)
    return False


def one_step(job, where, key, value):
    """Return (step, problem): the one step with key == value, or none.

    Two matches are a problem too: a check that took the first would
    pass a duplicate step carrying anything.
    """
    found = [s for s in steps_of(job) if isinstance(s, dict)
             and s.get(key) == value]
    if len(found) != 1:
        return None, f"{where} has {len(found)} steps with {key} {value!r}"
    return found[0], None


def mirrored(scan_with):
    """The scan inputs the validator mirrors.

    Each input the scan passes as one of the lane's grype_* inputs or
    as a fixed value, less sbom and target. An input the scan takes
    from the run, such as a job output or a secret, is left out: it
    carries no caller policy and the validation job has no such value.
    """
    return {
        name: value
        for name, value in (scan_with or {}).items()
        if name not in TARGETS
        and (LANE_INPUT.match(text(value)) or "${{" not in text(value))
    }


def same(a, b):
    """Literal equality: 'true' and True differ."""
    return a == b and type(a) is type(b)


def compare_with(got, want, where):
    """Return the problems in got, the validator's with:, against want."""
    problems = []
    for name in sorted(set(got) | set(want)):
        if name not in got:
            problems.append(f"{where} does not pass {name}")
        elif name not in want:
            if name in TARGETS:
                why = "which validate-only rejects"
            else:
                why = ("which the scan does not pass as a lane input or"
                       " a fixed value")
            problems.append(f"{where} passes {name}, {why}")
        elif not same(got[name], want[name]):
            problems.append(
                f"{where} passes {name} as {got[name]!r}, not {want[name]!r}"
            )
    return problems


def find_validator(doc):
    """Return (validator step, problem) for a lane."""
    job = jobs_of(doc).get(VALIDATE_JOB)
    if not isinstance(job, dict):
        return None, f"no {VALIDATE_JOB} job"
    return one_step(job, VALIDATE_JOB, "name", VALIDATOR)


def check_lane(doc, required=frozenset()):
    """Return the list of problems in one parsed lane.

    required names the inputs its scan must pass as the lane's own.
    """
    jobs = jobs_of(doc)
    validate_job = jobs.get(VALIDATE_JOB)
    scan_job = jobs.get(SCAN_JOB)
    if not isinstance(validate_job, dict):
        return [f"no {VALIDATE_JOB} job"]
    if not isinstance(scan_job, dict):
        return [f"no {SCAN_JOB} job"]
    validator, problem = one_step(validate_job, VALIDATE_JOB, "name",
                                  VALIDATOR)
    scan, scan_problem = one_step(scan_job, SCAN_JOB, "id", SCAN_ID)
    problems = [p for p in (problem, scan_problem) if p]
    if problems:
        return problems
    where = f"{VALIDATE_JOB}: '{VALIDATOR}'"
    for step, label in ((validator, where), (scan, f"{SCAN_JOB}: {SCAN_ID}")):
        if step.get("uses") != USES:
            problems.append(f"{label} uses {step.get('uses')!r}, not {USES}")
    if "if" in validator:
        problems.append(f"{where} has a condition; it must run on every call")
    lane_inputs = {
        name for name, value in (scan.get("with") or {}).items()
        if LANE_INPUT.match(text(value))
    }
    for name in sorted(required - lane_inputs):
        problems.append(
            f"{SCAN_JOB}: {SCAN_ID} does not pass {name} as the lane's own"
            " grype_* input"
        )
    want = {"validate-only": "true", **mirrored(scan.get("with"))}
    problems.extend(compare_with(validator.get("with") or {}, want, where))
    uses = [s.get("uses") for s in steps_of(validate_job)
            if isinstance(s, dict) and s.get("uses")]
    if uses != [USES]:
        problems.append(
            f"{VALIDATE_JOB} runs actions {uses!r}; the validator must be"
            " its one action: no checkout, no harden-runner"
        )
    if needs_of(validate_job):
        problems.append(f"{VALIDATE_JOB} needs {needs_of(validate_job)!r}")
    for step in steps_of(validate_job):
        if not isinstance(step, dict) or "run" not in step:
            continue
        read = set()
        for value in [*scalars(step.get("env")), step.get("run")]:
            read.update(GRYPE_INPUT.findall(text(value)))
        owned = sorted(read - NOT_OWNED)
        if owned:
            problems.append(
                f"{VALIDATE_JOB}: '{text(step.get('name'))}' checks"
                f" {', '.join(owned)} in shell; the action owns them"
            )
    for job_id in jobs:
        if job_id != VALIDATE_JOB and not waits_on(jobs, job_id, VALIDATE_JOB):
            problems.append(f"job {job_id} does not wait on {VALIDATE_JOB}")
    return problems


def check_text(content, steps):
    """Return the problems in the raw text's grype-scan-action lines.

    Each of the steps running the action holds PIN_LINE, and no other
    reference to the action appears; a value of None accepts any
    positive count, as long as every reference is the pinned line.
    """
    lines = USES_LINE.findall(content)
    pinned = content.count(PIN_LINE)
    refs = content.count(f"{ACTION}@")
    problems = []
    if steps is not None and len(lines) != steps:
        problems.append(f"{len(lines)} 'uses: {ACTION}@' lines, not {steps}")
    elif steps is None and not lines:
        problems.append(f"no 'uses: {ACTION}@' line")
    if pinned != refs:
        problems.append(
            f"{refs} references to {ACTION} but {pinned} read"
            f" '{PIN_LINE}'; one pin with its comment governs them all"
        )
    return problems


def check_check_job(testing, verify):
    """Return the problems in testing.yaml's rejection check.

    The job runs the verify lane's validator with fixed values and a
    gate-when the action does not know, under continue-on-error, and
    a later step reads the outcome.
    """
    validator, problem = find_validator(verify)
    if problem:
        return [f"{VERIFY}: {problem}"]
    job = jobs_of(testing).get(CHECK_JOB)
    if not isinstance(job, dict):
        return [f"no {CHECK_JOB} job"]
    actions = [s for s in steps_of(job) if isinstance(s, dict) and s.get("uses")]
    if len(actions) != 1 or actions[0].get("uses") != USES:
        return [f"{CHECK_JOB} must run {USES} as its one action"]
    step = actions[0]
    where = f"{CHECK_JOB}: '{text(step.get('name'))}'"
    problems = []
    if step.get("continue-on-error") is not True:
        problems.append(f"{where} must set continue-on-error: true")
    given = step.get("with") or {}
    want = set(validator.get("with") or {})
    if set(given) != want:
        problems.append(
            f"{where} passes {sorted(given)}, not the verify lane's"
            f" validator inputs {sorted(want)}"
        )
    if not same(given.get("validate-only"), "true"):
        problems.append(f"{where} must pass validate-only 'true'")
    if "gate-when" not in given or given["gate-when"] in GATE_WHEN:
        problems.append(
            f"{where} must pass a gate-when the action does not know"
        )
    for name, value in given.items():
        if "${{" in text(value):
            problems.append(f"{where} passes {name} as an expression")
    step_id = text(step.get("id"))
    outcome = f"steps.{step_id}.outcome"
    if not step_id or not any(
        isinstance(s, dict) and "run" in s
        and any(outcome in text(v) for v in scalars(s.get("env")))
        for s in steps_of(job)
    ):
        problems.append(f"{CHECK_JOB} has no step reading {outcome}")
    return problems


def mutants(doc):
    """Yield (label, mutated lane) for each drift check_lane must catch."""

    def parts(d):
        validate_job = jobs_of(d)[VALIDATE_JOB]
        validator = one_step(validate_job, "", "name", VALIDATOR)[0]
        scan = one_step(jobs_of(d)[SCAN_JOB], "", "id", SCAN_ID)[0]
        return validate_job, validator, scan

    def variant(label, change):
        d = copy.deepcopy(doc)
        change(*parts(d))
        return label, d

    other = "${{ inputs.grype_dependency_policy }}"
    yield variant("validator expression drifts",
                  lambda j, v, s: v["with"].update({"gate-when": other}))
    yield variant("validate-only removed",
                  lambda j, v, s: v["with"].pop("validate-only"))
    yield variant("validate-only as a YAML boolean",
                  lambda j, v, s: v["with"].update({"validate-only": True}))
    yield variant("validate-only 'false'",
                  lambda j, v, s: v["with"].update({"validate-only": "false"}))
    yield variant("validator at another pin",
                  lambda j, v, s: v.update({"uses": f"{ACTION}@{'0' * 40}"}))
    yield variant("scan at another pin",
                  lambda j, v, s: s.update({"uses": f"{ACTION}@{'0' * 40}"}))
    yield variant("validator at a tag",
                  lambda j, v, s: v.update({"uses": f"{ACTION}@{VERSION}"}))
    added = "${{ inputs.grype_declared_source }}"
    yield variant("scan input the validator lacks",
                  lambda j, v, s: s["with"].update({"declared-source": added}))
    yield variant("scan fixed value the validator lacks",
                  lambda j, v, s: s["with"].update({"sort-by": "severity"}))
    yield variant("validator input the scan lacks",
                  lambda j, v, s: v["with"].update({"declared-source": added}))
    yield variant("scan drops an input the validator keeps",
                  lambda j, v, s: s["with"].pop("fail-on"))
    for target in TARGETS:
        yield variant(f"{target} on the validator",
                      lambda j, v, s, t=target: v["with"].update({t: "x"}))
    yield variant("validator under a condition",
                  lambda j, v, s: v.update({"if": "inputs.grype_enabled"}))
    yield variant("validation job waits on another job",
                  lambda j, v, s: j.update({"needs": "repository-metadata"}))
    for name, action in (("checkout", "actions/checkout"),
                         ("harden-runner", "step-security/harden-runner")):
        yield variant(
            f"{name} in the validation job",
            lambda j, v, s, a=action: j["steps"].insert(
                0, {"name": name, "uses": f"{a}@{'0' * 40}"}
            ),
        )
    yield variant("a second validator step",
                  lambda j, v, s: j["steps"].append(copy.deepcopy(v)))
    yield variant(
        "shell check of fail-on through env",
        lambda j, v, s: j["steps"].append({
            "name": "Check", "shell": "bash",
            "env": {"FAIL_ON": "${{ inputs.grype_fail_on }}"},
            "run": "test -n \"$FAIL_ON\"",
        }),
    )
    yield variant(
        "shell check of gate-when inline",
        lambda j, v, s: j["steps"].append({
            "name": "Check", "shell": "bash",
            "run": "echo '${{ inputs.grype_gate_when }}'",
        }),
    )

    def drop_window(j, v, s):
        del s["with"]["remediation-window-start"]
        del v["with"]["remediation-window-start"]

    yield variant("both drop the window start", drop_window)

    def fixed_fail_on(j, v, s):
        s["with"]["fail-on"] = "medium"
        v["with"]["fail-on"] = "medium"

    yield variant("both fix fail-on, which the lane exposes", fixed_fail_on)

    d = copy.deepcopy(doc)
    del jobs_of(d)["rust-metadata"]["needs"]
    yield "rust-metadata no longer waits on gerrit-validate", d


def controls(doc):
    """Yield (label, varied lane) for each form check_lane must accept."""

    def parts(d):
        validate_job = jobs_of(d)[VALIDATE_JOB]
        validator = one_step(validate_job, "", "name", VALIDATOR)[0]
        scan = one_step(jobs_of(d)[SCAN_JOB], "", "id", SCAN_ID)[0]
        return validate_job, validator, scan

    def variant(label, change):
        d = copy.deepcopy(doc)
        change(*parts(d))
        return label, d

    def mirror_fixed(j, v, s):
        s["with"]["sort-by"] = "severity"
        v["with"]["sort-by"] = "severity"

    yield variant("a fixed value mirrored on both", mirror_fixed)
    yield variant(
        "scan takes an input from the run",
        lambda j, v, s: s["with"].update({
            "dependency-change-manifest": "${{ needs.sbom.outputs.path }}",
        }),
    )
    yield variant(
        "shell check of an input the action does not own",
        lambda j, v, s: j["steps"].append({
            "name": "Check", "shell": "bash",
            "env": {"PATTERNS": "${{ inputs.grype_dependency_patterns }}"},
            "run": "test -z \"$PATTERNS\" || true",
        }),
    )


def check_mutants(testing, verify):
    """Yield (label, mutated testing.yaml) check_check_job must catch."""

    def variant(label, change):
        d = copy.deepcopy(testing)
        job = jobs_of(d)[CHECK_JOB]
        step = next(s for s in steps_of(job) if s.get("uses"))
        change(job, step)
        return label, d

    yield variant("gate-when the action knows",
                  lambda j, s: s["with"].update({"gate-when": GATE_WHEN[0]}))
    yield variant("validate-only removed",
                  lambda j, s: s["with"].pop("validate-only"))
    yield variant("continue-on-error removed",
                  lambda j, s: s.pop("continue-on-error"))
    yield variant("sbom passed",
                  lambda j, s: s["with"].update({"sbom": "x.json"}))
    yield variant("an input of the validator missing",
                  lambda j, s: s["with"].pop("cache-db"))
    yield variant("an expression in place of a fixed value",
                  lambda j, s: s["with"].update({"fail-on": "${{ x }}"}))
    yield variant("another pin",
                  lambda j, s: s.update({"uses": f"{ACTION}@{'0' * 40}"}))
    yield variant("outcome unread",
                  lambda j, s: s.update({"id": "renamed"}))


def repin(content, pins):
    """Rewrite each grype-scan-action 'uses:' line of content, in order.

    pins holds one (sha, comment) per line; comment None drops it.
    """
    pins = iter(pins)

    def line(match):
        sha, comment = next(pins)
        tail = "" if comment is None else f"  # {comment}"
        return f"{match['lead']}uses: {ACTION}@{sha}{tail}"

    return USES_LINE.sub(line, content)


# (label, passes, the pin of each of the lane's two lines, extra text)
PIN_FIXTURES = (
    ("both lines pinned with the comment", True,
     ((PIN, VERSION), (PIN, VERSION)), ""),
    ("the validator with no comment", False,
     ((PIN, None), (PIN, VERSION)), ""),
    ("the scan commented as another version", False,
     ((PIN, VERSION), (PIN, "v0.6.1")), ""),
    ("the scan at another SHA", False,
     ((PIN, VERSION), ("f" * 40, VERSION)), ""),
    ("a third reference at another pin", False,
     ((PIN, VERSION), (PIN, VERSION)),
     f"\n      - uses: {ACTION}@{'0' * 40}  # {VERSION}\n"),
)


def main(path):
    docs = {}
    for name in (*LANES, TESTING):
        file = path / name
        if not file.is_file():
            print(f"::error::{file} not found")
            return 1
        content = file.read_text(encoding="utf-8")
        docs[name] = (content, yaml.safe_load(content))
    failed = 0
    for lane in LANES:
        content, doc = docs[lane]
        problems = check_lane(doc, REQUIRED[lane]) + check_text(content, 2)
        for problem in problems:
            print(f"::error file=.github/workflows/{lane}::{problem}")
        if problems:
            failed = 1
        else:
            print(f"✅ {lane}: the validator mirrors the scan at {VERSION}")
    content, testing = docs[TESTING]
    problems = check_check_job(testing, docs[VERIFY][1])
    problems += check_text(content, None)
    for problem in problems:
        print(f"::error file=.github/workflows/{TESTING}::{problem}")
    if problems:
        failed = 1
    else:
        print(f"✅ {TESTING}: {CHECK_JOB} runs the validator on a bad value")
    if failed:
        return failed

    wrong = 0

    def run(kind, cases, check, expect_pass):
        nonlocal wrong
        total = right = 0
        for label, variant in cases:
            total += 1
            # Through a dump and a load, as a written file would be.
            passed = not check(yaml.safe_load(yaml.safe_dump(variant)))
            if passed == expect_pass:
                right += 1
            else:
                print(f"::error::{kind} {label}: wrong result")
        wrong += total - right
        verb = "accepted" if expect_pass else "caught"
        print(f"{kind}s {verb}: {right}/{total}")

    verify_text, verify = docs[VERIFY]

    def check_verify(d):
        return check_lane(d, REQUIRED[VERIFY])

    run("Mutant", mutants(verify), check_verify, False)
    run("Positive control", controls(verify), check_verify, True)
    run("Check-job mutant", check_mutants(testing, verify),
        lambda d: check_check_job(d, verify), False)
    right = 0
    for label, expect_pass, pins, extra in PIN_FIXTURES:
        fixture = repin(verify_text, pins) + extra
        passed = not check_text(fixture, 2)
        if passed == expect_pass:
            right += 1
        else:
            print(f"::error::Pin fixture {label}: wrong result")
    wrong += len(PIN_FIXTURES) - right
    print(f"Pin fixtures as expected: {right}/{len(PIN_FIXTURES)}")
    return 1 if wrong else 0


sys.exit(main(pathlib.Path(sys.argv[1])))
PYEOF
