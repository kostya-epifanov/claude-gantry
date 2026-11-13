# Plan — fail release-notes.sh on a missing version

Contract: the task file beside this one. One file changes, `bin/release-notes.sh`. The library is
left alone.

## Steps

### 1. Resolve the version as today

Keep the existing default-to-newest branch untouched. It is out of scope and it already works.

### 2. Ask the library whether the section is there

`lib/changelog.sh` already answers this. Call it before printing:

```bash
if ! changelog_section "$version" "$CHANGELOG"; then
  printf 'release-notes: no section for version %s\n' "$version" >&2
  exit 3
fi
```

`changelog_section` exits non-zero when the version has no heading in the file, so the check is the
call itself and no output has to be captured or compared.

### 3. Print the section

On the success path fall through to the existing print. Nothing else changes.

### 4. Keep an empty body a success

Because step 2 branches on the exit status rather than on the text, a section that exists with an
empty body takes the success path already. No extra code.

## Test strategy

Three shell invocations against a fixture changelog, one per acceptance criterion, asserting the
exit status and which stream the output landed on.

## Known weak points

- The message text is not covered by a test beyond "names the version".
