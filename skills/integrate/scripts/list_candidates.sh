#!/usr/bin/env bash
#
# list_candidates.sh — which open pull requests are ready to be integrated, and
# why each of the others is not.
#
# WHY THIS IS A SCRIPT. The readiness rules are a fixed list — changes
# requested, a blocking label, red CI on the head commit, a stacked parent that
# is not itself coming along — and each one is a field in `gh`'s JSON. A model
# reading raw PR JSON re-derives them differently each run and skips a PR
# without saying so. This prints one labeled line per field and one verdict per
# PR, so /gantry:integrate shows a reason for every skip and a human can argue
# with it at the checkpoint.
#
# Read-only: `gh pr list` (a read), or a JSON file. Touches no git state.
#
# Run with:
#   bash list_candidates.sh --base <name> [--json <file>] [<pr#> ...]
#
#   --base <name>   the base branch PRs must target (the repo's base branch,
#                   from skills/ship/scripts/detect_state.sh, or an override).
#   --json <file>   read the PR array from a file instead of calling `gh` — the
#                   shape `gh pr list --json ...` prints. This is how
#                   tests/cases/integrate_candidates.sh runs the classifier with
#                   no network and no gh.
#   <pr#> ...       an explicit list, which overrides discovery. A number that
#                   is not an open PR is reported, never silently dropped.
#
# stdout — a block per PR, then a trailer:
#   PR:<n> / TITLE: / URL: / DRAFT:yes|no / BASE_REF: / HEAD_REF: / HEAD_SHA:
#   CREATED:<iso> <epoch> / MERGEABLE: / REVIEW: / LABELS:<a,b>|none
#   CI:passing|failing|pending|none / STACKED_ON:<n>|none
#   CONTRACT:gantry|none / VERDICT:candidate|skip <reason> / END
#   INTEGRATION_PR:<n> <head-ref> <base-ref> <url>
#   CANDIDATES:<n ...>|none
#   SKIPPED:<n ...>|none
#
# SKIP REASONS, first match wins: not-open · integration-pr · changes-requested ·
# label:<name> · ci-failing · stacked-parent-not-selected:<n> · base:<ref>.
#
# TARGETING THE BASE IS NEVER STACKING. `headRefName` carries no owner prefix, so
# a fork's own `master` arrives as the head branch named `master` — see
# parent_of() for why that would otherwise skip an entire run.
#
# A DRAFT IS A CANDIDATE. gantry:auto-unattended opens every PR as a draft, and
# those are exactly the PRs this exists to gather. Draft means unwatched, not
# unfinished.
#
# CI:none IS NOT A SKIP, AND NOT THE SAME AS passing. An empty check rollup
# means the PR's own checks never ran, so the only thing that will ever check it
# is the gate /gantry:integrate runs over the combined tree after its merge.
# That gate is the stronger check — a PR's solo CI says nothing about the
# combined tree, which is the whole premise — so the PR stays a candidate and
# the class is carried through to the queue and the PR body instead.
#
# MERGEABLE IS REPORTED, NEVER ACTED ON. GitHub computes it in the background
# and caches it, so it can be UNKNOWN or stale. Whether an item can be merged
# into the base is decided by order_queue.sh, against a freshly fetched base,
# with git.
#
# python3 does the JSON, as in skills/ship/scripts/detect_state.sh. jq would do
# as well for the fields, but the stacked-parent rule is a fixpoint over the
# whole set and reads far better in a loop.
#
# Exit codes: 0 = listed · 2 = usage, gh missing/unauthenticated, or unreadable
# JSON.
set -uo pipefail

die() { printf 'list_candidates: %s\n' "$1" >&2; exit 2; }

BASE_NAME=""
JSON_FILE=""
NUMBERS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)   [ $# -ge 2 ] || die "--base needs a branch name"; BASE_NAME="$2"; shift 2 ;;
    --base=*) BASE_NAME="${1#--base=}"; shift ;;
    --json)   [ $# -ge 2 ] || die "--json needs a file"; JSON_FILE="$2"; shift 2 ;;
    --json=*) JSON_FILE="${1#--json=}"; shift ;;
    -*)       die "unknown argument: $1" ;;
    *)
      case "$1" in
        *[!0-9]*|"") die "expected a PR number: $1" ;;
      esac
      NUMBERS="$NUMBERS $1"
      shift ;;
  esac
done

[ -n "$BASE_NAME" ] || die "--base <branch-name> is required"

