# Plan — a --words flag for tally.sh

Contract: the task file beside this one. One file changes, `bin/tally.sh`. `lib/tally.sh` is not
touched, which the contract requires.

## Steps

### 1. Parse the one flag

Replace the fixed `[ "$#" -eq 1 ]` check with a small parse over the first argument:

```bash
mode=lines
if [ "${1:-}" = "--words" ]; then
  mode=words
  shift
elif case "${1:-}" in -?*) true ;; *) false ;; esac; then
  usage
fi
```

`usage` prints `usage: tally.sh [--words] <file>` to stderr and exits 2. Anything beginning with a
dash that is not `--words` therefore exits 2 without counting, which is the fourth criterion. A
bare path is left alone, which is the second.

### 2. Keep the arity and existence checks where they are

After the shift, `[ "$#" -eq 1 ]` and the `[ -f "$file" ]` test run exactly as they do today, so a
missing file still exits 2 with its message on stderr in either mode. That is the third criterion
and it needs no new code — only the ordering, which step 1 preserves by shifting before the checks
rather than after them.

### 3. Dispatch on the mode

```bash
if [ "$mode" = words ]; then
  count_words "$file"
else
  count_lines "$file"
fi
```

`count_words` is already in `lib/tally.sh` with the same one-argument signature as `count_lines`
and prints a bare number, so nothing else in the script changes. That is the first criterion.

## Test strategy

Four invocations against one fixture file whose line and word counts are known, one per acceptance
criterion, asserting the number on stdout, the stream the message landed on, and the exit status:
`--words f`, `f`, `--words nosuchfile`, `--lines f`.

## Known weak points

- `--words` after the path (`tally.sh f --words`) is not accepted and not rejected with a usage
  line; it falls through to the arity check and exits 2 with the usage line anyway, which is the
  right status for the wrong reason. Worth a comment, not worth a parser.
