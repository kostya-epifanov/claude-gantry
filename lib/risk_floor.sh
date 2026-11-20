#!/usr/bin/env bash
# risk_floor.sh — which review lenses a diff fires, which files fired them, and
# the floor each lens sets on the change's risk level. No model is involved.
#
# Run with:
#   bash risk_floor.sh <base>                      # the working diff against <base>
#   bash risk_floor.sh --commits <base> <sha>...   # exactly these commits' changes
#   bash risk_floor.sh --body <name> <base>        # print lens <name>'s prompt body
#
# WHY THIS EXISTS. A lens (`.claude/review-lenses/<name>.md` in the target repo)
# names the paths whose change needs a careful read before merge, and a floor
# for each. Which files a diff touched, and which floor that sets, is
# arithmetic over git — so it is computed here, deterministically, and the PR
# body's `## Guarded changes` list comes from this output rather than from a
# model's reading of the diff. gantry:review runs it to decide which lens
# sub-agents to dispatch; gantry:ship runs it again at ship time for the file
# list and the floor; gantry:integrate runs the `--commits` form over the
# integration's own commits.
#
# THE LENS FILE. Frontmatter between the first two `---` lines:
#
#   ---
#   name: security
#   description: one line
#   floors:
#     ".claude/": critical
#     "bin/": medium
#     "setup.sh": high
#   defer: never
#   ---
#   <prompt body>
#
#   - A `floors` key ending in `/` is a directory prefix; any other key is an
#     exact repo-root-relative path. The keys are also the trigger: the lens
#     fires when the diff touches any of them.
#   - Levels are ordered low < medium < high < critical. A file matching several
#     keys of one lens takes the highest; the lens's FLOOR is the highest over
#     its matched files.
#   - `name:` falls back to the file's stem.
#   - Keys and values may be quoted with " or '. A trailing ` # comment` on an
#     unquoted value is ignored.
#
# FAIL LOUD, NEVER SILENTLY UNGUARDED. An unknown level, a lens with no
# frontmatter or no `floors:` keys, and a flow-style map (`floors: {a: high}`,
# or any value on the `floors:` line itself) are exit 2, naming the lens. Each
# of those would otherwise parse as "no keys", and a lens with no keys never
# fires — the one outcome a guard must not have by accident.
#
# LENSES ARE READ FROM THE BASE REF, NEVER THE WORKTREE. `git ls-tree <base>` and
# `git show <base>:<path>`. A diff that adds, edits or deletes a lens does not
# get to judge itself with the new text; it is reported instead (LENS_IN_DIFF).
#
# THE FILE SET.
#   working form  `git diff --name-only --no-renames <merge-base of base and
#                 HEAD>` (committed plus working-tree changes, both sides of a
#                 rename) plus untracked, non-ignored files. The merge-base and
#                 not the base tip: when the base moved after the branch was
#                 cut, a two-dot diff against the tip would count files an
#                 earlier PR changed on the base as this branch's changes.
#                 The chain's own artifacts are excluded by pathspec, as in
#                 lib/diff_fingerprint.sh.
#   --commits     each commit's own change: `git diff-tree` against its parent
#                 for an ordinary commit; for a merge, `git show --remerge-diff
#                 --name-only` — the files where the recorded resolution differs
#                 from a mechanical merge, i.e. the lines the merge itself wrote.
#
# stdout, one block per lens that fired (lenses in path order, files sorted):
#
#   LENS:<name>
#   FLOOR:<level>
#   DEFER:never                  only when the lens says `defer: never`
#   FILE:<path> <level>          one per matched file, with its own level
#   END
#
# then one `LENS_IN_DIFF:<path>` per lens file the file set itself touches.
# A file set touching no lens key and no lens file prints NOTHING, exit 0.
#
# Exit codes: 0 = answered (possibly with no output) · 2 = usage, not a
# repository, a base or commit that does not resolve, a malformed lens, or the
# matcher itself failing (a non-zero awk exit is never read as "no lens fired").
# The file set reaches the matcher through a temp file, not the environment: a
# diff of several thousand paths overflows the per-string limit of an exec.
#
# bash 3.2 (macOS): no associative arrays, no mapfile. awk does the parsing.
set -uo pipefail