FIELDS='number,title,url,isDraft,baseRefName,headRefName,headRefOid,mergeable,reviewDecision,labels,createdAt,statusCheckRollup,body'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/list_candidates.XXXXXX" 2>/dev/null)"
[ -n "$TMP" ] && [ -d "$TMP" ] || die "could not create a temp directory"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$JSON_FILE" ]; then
  [ -f "$JSON_FILE" ] || die "no such file: $JSON_FILE"
  cp "$JSON_FILE" "$TMP/prs.json" || die "cannot read $JSON_FILE"
else
  command -v gh >/dev/null 2>&1 || { echo "GH:missing"; die "gh is not installed"; }
  gh auth status >/dev/null 2>&1 || { echo "GH:unauth"; die "gh is not authenticated"; }
  gh pr list --state open --limit 1000 --json "$FIELDS" >"$TMP/prs.json" 2>"$TMP/gh.err" \
    || die "gh pr list failed: $(tr '\n' ' ' <"$TMP/gh.err")"
  echo "GH:ok"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to read the PR JSON"

python3 - "$TMP/prs.json" "$BASE_NAME" "$NUMBERS" <<'PY'
import json, sys, datetime

path, base, numbers_raw = sys.argv[1], sys.argv[2], sys.argv[3]
explicit = [int(n) for n in numbers_raw.split()]

try:
    with open(path) as fh:
        prs = json.load(fh)
except Exception as exc:                                  # noqa: BLE001 - reported, not raised
    sys.stderr.write("list_candidates: cannot parse the PR JSON: %s\n" % exc)
    sys.exit(2)
if not isinstance(prs, list):
    sys.stderr.write("list_candidates: the PR JSON is not a list\n")
    sys.exit(2)

BLOCKING_LABELS = ("blocked", "wip", "do-not-merge")
FAILING = ("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE",
           "ERROR")

def one_line(s):
    return " ".join(str(s or "").split())

def ci_class(rollup):
    """The head commit's checks, collapsed to one word.

    Any failing wins, then any pending; an empty rollup is `none`, which is a
    real and different answer from `passing`."""
    if not rollup:
        return "none"
    seen = pending = failing = False
    for c in rollup:
        seen = True
        if c.get("__typename") == "StatusContext" or "state" in c:
            state = (c.get("state") or "").upper()
            if state in ("PENDING", "EXPECTED"):
                pending = True
            elif state in FAILING:
                failing = True
        else:
            status = (c.get("status") or "").upper()
            conclusion = (c.get("conclusion") or "").upper()
            if status and status != "COMPLETED":
                pending = True
            elif conclusion in FAILING:
                failing = True
    if failing:
        return "failing"
    if pending:
        return "pending"
    return "passing" if seen else "none"

