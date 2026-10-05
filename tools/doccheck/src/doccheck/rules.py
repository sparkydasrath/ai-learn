"""The checks. Each rule takes a parsed Doc and yields Findings."""

from __future__ import annotations

import re
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import PurePosixPath

from doccheck.parse import CodeBlock, Doc

ERROR = "error"
WARNING = "warning"


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    level: str
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.level} {self.rule}: {self.message}"


Rule = Callable[[Doc, dict[str, Doc]], Iterator[Finding]]

MODULE_DOC = re.compile(r"^(0[3-9]|1[0-7])-")


def is_module_doc(doc: Doc) -> bool:
    return bool(MODULE_DOC.match(doc.path.name))


def _f(doc: Doc, line: int, level: str, rule: str, message: str) -> Finding:
    return Finding(doc.path.as_posix(), line, level, rule, message)


# --- link -------------------------------------------------------------------------------------

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")


def check_links(doc: Doc, all_docs: dict[str, Doc]) -> Iterator[Finding]:
    for line_no, line in doc.prose_lines:
        for target in LINK.findall(re.sub(r"`[^`]*`", "", line)):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            path_part, _, anchor = target.partition("#")
            if path_part:
                resolved = (doc.path.parent / path_part).resolve()
                if not resolved.exists():
                    yield _f(doc, line_no, ERROR, "link", f"missing file {target}")
                    continue
                target_doc = all_docs.get(str(resolved))
            else:
                target_doc = doc
            if anchor and target_doc is not None and anchor not in target_doc.anchors:
                yield _f(doc, line_no, ERROR, "link", f"missing anchor {target}")


# --- section ----------------------------------------------------------------------------------

REQUIRED_SECTIONS = {
    "Where this fits": re.compile(r"where this fits", re.I),
    "cross-check": re.compile(r"cross-check", re.I),
    "Review track sync": re.compile(r"review track sync", re.I),
    "Checkpoint": re.compile(r"^checkpoint", re.I),
    "Going deeper": re.compile(r"going deeper", re.I),
}


