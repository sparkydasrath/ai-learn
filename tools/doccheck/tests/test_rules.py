from pathlib import Path

import pytest

from doccheck.parse import parse, slug
from doccheck.rules import (
    check_bash_env,
    check_layout,
    check_links,
    check_not_implemented,
    check_ollama_wiring,
    check_sections,
    check_stale_api,
)

FENCE = "```"


def write(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(body.replace("~~~", FENCE), encoding="utf-8")
    return p


def rules_hit(rule, path: Path) -> list[str]:
    doc = parse(path)
    return [f.message for f in rule(doc, {str(path.resolve()): doc})]


@pytest.mark.parametrize(
    ("heading", "anchor"),
    [
        ("Two languages: Python first, then C#", "two-languages-python-first-then-c"),
        ("The `stub` backend", "the-stub-backend"),
        ("snake_case names", "snake_case-names"),
    ],
)
def test_slug_matches_github(heading: str, anchor: str) -> None:
    assert slug(heading) == anchor


def test_links_missing_anchor_and_file(tmp_path: Path) -> None:
    p = write(tmp_path, "a.md", "# Real\n[ok](#real) [bad](#nope) [gone](missing.md)\n")
    assert rules_hit(check_links, p) == ["missing anchor #nope", "missing file missing.md"]


def test_links_inside_code_are_ignored(tmp_path: Path) -> None:
    p = write(tmp_path, "a.md", "# A\n~~~\n[x](missing.md)\n~~~\n")
    assert rules_hit(check_links, p) == []


def test_sections_order_and_watch(tmp_path: Path) -> None:
    body = (
        "# 07\n## Where this fits\n## Cross-check the two\n"
        "## Review track sync\n- nothing\n## Pitfalls\n## Checkpoint\n## Going deeper\n"
    )
    p = write(tmp_path, "07-x.md", body)
    assert rules_hit(check_sections, p) == [
        "'Review track sync' must come just before 'Checkpoint'",
        "'Review track sync' has no 'C#-specific watch' bullet",
    ]


def test_sections_only_apply_to_module_docs(tmp_path: Path) -> None:
    assert rules_hit(check_sections, write(tmp_path, "conventions.md", "# C\n")) == []


def test_stale_api_in_code_but_not_prose(tmp_path: Path) -> None:
    p = write(tmp_path, "a.md", "Watch for `CompleteAsync`.\n~~~csharp\nawait c.CompleteAsync(m);\n~~~\n")
    assert len(rules_hit(check_stale_api, p)) == 1


def test_not_implemented_and_ignore_marker(tmp_path: Path) -> None:
    body = "~~~python\nraise NotImplementedError\n~~~\n<!-- doccheck: ignore=not-implemented -->\n~~~python\nraise NotImplementedError\n~~~\n"
    assert len(rules_hit(check_not_implemented, write(tmp_path, "a.md", body))) == 1


def test_bash_env_needs_pwsh_form(tmp_path: Path) -> None:
    bare = write(tmp_path, "a.md", "~~~bash\nLLM_BACKEND=stub dotnet run\n~~~\n")
    paired = write(tmp_path, "b.md", "~~~bash\nLLM_BACKEND=stub dotnet run\n~~~\n~~~powershell\n$env:LLM_BACKEND='stub'; dotnet run\n~~~\n")
    assert len(rules_hit(check_bash_env, bare)) == 1
    assert rules_hit(check_bash_env, paired) == []


def test_layout_flags_unshown_files(tmp_path: Path) -> None:
    body = (
        "~~~\nprojects/07-x/\n├── fixtures/\n│   └── qa.jsonl\n└── python/\n"
        "    ├── app/\n    │   ├── main.py\n    │   └── hosted.py   # exercise\n"
        "    ├── run.py\n    └── uv.lock\n~~~\n~~~python\n# app/main.py\n~~~\n"
    )
    p = write(tmp_path, "07-x.md", body)
    assert rules_hit(check_layout, p) == [
        "python/run.py is in the layout tree but no code block names it (start its block with a path comment, or mark it '# exercise')"
    ]


def test_ollama_wiring(tmp_path: Path) -> None:
    body = (
        "~~~yaml\n# compose.yaml\n    environment:\n      OLLAMA_BASE_URL: http://ollama:11434\n~~~\n"
        "~~~bash\n# projects/x/python/.env.example\nOLLAMA_BASE_URL=http://localhost:11434\n# OLLAMA_BASE_URL=ok\n~~~\n"
    )
    assert len(rules_hit(check_ollama_wiring, write(tmp_path, "a.md", body))) == 2
