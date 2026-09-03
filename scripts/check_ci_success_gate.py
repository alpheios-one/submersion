#!/usr/bin/env python3
"""Verify every CI job reaches the `ci-success` aggregation gate.

`CI Success` is the only check marked required in branch protection, and it
decides pass/fail by looping over `join(needs.*.result)`. That expression can
only ever see jobs named in its `needs:` list, so a job left out of that list
is advisory: it shows red on the pull request while the merge box stays green.

This is not hypothetical. `script-tests` was added in bc40ab67c40 (2026-06-24)
without being added to the gate, so for over two months the JNI local-reference
guard (#318), the dive-download process isolation check, the pre-push hook test
and the release-notes tests could all fail without blocking a merge.

GitHub Actions offers no wildcard for "every job in this workflow", so the list
has to be maintained by hand. This guard is what makes that maintenance
enforced rather than remembered. Pure stdlib: the CI job that runs it has no
YAML parser installed, and the small subset of YAML that job declarations use
is parsed directly here.

Usage: check_ci_success_gate.py [workflow.yaml ...]
"""

import re
import sys

DEFAULT_WORKFLOW = ".github/workflows/ci.yaml"

# The job that aggregates the others; the one to mark required in protection.
GATE_JOB = "ci-success"

# Jobs deliberately outside the gate. Keep this as short as possible: every
# entry is a job whose failure cannot block a merge.
#
#   pr-number  Writes the PR number to an artifact for the coverage upload to
#              pick up. It builds nothing and verifies nothing, so its failure
#              costs a coverage annotation, not correctness.
EXEMPT_JOBS = frozenset({"pr-number"})

_JOBS_KEY = re.compile(r"^jobs:\s*$")
_JOB_ID = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
_NEEDS_BLOCK = re.compile(r"^    needs:\s*$")
_NEEDS_INLINE = re.compile(r"^    needs:\s*\[(.*)\]\s*$")
_NEEDS_ITEM = re.compile(r"^      - ([A-Za-z0-9_-]+)\s*(?:#.*)?$")


def _job_lines(text):
    """Yield (job_id, [lines]) for each top-level job, in file order.

    Only lines after the `jobs:` key are considered. Top-level workflow keys
    such as `on:` nest their own two-space children (`push:`, `branches:`),
    which are indistinguishable from job ids by indentation alone.
    """
    lines = text.splitlines()
    try:
        start = next(i for i, ln in enumerate(lines) if _JOBS_KEY.match(ln)) + 1
    except StopIteration:
        return
    current, body = None, []
    for line in lines[start:]:
        match = _JOB_ID.match(line)
        if match:
            if current is not None:
                yield current, body
            current, body = match.group(1), []
        elif current is not None:
            body.append(line)
    if current is not None:
        yield current, body


def job_ids(text):
    """Return every top-level job id declared in the workflow, in file order."""
    return [job_id for job_id, _ in _job_lines(text)]


def gate_needs(text):
    """Return the gate job's `needs` entries, or None if it declares none.

    Handles both the block sequence and the inline flow sequence spellings.
    """
    for job_id, body in _job_lines(text):
        if job_id != GATE_JOB:
            continue
        for index, line in enumerate(body):
            inline = _NEEDS_INLINE.match(line)
            if inline:
                return [n.strip() for n in inline.group(1).split(",") if n.strip()]
            if _NEEDS_BLOCK.match(line):
                needs = []
                for item in body[index + 1:]:
                    entry = _NEEDS_ITEM.match(item)
                    if not entry:
                        break
                    needs.append(entry.group(1))
                return needs
        return None
    return None


def find_violations(text):
    """Return a list of violation strings; empty == every job is gated."""
    jobs = job_ids(text)
    if GATE_JOB not in jobs:
        return [f"no {GATE_JOB} job found -- nothing aggregates the pipeline"]

    needs = gate_needs(text)
    if needs is None:
        return [
            f"{GATE_JOB} declares no needs -- it can never observe another "
            "job's result, so it reports green unconditionally"
        ]

    violations = []
    for job_id in jobs:
        if job_id == GATE_JOB or job_id in EXEMPT_JOBS or job_id in needs:
            continue
        violations.append(
            f"job '{job_id}' is not in {GATE_JOB}.needs -- it can fail while "
            "the required check stays green (add it, or exempt it in "
            "EXEMPT_JOBS with a reason)"
        )
    for need in needs:
        if need not in jobs:
            violations.append(
                f"{GATE_JOB}.needs lists '{need}', which is not a job in this "
                "workflow -- Actions rejects the workflow as invalid"
            )
    return violations


def check_file(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        violations = find_violations(fh.read())
    lines = [f"  FAIL  {v}" for v in violations]
    if not violations:
        lines.append(f"  ok    every job reaches the {GATE_JOB} gate")
    return not violations, lines


def main(argv):
    paths = argv[1:] or [DEFAULT_WORKFLOW]
    all_ok = True
    for path in paths:
        print(f"Checking CI aggregation gate: {path}")
        try:
            ok, lines = check_file(path)
        except OSError as exc:
            print(f"  ERROR reading {path}: {exc}")
            all_ok = False
            continue
        for line in lines:
            print(line)
        print("  -> PASS" if ok else "  -> FAIL: a job can fail without blocking a merge")
        all_ok = all_ok and ok
    return 0 if all_ok else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv))
