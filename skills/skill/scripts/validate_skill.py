#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml"]
# ///
"""Validate a Claude Code skill directory.

Complements `claude plugin validate`, which only checks the plugin manifest and
never looks at a skill's frontmatter. This checks the things that fail silently:
a description Claude can't match on, a name that disagrees with the directory,
a typo'd frontmatter key, a body that quietly taxes every session.

Usage:  uv run validate_skill.py <skill-dir> [<skill-dir> ...]

Exit 0 if every skill is free of errors (warnings still exit 0), 1 otherwise.
"""

import re
import sys
from pathlib import Path

import yaml

# Fields Claude Code understands. An unknown key is almost always a typo
# (`when-to-use` for `when_to_use`), and a typo'd key is ignored silently —
# which is exactly the failure this catches.
CLAUDE_CODE_FIELDS = {
    "name", "description", "when_to_use", "argument-hint", "arguments",
    "disable-model-invocation", "user-invocable", "allowed-tools",
    "disallowed-tools", "model", "effort", "context", "agent", "paths",
    "hooks", "shell",
}
# Accepted by the portable Agent Skills spec; harmless in Claude Code.
PORTABLE_FIELDS = {"license", "metadata", "compatibility", "version"}
KNOWN_FIELDS = CLAUDE_CODE_FIELDS | PORTABLE_FIELDS

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
RESERVED = ("claude", "anthropic")
MAX_NAME = 64
MAX_DESC = 1024
MAX_BODY_LINES = 500

# Markdown links to local files, e.g. [text](references/authoring.md)
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def split_frontmatter(text):
    """Return (frontmatter_str, body_str, error). Frontmatter is None if absent."""
    if not text.startswith("---"):
        return None, text, "SKILL.md has no YAML frontmatter (must start with ---)"
    m = re.match(r"^---\r?\n(.*?)\r?\n---[ \t]*\r?\n?(.*)\Z", text, re.DOTALL)
    if not m:
        return None, text, "frontmatter opens with --- but is never closed"
    return m.group(1), m.group(2), None


def local_md_links(text, base):
    """Local markdown files linked from `text`, resolved against `base`."""
    out = []
    for target in LINK_RE.findall(text):
        target = target.split("#", 1)[0].strip()
        if not target or "://" in target or target.startswith("/"):
            continue
        out.append((target, (base / target)))
    return out


def validate(skill_dir):
    errors, warnings = [], []
    skill_dir = Path(skill_dir).resolve()

    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return [f"no SKILL.md in {skill_dir}"], []

    text = skill_md.read_text(encoding="utf-8")
    fm_text, body, err = split_frontmatter(text)
    if err:
        # Claude Code loads the body with empty metadata rather than failing, so
        # /name still works and the skill silently stops being discoverable.
        return [err], []

    try:
        fm = yaml.safe_load(fm_text)
    except yaml.YAMLError as e:
        return [f"frontmatter is not valid YAML: {e}"], []
    if fm is None:
        fm = {}
    if not isinstance(fm, dict):
        return [f"frontmatter must be a YAML mapping, got {type(fm).__name__}"], []

    for key in sorted(set(fm) - KNOWN_FIELDS):
        errors.append(f"unknown frontmatter key {key!r} — typo'd keys are ignored silently")

    # --- name -------------------------------------------------------------
    name = fm.get("name")
    if name is None:
        warnings.append("no 'name' — the directory name is used as the display label")
    elif not isinstance(name, str):
        errors.append(f"'name' must be a string, got {type(name).__name__}")
    else:
        name = name.strip()
        if not NAME_RE.match(name):
            errors.append(
                f"name {name!r} must be lowercase letters/digits separated by single hyphens"
            )
        if len(name) > MAX_NAME:
            errors.append(f"name is {len(name)} chars, max {MAX_NAME}")
        for word in RESERVED:
            if word in name.lower():
                errors.append(f"name contains the reserved word {word!r}")
        # The directory name is what you type after the slash; `name` is only a
        # display label. Disagreement misleads whoever reads the file next.
        if name != skill_dir.name:
            errors.append(
                f"name {name!r} != directory {skill_dir.name!r} — the directory "
                f"decides the command name, so this misleads"
            )

    # --- description ------------------------------------------------------
    desc = fm.get("description")
    if desc is None:
        errors.append("no 'description' — Claude has nothing to match the skill against")
    elif not isinstance(desc, str):
        errors.append(f"'description' must be a string, got {type(desc).__name__}")
    else:
        desc = desc.strip()
        if not desc:
            errors.append("'description' is empty")
        if len(desc) > MAX_DESC:
            errors.append(f"description is {len(desc)} chars, max {MAX_DESC}")
        if "<" in desc or ">" in desc:
            errors.append(
                "description contains angle brackets — the spec forbids XML tags "
                "here; use [branch] or plain words instead"
            )
        if not re.search(r"\buse\s+when\b|\bwhen\s+the\s+user\b", desc, re.I):
            warnings.append(
                "description never says *when* to use the skill — discovery depends on it"
            )
        for opener in ("i can ", "i'll ", "you can use this", "this skill lets you"):
            if desc.lower().startswith(opener) or opener in desc.lower()[:60]:
                warnings.append("description should be third person, not first/second")
                break

    # --- invocation control ----------------------------------------------
    if fm.get("disable-model-invocation") is True and fm.get("user-invocable") is False:
        errors.append(
            "disable-model-invocation: true with user-invocable: false — "
            "nothing could ever invoke this skill"
        )

    # --- body -------------------------------------------------------------
    body_lines = len(body.splitlines())
    if body_lines > MAX_BODY_LINES:
        warnings.append(
            f"body is {body_lines} lines (>{MAX_BODY_LINES}); it stays in context "
            f"for the whole session — move detail into references/"
        )

    # --- supporting files -------------------------------------------------
    for target, path in local_md_links(body, skill_dir):
        if not path.exists():
            errors.append(f"SKILL.md links to {target!r}, which does not exist")
            continue
        # References must be one level deep: Claude partially reads files it
        # reaches through another reference, so a link-of-a-link loses content.
        if path.suffix == ".md":
            try:
                nested = local_md_links(path.read_text(encoding="utf-8"), path.parent)
            except OSError as e:
                warnings.append(f"could not read {target!r}: {e}")
                continue
            for nested_target, nested_path in nested:
                if nested_path.suffix == ".md" and nested_path.exists():
                    warnings.append(
                        f"{target} links on to {nested_target} — keep references one "
                        f"level deep from SKILL.md, or the nested file gets partially read"
                    )

    return errors, warnings


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-3].strip(), file=sys.stderr)
        return 1

    failed = False
    for target in argv[1:]:
        errors, warnings = validate(target)
        label = Path(target).resolve().name
        if errors:
            failed = True
        if not errors and not warnings:
            print(f"OK    {label}")
            continue
        print(f"{'FAIL' if errors else 'WARN'}  {label}")
        for e in errors:
            print(f"  error: {e}")
        for w in warnings:
            print(f"  warn:  {w}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