def check_sections(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    if not is_module_doc(doc):
        return
    found = {name: [h for h in doc.headings if rx.search(h.text)] for name, rx in REQUIRED_SECTIONS.items()}
    for name, hits in found.items():
        if not hits:
            yield _f(doc, 1, ERROR, "section", f"no '{name}' heading")
    review, checkpoint = found["Review track sync"], found["Checkpoint"]
    if review and checkpoint:
        r, c = review[0], checkpoint[0]
        between = [h for h in doc.headings if r.line < h.line < c.line and h.level <= r.level]
        if r.line > c.line or between:
            yield _f(doc, r.line, ERROR, "section", "'Review track sync' must come just before 'Checkpoint'")
        section_text = "\n".join(doc.lines[r.line : c.line - 1])
        if "C#-specific watch" not in section_text:
            yield _f(doc, r.line, ERROR, "section", "'Review track sync' has no 'C#-specific watch' bullet")


# --- stale-api / not-implemented -------------------------------------------------------------

STALE_API = [
    (re.compile(r"\bCompleteAsync\b|\bCompleteStreamingAsync\b"), "pre-GA MEAI name; use GetResponseAsync / GetStreamingResponseAsync"),
    (re.compile(r"\bChatCompletion\b|\bStreamingChatCompletionUpdate\b"), "pre-GA MEAI type; use ChatResponse / ChatResponseUpdate"),
    (re.compile(r"\.AsChatClient\("), "pre-GA adapter name; use AsIChatClient()"),
    (re.compile(r"GenerateEmbeddingVectorAsync"), "pre-GA embedding helper; use GenerateVectorAsync / GenerateAsync"),
    (re.compile(r"Microsoft\.Extensions\.AI\.Ollama"), "deprecated package; use OllamaSharp"),
    (re.compile(r"\.\[dev\]"), "an extra, not a dependency group; use `uv add --dev`"),
]
NOT_IMPLEMENTED = re.compile(r"raise NotImplementedError|throw new NotImplementedException")


def _code_lines(block: CodeBlock) -> Iterator[tuple[int, str]]:
    for offset, line in enumerate(block.lines, start=1):
        yield block.start + offset, line


def check_stale_api(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    for block in doc.blocks:
        if "stale-api" in block.ignored:
            continue
        for line_no, line in _code_lines(block):
            for rx, why in STALE_API:
                if rx.search(line):
                    yield _f(doc, line_no, ERROR, "stale-api", why)


def check_not_implemented(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    for block in doc.blocks:
        if "not-implemented" in block.ignored:
            continue
        for line_no, line in _code_lines(block):
            if NOT_IMPLEMENTED.search(line):
                yield _f(doc, line_no, ERROR, "not-implemented", "stub on a code path the doc presents as runnable (ADR-002)")


# --- bash-env ---------------------------------------------------------------------------------

SHELL_LANGS = {"", "bash", "sh", "shell", "console"}
BASH_ENV = re.compile(r"^\s*(?:[A-Z][A-Z0-9_]*=\S*\s+)+[\w./~-]")
PWSH_HINT = re.compile(r"\$env:|bash\s*/\s*WSL|Git Bash|bash-only", re.I)


def check_bash_env(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    for block in doc.blocks:
        if block.lang not in SHELL_LANGS or "bash-env" in block.ignored:
            continue
        end = block.start + len(block.lines) + 1
        window = "\n".join(doc.lines[max(0, block.start - 6) : min(len(doc.lines), end + 12)])
        if PWSH_HINT.search(window):
            continue
        for line_no, line in _code_lines(block):
            if BASH_ENV.match(line):
                yield _f(doc, line_no, WARNING, "bash-env", "`VAR=x cmd` is bash-only; add the pwsh `$env:VAR='x'; cmd` form")


# --- layout -----------------------------------------------------------------------------------

TREE_LINE = re.compile(r"^(?P<prefix>(?:[│ ]   )*)(?:[├└]── )(?P<name>[^\s#]+)(?:\s+#\s*(?P<comment>.*))?$")
GENERATED_NAMES = {
    "uv.lock", ".python-version", "README.md", "settings.json", "Directory.Build.props",
    "__init__.py", "SmokeTests.cs", ".gitignore", ".dockerignore", "Dockerfile.dockerignore",
    ".env", "pyrightconfig.json", "NOTES.md", "launchSettings.json",
}
GENERATED_SUFFIXES = (".slnx", ".csproj")
EXEMPT_COMMENT = re.compile(r"exercise|generated|gitignored|bootstrap|scaffold|optional|output|left to you", re.I)
DATA_SUFFIXES = (".jsonl", ".json", ".csv", ".md", ".txt", ".png", ".onnx", ".gguf", ".bin", ".safetensors")


def tree_files(block: CodeBlock) -> Iterator[tuple[int, PurePosixPath, str]]:
    """Yield (line, path, comment) for each file in a ├── / └── layout tree."""
    stack: list[str] = []
    for line_no, line in _code_lines(block):
        m = TREE_LINE.match(line)
        if not m:
            continue
        depth = len(m.group("prefix")) // 4
        name = m.group("name")
        del stack[depth:]
        if name.endswith("/"):
            stack.append(name.rstrip("/"))
            continue
        yield line_no, PurePosixPath(*stack, name), m.group("comment") or ""


def _shown_names(doc: Doc) -> set[str]:
    """Basenames a doc shows: named in a block's first line, or just above the block."""
    shown: set[str] = set()
    prose = dict(doc.prose_lines)
    for block in doc.blocks:
        if "├──" in block.body:
            continue  # a layout tree names files; it doesn't show them
        context = [block.lines[0] if block.lines else ""]
        context += [prose[n] for n in range(block.start - 6, block.start) if n in prose]
        for text in context:
            shown.update(re.findall(r"[\w.-]+\.\w+|Dockerfile|Modelfile", text))
    return shown


def check_layout(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    if not is_module_doc(doc):
        return
    shown = _shown_names(doc)
    for block in doc.blocks:
        if "layout" in block.ignored or "├──" not in block.body:
            continue
        for line_no, path, comment in tree_files(block):
            name = path.name
            if (
                "fixtures" in path.parts
                or name in GENERATED_NAMES
                or name.endswith(GENERATED_SUFFIXES)
                or (name.endswith(DATA_SUFFIXES) and name != "compose.yaml")
                or EXEMPT_COMMENT.search(comment)
                or name in shown
            ):
                continue
            yield _f(doc, line_no, WARNING, "layout", f"{path} is in the layout tree but no code block names it (start its block with a path comment, or mark it '# exercise')")


# --- ollama-wiring ----------------------------------------------------------------------------

HARDCODED_OLLAMA = re.compile(r"^\s*OLLAMA_BASE_URL:\s*http://ollama:11434")
ENV_OLLAMA = re.compile(r"^OLLAMA_BASE_URL=")


def check_ollama_wiring(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    """conventions.md#ollama: compose defaults to host.docker.internal behind a profile, and
    .env.example leaves OLLAMA_BASE_URL commented (compose interpolates it from .env)."""
    for block in doc.blocks:
        if "ollama-wiring" in block.ignored:
            continue
        is_env_example = bool(block.lines) and ".env" in block.lines[0]
        for line_no, line in _code_lines(block):
            if block.lang in {"yaml", "yml"} and HARDCODED_OLLAMA.match(line):
                yield _f(doc, line_no, WARNING, "ollama-wiring",
                         "hard-coded http://ollama:11434; use ${OLLAMA_BASE_URL:-http://host.docker.internal:11434} and the ollama profile")
            if is_env_example and ENV_OLLAMA.match(line):
                yield _f(doc, line_no, WARNING, "ollama-wiring",
                         "OLLAMA_BASE_URL set in .env.example; compose would interpolate it into the container. Comment it out")


# --- verified ---------------------------------------------------------------------------------


def check_verified(doc: Doc, _: dict[str, Doc]) -> Iterator[Finding]:
    if is_module_doc(doc) and not re.search(r"Last verified:", doc.text):
        yield _f(doc, len(doc.lines), WARNING, "verified", "no 'Last verified:' line (conventions: Module readiness)")


RULES: list[Rule] = [
    check_links,
    check_sections,
    check_stale_api,
    check_not_implemented,
    check_bash_env,
    check_layout,
    check_ollama_wiring,
    check_verified,
]
