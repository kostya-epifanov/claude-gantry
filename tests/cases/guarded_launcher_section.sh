#!/usr/bin/env bash
#
# A `## Guarded changes` section carrying the launcher's marker is owned by the
# launcher: lib/splice_pr_section.sh must never delete or rewrite it,
# and may only append its own bullets.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SPLICE="$GANTRY_ROOT/lib/splice_pr_section.sh"
W="$CASE_TMP/g"
mkdir -p "$W"

{
  printf '## Risk\n\nRisk level: low\n\n'
  printf '## Guarded changes\n<!-- homebase-launcher-guarded -->\n- `hooks/hooks.json`: launcher-listed\n\n'
  printf '## Not proven by this run\n\nnothing\n'
} >"$W/body.md"

printf '## Guarded changes\n\nNone — no lens fires on the current diff.\n' >"$W/none.md"
bash "$SPLICE" "$W/body.md" "$W/none.md" "Guarded changes" >"$W/out1.md"
if cmp -s "$W/out1.md" "$W/body.md"; then _pass "no lens fires: launcher section left byte-identical"
else _fail "launcher section was changed by a None replacement"; fi

printf '## Guarded changes\n\n- `lib/x.sh`: look here\n- `hooks/hooks.json`: launcher-listed\n' >"$W/lens.md"
bash "$SPLICE" "$W/body.md" "$W/lens.md" "Guarded changes" >"$W/out2.md"
grep -q 'homebase-launcher-guarded' "$W/out2.md" && _pass "marker kept" || _fail "marker lost"
grep -qF -- '- `lib/x.sh`: look here' "$W/out2.md" && _pass "lens bullet added" || _fail "lens bullet missing"
[ "$(grep -cF -- '- `hooks/hooks.json`: launcher-listed' "$W/out2.md")" = 1 ] \
  && _pass "launcher bullet kept once, not duplicated" || _fail "launcher bullet dropped or duplicated"
grep -q '^## Not proven by this run' "$W/out2.md" && grep -q '^## Risk' "$W/out2.md" \
  && _pass "neighbouring sections intact" || _fail "neighbour section lost"

# a section file with no final newline keeps its last bullet
printf '## Guarded changes\n\n- `lib/y.sh`: no trailing newline' >"$W/nonl.md"
bash "$SPLICE" "$W/body.md" "$W/nonl.md" "Guarded changes" >"$W/out4.md"
grep -qF -- '- `lib/y.sh`: no trailing newline' "$W/out4.md" && _pass "last bullet without newline kept" || _fail "last bullet lost"

# without the marker the old behaviour holds
sed '/homebase-launcher-guarded/d' "$W/body.md" >"$W/plain.md"
bash "$SPLICE" "$W/plain.md" "$W/none.md" "Guarded changes" >"$W/out3.md"
grep -q 'None — no lens fires' "$W/out3.md" && ! grep -q 'launcher-listed' "$W/out3.md" \
  && _pass "unmarked section is still replaced" || _fail "unmarked section not replaced"

finish
