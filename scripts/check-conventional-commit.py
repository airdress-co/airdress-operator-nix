#!/usr/bin/env python3
"""Refuse a commit whose message is not a Conventional Commit.

Run by prek at the commit-msg stage with the path of the message file:

    type(scope)!: subject

`type` is one of TYPES; `(scope)` and `!` (a breaking change) are
optional. The header is at most MAX_HEADER characters, and a body, if
any, is separated from it by a blank line.

Exempt, because git or a tool writes them: merge commits ("Merge …"),
git's own revert header ("Revert "…""), and fixup!/squash!/amend!
commits, which are folded away before they reach a branch.

This is the source copy. Every workspace repo vendors it unchanged as
`scripts/check-conventional-commit.py`; change it here and re-vendor
with `just conventional-commit-vendor`.

Owner decision 2026-10-09: every repo, own dependency-free script.
"""

from __future__ import annotations

import re
import sys

TYPES = (
    "build",
    "chore",
    "ci",
    "deps",
    "docs",
    "feat",
    "fix",
    "perf",
    "refactor",
    "revert",
    "style",
    "test",
)
MAX_HEADER = 100

HEADER = re.compile(
    r"^(?P<type>[a-z]+)"
    r"(?:\((?P<scope>[^()\s][^()]*)\))?"
    r"(?P<breaking>!)?"
    r": (?P<subject>\S.*)$"
)
EXEMPT = re.compile(r"^(Merge |Revert \"|fixup! |squash! |amend! )")


def meaningful_lines(message: str) -> list[str]:
    """The message as git will store it: comment lines and the verbose
    diff below the scissors line removed, trailing blank lines dropped."""
    lines: list[str] = []
    for line in message.splitlines():
        if line.startswith("# ------------------------ >8"):
            break
        if line.startswith("#"):
            continue
        lines.append(line.rstrip())
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    return lines


def check(message: str) -> str | None:
    """None when the message is acceptable, otherwise why it is not."""
    lines = meaningful_lines(message)
    if not lines:
        return None  # git aborts an empty message itself
    header = lines[0]
    if EXEMPT.match(header):
        return None
    m = HEADER.match(header)
    if not m:
        return (
            f"the first line is not `type(scope): subject`:\n  {header}"
        )
    if m.group("type") not in TYPES:
        return (
            f"`{m.group('type')}` is not a commit type; use one of: "
            + ", ".join(TYPES)
        )
    if len(header) > MAX_HEADER:
        return (
            f"the first line is {len(header)} characters; keep it to "
            f"{MAX_HEADER} and put the rest in the body"
        )
    if len(lines) > 1 and lines[1]:
        return "leave a blank line between the first line and the body"
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check-conventional-commit.py <commit-msg-file>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        problem = check(f.read())
    if problem is None:
        return 0
    print(
        "commit message refused: "
        + problem
        + "\n\nExpected a Conventional Commit, for example:\n"
        "  feat(federation): admit peers by their hub binding\n"
        "  fix(pyinfra): render the wake block only for opted-in hosts\n"
        "  docs(runbooks): record the review verdict\n"
        "  chore(release): v0.1.125\n"
        "A breaking change adds `!` before the colon: feat(api)!: …",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