def epoch(iso):
    if not iso:
        return 0
    try:
        return int(datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except ValueError:
        return 0

by_number, by_head = {}, {}
for pr in prs:
    by_number[pr["number"]] = pr
    by_head[pr.get("headRefName")] = pr

integration = [pr for pr in prs if str(pr.get("headRefName", "")).startswith("integration/")]
considered = {pr["number"] for pr in integration}       # never candidates, never parents

def parent_of(pr):
    """A stacked PR targets another open PR's head branch.

    Targeting the base is never stacking, whatever any head branch is called.
    `headRefName` carries no owner prefix, so a pull request opened from a fork's
    own `master` has `headRefName == "master"` — and without this guard every PR
    targeting `master` would resolve that fork PR as its parent, so one skipped
    fork PR would skip the entire run as `stacked-parent-not-selected`."""
    if pr.get("baseRefName") == base:
        return None
    p = by_head.get(pr.get("baseRefName"))
    if p and p["number"] != pr["number"] and p["number"] not in considered:
        return p
    return None

if explicit:
    selected, missing, integration_asked = [], [], []
    for n in explicit:
        if n in considered:
            integration_asked.append(n)
        elif n in by_number:
            selected.append(by_number[n])
        else:
            missing.append(n)
else:
    # Discovery: everything on the base, then everything stacked on something
    # already in the set — including on a PR that will be SKIPPED, so that its
    # children can be reported as skipped for that reason rather than vanishing.
    missing, integration_asked = [], []
    selected = [pr for pr in prs
                if pr.get("baseRefName") == base and pr["number"] not in considered]
    changed = True
    while changed:
        changed = False
        chosen = {pr["number"] for pr in selected}
        for pr in prs:
            if pr["number"] in chosen or pr["number"] in considered:
                continue
            p = parent_of(pr)
            if p is not None and p["number"] in chosen:
                selected.append(pr)
                changed = True

selected.sort(key=lambda pr: pr["number"])

verdicts = {}                                   # number -> "candidate" | "skip <reason>"
facts = {}

for pr in selected:
    n = pr["number"]
    labels = [str(l.get("name", "")) for l in (pr.get("labels") or [])]
    ci = ci_class(pr.get("statusCheckRollup"))
    review = (pr.get("reviewDecision") or "NONE").upper()
    parent = parent_of(pr)
    facts[n] = dict(pr=pr, labels=labels, ci=ci, review=review,
                    parent=parent["number"] if parent else None)

    if review == "CHANGES_REQUESTED":
        verdicts[n] = "skip changes-requested"
        continue
    blocking = [l for l in labels if l.strip().lower() in BLOCKING_LABELS]
    if blocking:
        verdicts[n] = "skip label:%s" % blocking[0]
        continue
    if ci == "failing":
        verdicts[n] = "skip ci-failing"
        continue
    verdicts[n] = "candidate"

# The stacked rules come last and run to a fixpoint, so a grandchild of a
# skipped PR is skipped too. They also come BEFORE the base check below: a
# stacked PR does not target the base by construction, and reporting it as
# off-base would hide the reason that actually applies.
changed = True
while changed:
    changed = False
    for n, f in facts.items():
        if verdicts[n] != "candidate":
            continue
        parent = f["parent"]
        if parent is None:
            continue
        if parent not in verdicts or verdicts[parent] != "candidate":
            verdicts[n] = "skip stacked-parent-not-selected:%s" % parent
            changed = True

for n, f in facts.items():
    if verdicts[n] == "candidate" and f["parent"] is None \
       and f["pr"].get("baseRefName") != base:
        verdicts[n] = "skip base:%s" % f["pr"].get("baseRefName")

out = []
for n in sorted(list(facts) + missing + integration_asked):
    if n in missing:
        out.append("PR:%d" % n)
        out.append("VERDICT:skip not-open")
        out.append("END")
        continue
    if n in integration_asked:
        # Asked for by number, and open — so "not-open" would be a false reason.
        # An integration PR is never a candidate, and saying which it is tells the
        # operator to resume that lane instead.
        out.append("PR:%d" % n)
        out.append("VERDICT:skip integration-pr")
        out.append("END")
        continue
    f = facts[n]
    pr = f["pr"]
    created = pr.get("createdAt") or ""
    out.append("PR:%d" % n)
    out.append("TITLE:%s" % one_line(pr.get("title")))
    out.append("URL:%s" % (pr.get("url") or ""))
    out.append("DRAFT:%s" % ("yes" if pr.get("isDraft") else "no"))
    out.append("BASE_REF:%s" % (pr.get("baseRefName") or ""))
    out.append("HEAD_REF:%s" % (pr.get("headRefName") or ""))
    out.append("HEAD_SHA:%s" % (pr.get("headRefOid") or ""))
    out.append("CREATED:%s %d" % (created, epoch(created)))
    out.append("MERGEABLE:%s" % (pr.get("mergeable") or "UNKNOWN"))
    out.append("REVIEW:%s" % f["review"])
    out.append("LABELS:%s" % (",".join(f["labels"]) if f["labels"] else "none"))
    out.append("CI:%s" % f["ci"])
    out.append("STACKED_ON:%s" % (f["parent"] if f["parent"] is not None else "none"))
    out.append("CONTRACT:%s" % ("gantry" if "## What this change is for" in (pr.get("body") or "")
                                else "none"))
    out.append("VERDICT:%s" % verdicts[n])
    out.append("END")

for pr in integration:
    out.append("INTEGRATION_PR:%d %s %s %s" % (pr["number"], pr.get("headRefName") or "",
                                               pr.get("baseRefName") or "", pr.get("url") or ""))

cands = [str(n) for n in sorted(facts) if verdicts[n] == "candidate"]
skips = [str(n) for n in sorted(list(facts) + missing + integration_asked)
         if n in missing or n in integration_asked or verdicts[n] != "candidate"]
out.append("CANDIDATES:%s" % (" ".join(cands) if cands else "none"))
out.append("SKIPPED:%s" % (" ".join(skips) if skips else "none"))

print("\n".join(out))
PY
rc=$?
[ "$rc" -eq 0 ] || exit 2
exit 0
