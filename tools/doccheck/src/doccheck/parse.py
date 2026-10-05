"""Split a markdown doc into the pieces the rules look at: headings, code blocks, links."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([\w#+.-]*)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
IGNORE = re.compile(r"<!--\s*doccheck:\s*ignore=([\w,-]+)\s*-->")


@dataclass(frozen=True)
class Heading:
    line: int  # 1-based
    level: int
    text: str

    @property
    def anchor(self) -> str:
        return slug(self.text)


@dataclass(frozen=True)
class CodeBlock:
    start: int  # 1-based line of the opening fence
    lang: str
    lines: tuple[str, ...]
    ignored: frozenset[str] = field(default_factory=frozenset)

    @property
    def body(self) -> str:
        return "\n".join(self.lines)


@dataclass
class Doc:
    path: Path
    text: str
    lines: list[str]
    headings: list[Heading]
    blocks: list[CodeBlock]
    prose_lines: list[tuple[int, str]]  # (1-based line, text) outside code blocks

    @property
    def anchors(self) -> set[str]:
        return {h.anchor for h in self.headings}


def slug(heading: str) -> str:
    """GitHub's anchor slug: lowercase, drop punctuation except - and _, spaces to -."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def parse(path: Path) -> Doc:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    headings: list[Heading] = []
    blocks: list[CodeBlock] = []
    prose: list[tuple[int, str]] = []

    i = 0
    while i < len(lines):
        line = lines[i]
        m = FENCE.match(line)
        if m:
            fence = m.group(2)
            lang = m.group(3).lower()
            start = i + 1
            body: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith(fence):
                body.append(lines[i])
                i += 1
            ignored: set[str] = set()
            for back in range(max(0, start - 3), start - 1):
                im = IGNORE.search(lines[back])
                if im:
                    ignored.update(im.group(1).split(","))
            blocks.append(CodeBlock(start, lang, tuple(body), frozenset(ignored)))
            i += 1
            continue
        h = HEADING.match(line)
        if h:
            headings.append(Heading(i + 1, len(h.group(1)), h.group(2)))
        prose.append((i + 1, line))
        i += 1

    return Doc(path, text, lines, headings, blocks, prose)
