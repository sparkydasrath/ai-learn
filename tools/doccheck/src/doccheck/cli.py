"""doccheck [--strict] [--rule RULE ...] [paths...]"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from doccheck.parse import parse
from doccheck.rules import ERROR, RULES, Finding


def find_docs_dir(start: Path) -> Path:
    for folder in (start, *start.parents):
        if (folder / "docs" / "conventions.md").exists():
            return folder / "docs"
    raise SystemExit("doccheck: can't find docs/conventions.md above the current directory")


def run(paths: list[Path], docs_dir: Path, only: set[str] | None = None) -> list[Finding]:
    all_docs = {str(p.resolve()): parse(p) for p in sorted(docs_dir.rglob("*.md"))}
    targets = [all_docs.get(str(p.resolve())) or parse(p) for p in paths] if paths else list(all_docs.values())
    findings: list[Finding] = []
    for doc in targets:
        for rule in RULES:
            for finding in rule(doc, all_docs):
                if only is None or finding.rule in only:
                    findings.append(finding)
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lint the curriculum docs against docs/conventions.md.")
    parser.add_argument("paths", nargs="*", type=Path, help="docs to check (default: every docs/**/*.md)")
    parser.add_argument("--strict", action="store_true", help="warnings fail the run too")
    parser.add_argument("--rule", action="append", help="only report this rule (repeatable)")
    args = parser.parse_args(argv)

    docs_dir = find_docs_dir(Path.cwd())
    findings = run(args.paths, docs_dir, set(args.rule) if args.rule else None)
    root = docs_dir.parent
    for f in findings:
        try:
            rel = Path(f.path).resolve().relative_to(root).as_posix()
        except ValueError:
            rel = f.path
        print(str(Finding(rel, f.line, f.level, f.rule, f.message)))

    counts = Counter((f.level, f.rule) for f in findings)
    summary = ", ".join(f"{n} {rule} {level}" for (level, rule), n in sorted(counts.items())) or "clean"
    print(f"doccheck: {summary}", file=sys.stderr)
    failed = any(f.level == ERROR for f in findings) or (args.strict and findings)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