die() { printf 'risk_floor: %s\n' "$1" >&2; exit 2; }

usage="usage: risk_floor.sh <base> | --commits <base> <sha>... | --body <name> <base>"
MODE=working
BODY_NAME=""
COMMITS=()

case "${1:-}" in
  --commits)
    [ "$#" -ge 3 ] || die "$usage"
    MODE=commits; BASE="$2"; shift 2
    COMMITS=("$@") ;;
  --body)
    [ "$#" -eq 3 ] || die "$usage"
    MODE=body; BODY_NAME="$2"; BASE="$3"
    [ -n "$BODY_NAME" ] || die "$usage" ;;
  -*|'')
    die "$usage" ;;
  *)
    [ "$#" -eq 1 ] || die "$usage"
    BASE="$1" ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
git rev-parse --quiet --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base does not resolve to a commit: $BASE"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "could not resolve the repository root"
cd "$ROOT" || die "could not enter $ROOT"

LENS_DIR='.claude/review-lenses'

# gitq — git with core.quotePath off, for every call that lists paths. With the
# default (true) a non-ASCII path comes out C-quoted ("bin/caf\303\251.sh"), never
# matches a lens key, and the file ships unguarded.
gitq() { git -c core.quotePath=false "$@"; }

# Every lens at the base, one path per line, in path order.
LENSES="$(gitq ls-tree -r --name-only "$BASE" -- "$LENS_DIR/" 2>/dev/null | grep -E '\.md$' | LC_ALL=C sort)"

# parse_lens <stem> — the lens text on stdin. Prints, tab-separated:
#   NAME <name> · DEFER <value> · KEY <key> <level> · BODY <line> (each body line)
# or, on a malformed lens, an `ERR <reason>` line. Matching is done by the caller's second awk.
parse_lens() {
  awk -v stem="$1" -v q="'" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unq(s,   c) {
      s = trim(s)
      c = substr(s, 1, 1)
      if ((c == "\"" || c == q) && length(s) >= 2 && substr(s, length(s), 1) == c)
        return substr(s, 2, length(s) - 2)
      sub(/[[:space:]]+#.*$/, "", s)
      return trim(s)
    }
    BEGIN {
      rank["low"] = 1; rank["medium"] = 2; rank["high"] = 3; rank["critical"] = 4
      state = 0; name = stem; defer = ""; nk = 0; sawfloors = 0; err = ""
    }
    { sub(/\r$/, "") }
    state == 0 {
      if ($0 !~ /^---[[:space:]]*$/) { err = "no frontmatter (the first line must be ---)"; exit }
      state = 1; next
    }
    state == 1 && /^---[[:space:]]*$/ { state = 2; next }
    state == 1 {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) next
      if ($0 ~ /^[^[:space:]]/) {
        infloors = 0
        k = $0; sub(/:.*$/, "", k); k = trim(k)
        v = $0; if (!sub(/^[^:]*:/, "", v)) v = ""
        if (k == "name")  { v = unq(v); if (v != "") name = v }
        if (k == "defer") { defer = tolower(unq(v)) }
        if (k == "floors") {
          if (trim(v) != "") { err = "floors must be a block map, one key per line (got a value on the floors: line)"; exit }
          infloors = 1; sawfloors = 1
        }
        next
      }
      if (!infloors) next
      line = trim($0)
      c = substr(line, 1, 1)
      if (c == "\"" || c == q) {
        rest = substr(line, 2)
        p = index(rest, c)
        if (p == 0) { err = "unterminated quoted key: " line; exit }
        key = substr(rest, 1, p - 1)
        rest = trim(substr(rest, p + 1))
        if (substr(rest, 1, 1) != ":") { err = "expected key: level, got: " line; exit }
        lvl = substr(rest, 2)
      } else {
        p = index(line, ":")
        if (p == 0) { err = "expected key: level, got: " line; exit }
        key = trim(substr(line, 1, p - 1))
        lvl = substr(line, p + 1)
      }
      lvl = tolower(unq(lvl))
      if (key == "") { err = "empty key in floors"; exit }
      if (!(lvl in rank)) { err = "unknown level \"" lvl "\" for " key " (low, medium, high, critical)"; exit }
      nk++; printf "KEY\t%s\t%s\n", key, lvl
      next
    }
    state == 2 { printf "BODY\t%s\n", $0 }
    END {
      if (err != "") { print "ERR\t" err; exit }
      if (state == 0) { print "ERR\tempty lens file"; exit }
      if (state == 1) { print "ERR\tunterminated frontmatter (no closing ---)"; exit }
      if (!sawfloors) { print "ERR\tno floors: key"; exit }
      if (nk == 0)    { print "ERR\tfloors: has no keys"; exit }
      printf "NAME\t%s\n", name
      printf "DEFER\t%s\n", defer
    }
  '
}

# --- parse every lens once, before any output -----------------------------------
# A malformed lens or a repeated `name:` is exit 2 in every mode, before anything
# is printed. Two lenses sharing a name would print two `LENS:<name>` blocks,
# `--body` would return only the first one's prompt, and review.md would carry
# two `## Lens: <name>` headings that ship's per-heading splice cannot tell apart.
LENS_PATH=()
LENS_NAME=()
LENS_PARSED=()
while IFS= read -r lens; do
  [ -n "$lens" ] || continue
  stem="$(basename "$lens" .md)"
  parsed="$(git show "$BASE:$lens" 2>/dev/null | parse_lens "$stem")" || die "could not read $lens at $BASE"
  err="$(printf '%s\n' "$parsed" | sed -n 's/^ERR	//p')"
  [ -z "$err" ] || die "$lens: $err"
  n="$(printf '%s\n' "$parsed" | sed -n 's/^NAME	//p')"
  i=0
  while [ "$i" -lt "${#LENS_NAME[@]}" ]; do
    [ "${LENS_NAME[$i]}" != "$n" ] || die "two lenses are named $n: ${LENS_PATH[$i]} and $lens"
    i=$((i + 1))
  done
  LENS_PATH[${#LENS_PATH[@]}]="$lens"
  LENS_NAME[${#LENS_NAME[@]}]="$n"
  LENS_PARSED[${#LENS_PARSED[@]}]="$parsed"
done <<EOF
$LENSES
EOF

# --- --body: print one lens's prompt body ---------------------------------------
if [ "$MODE" = body ]; then
  i=0
  while [ "$i" -lt "${#LENS_NAME[@]}" ]; do
    if [ "${LENS_NAME[$i]}" = "$BODY_NAME" ]; then
      printf '%s\n' "${LENS_PARSED[$i]}" | sed -n 's/^BODY	//p'
      exit 0
    fi
    i=$((i + 1))
  done
  die "no lens named $BODY_NAME at $BASE"
fi

# --- the file set -----------------------------------------------------------------
EXCLUDE=(':!task.md' ':!plan.md' ':!handover.md' ':!review.md' ':!qa.md' ':!.claude/artifacts' ':!journal.jsonl')

if [ "$MODE" = working ]; then
  MB="$(git merge-base "$BASE" HEAD 2>/dev/null)" || die "no merge-base between $BASE and HEAD"
  FILES="$(
    {
      gitq diff --name-only --no-renames "$MB" -- "${EXCLUDE[@]}" 2>/dev/null
      gitq ls-files --others --exclude-standard -- "${EXCLUDE[@]}" 2>/dev/null
    } | LC_ALL=C sort -u
  )"
else
  FILES=""
  for c in "${COMMITS[@]}"; do
    git rev-parse --quiet --verify "$c^{commit}" >/dev/null 2>&1 || die "commit does not resolve: $c"
    nparents="$(git rev-list --parents -n 1 "$c" 2>/dev/null | awk '{ print NF - 1 }')"
    if [ "${nparents:-0}" -gt 1 ]; then
      part="$(gitq show --remerge-diff --format= --name-only --no-renames "$c" 2>/dev/null)" \
        || die "could not compute the resolution of merge $c (git >= 2.36 is needed for --remerge-diff)"
    else
      part="$(gitq diff-tree --root --no-commit-id --name-only -r --no-renames "$c" 2>/dev/null)" \
        || die "could not list the files of commit $c"
    fi
    FILES="$FILES
$part"
  done
  FILES="$(printf '%s\n' "$FILES" | sed '/^$/d' | LC_ALL=C sort -u)"
fi

# --- match each lens against the file set ---------------------------------------
# Only when a lens exists: a repo with no lenses must not depend on a writable tmp.
FILES_TMP=""
if [ "${#LENS_PARSED[@]}" -gt 0 ]; then
  FILES_TMP="$(mktemp "${TMPDIR:-/tmp}/risk_floor.XXXXXX")" || die "could not create a temp file"
  trap 'rm -f "$FILES_TMP"' EXIT
  printf '%s\n' "$FILES" > "$FILES_TMP" || die "could not write the file set to $FILES_TMP"
fi
OUT=""
i=0
while [ "$i" -lt "${#LENS_PARSED[@]}" ]; do
  block="$(printf '%s\n' "${LENS_PARSED[$i]}" | awk -F '\t' -v files_path="$FILES_TMP" '
    BEGIN {
      rank["low"] = 1; rank["medium"] = 2; rank["high"] = 3; rank["critical"] = 4
      name_of[1] = "low"; name_of[2] = "medium"; name_of[3] = "high"; name_of[4] = "critical"
      nf = 0; bad = 0
      while ((rc = (getline line < files_path)) > 0) F[++nf] = line
      if (rc < 0) { bad = 1; exit 2 }
      close(files_path)
      nk = 0
    }
    $1 == "KEY"   { nk++; K[nk] = $2; L[nk] = rank[$3]; next }
    $1 == "NAME"  { name = $2; next }
    $1 == "DEFER" { defer = $2; next }
    END {
      if (bad) exit 2
      floor = 0; nm = 0
      for (i = 1; i <= nf; i++) {
        f = F[i]; if (f == "") continue
        best = 0
        for (j = 1; j <= nk; j++) {
          k = K[j]
          if (substr(k, length(k), 1) == "/") hit = (substr(f, 1, length(k)) == k)
          else hit = (f == k)
          if (hit && L[j] > best) best = L[j]
        }
        if (best > 0) { nm++; M[nm] = "FILE:" f " " name_of[best]; if (best > floor) floor = best }
      }
      if (nm == 0) exit
      print "LENS:" name
      print "FLOOR:" name_of[floor]
      if (defer == "never") print "DEFER:never"
      for (i = 1; i <= nm; i++) print M[i]
      print "END"
    }
  ')" || die "the lens matcher failed on lens ${LENS_NAME[$i]} (${LENS_PATH[$i]})"
  [ -n "$block" ] && OUT="$OUT$block
"
  i=$((i + 1))
done

IN_DIFF="$(printf '%s\n' "$FILES" | grep -E "^$LENS_DIR/" || true)"
[ -n "$OUT" ] && printf '%s' "$OUT"
if [ -n "$IN_DIFF" ]; then
  printf '%s\n' "$IN_DIFF" | sed 's/^/LENS_IN_DIFF:/'
fi
exit 0
