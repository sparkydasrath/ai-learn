# 01 — Python for .NET engineers

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. You already know architecture, testing, CI, APIs, debugging, and git cold, so this doc doesn't re-teach any of that. It teaches the AI-specific layer — starting here with the Python toolchain — using analogies to things you already know: NuGet ↔ pip, `dotnet` ↔ `uv`, LINQ ↔ comprehensions, `Task` ↔ `async`/`await`, DI, records ↔ dataclasses, xUnit ↔ pytest. Math stays out of this one entirely. The goal is to get you writing idiomatic, typed, tested Python and running the modern toolchain without fighting it.

Every AI project in this series is Python. Not because Python is a better language than C# — it isn't, for most of what you've built — but because the entire model/tooling ecosystem lives there. Treat Python the way you'd treat learning a new team's stack: learn the idioms, wire up the guardrails you're used to (types, lint, tests, CI), and stop fighting the parts that are just *different*, not worse.

## Where this fits

**Prerequisites:** you can already program. Docker installed. That's it.

**After this module you can:**

- Stand up a Python project with `uv`, pinned dependencies, and a real `pyproject.toml`.
- Write typed Python that a type checker (pyright/mypy) actually verifies.
- Lint and format with `ruff`, test with `pytest`, and run all of it in Docker.
- Read idiomatic Python — comprehensions, generators, context managers, `async` — without translating it in your head.
- Avoid the handful of Python gotchas that reliably bite people coming from C#.

## The toolchain, mapped to what you know

| You know (.NET) | Python equivalent | Notes |
|---|---|---|
| `dotnet` CLI | `uv` | Manages Python versions, venvs, deps, and running. The modern default. |
| NuGet / `dotnet add package` | `uv add` (PyPI) | PyPI is the package registry; `uv add` writes to `pyproject.toml`. |
| `.csproj` | `pyproject.toml` | Project metadata, deps, tool config — all in one TOML file. |
| `packages.lock.json` | `uv.lock` | Fully resolved, cross-platform lockfile. Commit it. |
| MSBuild restore | `uv sync` | Materializes the venv to match the lockfile exactly. |
| Roslyn analyzers / `dotnet format` | `ruff` | One fast tool for both lint and format. |
| Nullable reference types + compiler | pyright / mypy | *Opt-in* static typing; the runtime ignores types entirely. |
| xUnit / NUnit | pytest | Convention-based, fixture-driven. |
| `record` / DTO | `@dataclass` / pydantic model | Data-holding types with generated boilerplate. |
| NuGet.config feeds | PyPI index config | Rarely needed early; `uv` handles the default. |

The single biggest mental shift: **types in Python are checked by a separate tool, not by the runtime.** The interpreter will happily run code that pyright flags as wrong. This feels dangerous coming from C#. The discipline that replaces the compiler is: pyright in your editor, pyright in CI, and it fails the build. We set that up below.

### uv: your `dotnet` for Python

`uv` (from Astral, the `ruff` people) replaces the old tangle of `python`, `pip`, `venv`, `pyenv`, and `poetry`. It's fast (Rust) and it's what the ecosystem is converging on. The mental model:

```bash
uv init myproj            # like `dotnet new`, scaffolds pyproject.toml
uv add pydantic           # like `dotnet add package`, writes to pyproject + lock
uv add --dev pytest ruff  # dev-only deps (like a test-project reference)
uv sync                   # like restore: build the venv to match the lock
uv run pytest             # run a command inside the project's venv
uv run python -m myproj   # run your module
```

`uv run` is the important habit: it guarantees the command runs in the project's virtual environment without you manually "activating" anything. You almost never need to think about the venv directly — analogous to never hand-editing `obj/`.

### Virtual environments (the thing with no C# analog)

.NET isolates dependencies per project automatically. Python historically did not: `pip install` dropped packages into a *global* site-packages, and two projects wanting different versions of the same library would clobber each other. A **virtual environment** (`.venv/`) is a per-project sandbox of installed packages — conceptually the isolation `.csproj` + NuGet gives you for free.

With `uv` you rarely touch it directly, but know that:

- `.venv/` is generated and **git-ignored** (the .NET `.gitignore` in this repo already ignores it via the standard template? check — if not, add it).
- The lockfile + `uv sync` reproduce it exactly on any machine, including in Docker.

### pyproject.toml — the one config file

This is your `.csproj` plus analyzer config plus test config, all in TOML:

```toml
[project]
name = "textstats"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "pydantic>=2.7",
]

[dependency-groups]
dev = [
    "pytest>=8.2",
    "ruff>=0.5",
    "pyright>=1.1.370",
]

[project.scripts]
textstats = "textstats.cli:main"   # like defining a console entry point

[tool.ruff]
line-length = 100

[tool.ruff.lint]
# Sensible default rule set: pyflakes, pycodestyle, isort, bugbear, pyupgrade
select = ["E", "F", "I", "B", "UP"]

[tool.pyright]
typeCheckingMode = "strict"        # treat it like <Nullable>enable</Nullable> and then some
```

`typeCheckingMode = "strict"` is the closest you'll get to the C# compiler's protection. Turn it on from day one; it's much harder to retrofit.

## Idiomatic, typed Python for a C# developer

### Type hints — real, but advisory

Python 3.12 syntax is clean and will feel familiar:

```python
def word_count(text: str, *, ignore_case: bool = True) -> dict[str, int]:
    ...
```

Notes for a C# dev:

- `dict[str, int]` is `Dictionary<string, int>`. `list[str]` is `List<string>`. Built-in generics, no `using`.
- The `*` in the signature forces `ignore_case` to be keyword-only — the caller must write `word_count(t, ignore_case=False)`. Use it for boolean flags; it kills the "what does `True` mean here" problem.
- `X | None` is the nullable type (`str | None` ≈ `string?`). There is no separate `Nullable<T>`.
- Types are **erased at runtime.** `dict[str, int]` does not enforce anything when the code runs. pyright/mypy is what enforces it, at check time. This is the opposite of C#, and the #1 thing to internalize.

For a `Result`-style return or an enum-like set of options, use `Literal` and `Enum`:

```python
from enum import Enum
from typing import Literal

Mode = Literal["json", "text"]          # a closed set of string values

class Severity(Enum):
    LOW = "low"
    HIGH = "high"
```

### dataclasses and pydantic — records and DTOs

`@dataclass` is the direct analog of a C# `record`: value-holding type, generated `__init__`, `__eq__`, `__repr__`:

```python
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)   # frozen ≈ init-only/immutable record
class TokenStat:
    token: str
    count: int
```

`frozen=True` makes it immutable; `slots=True` is a small perf/memory win and prevents typo-ing new attributes on.

**pydantic** is what you reach for when the data comes from *outside* — a config file, an API response, env vars. It's a dataclass that *validates and coerces at runtime*, which dataclasses do not. Think of it as a DTO with `System.ComponentModel.DataAnnotations` baked in and always enforced:

```python
from pydantic import BaseModel, Field

class AppConfig(BaseModel):
    top_n: int = Field(default=20, ge=1, le=1000)   # validated range
    min_length: int = Field(default=1, ge=1)
    ignore_case: bool = True
```

Construct it from untrusted input and it either gives you a valid, typed object or raises a clear `ValidationError`. This matters enormously in AI code, where you'll be parsing model outputs and external API payloads constantly (module 06 leans on it hard).

**Rule of thumb:** `@dataclass` for internal data you construct yourself; `pydantic.BaseModel` at trust boundaries (I/O, config, API edges).

### Comprehensions and generators — this is LINQ

Comprehensions are Python's LINQ, minus the fluent method chain. Learn to read them instantly:

```python
# C#: words.Where(w => w.Length > 3).Select(w => w.ToLower())
cleaned = [w.lower() for w in words if len(w) > 3]

# dict projection — like ToDictionary
counts = {word: text.count(word) for word in set(words)}

# set comprehension
unique = {w.lower() for w in words}
```

A **generator** is `IEnumerable<T>` with `yield return` — lazy, streamed, one item at a time, never fully materialized:

```python
def read_lines(path: str) -> Iterator[str]:
    with open(path, encoding="utf-8") as f:
        for line in f:
            yield line.rstrip("\n")
```

Swap the `[...]` for `(...)` and a comprehension becomes a lazy generator expression — the difference between `.ToList()` and leaving it deferred:

```python
total = sum(len(line) for line in read_lines(path))   # streams, no big list in memory
```

You'll use generators a lot when processing large text/documents (module 07) so you don't load gigabytes into RAM.

### Context managers — the `using` statement

`with` is `using`. It guarantees cleanup (file handles, network sessions, locks) even on exceptions:

```python
with open("data.txt", encoding="utf-8") as f:   # like `using var f = ...`
    data = f.read()
# f is closed here, exception or not
```

Always pass `encoding="utf-8"` when opening text files. The default encoding is platform-dependent (a real cross-platform footgun on Windows), unlike .NET's UTF-8 default.

### async — same shape as Task, different engine

`async`/`await` looks nearly identical to C#, and the mental model (a single-threaded event loop for I/O-bound concurrency) matches `Task` on the UI thread more than it matches `Task.Run` on the thread pool:

```python
import asyncio
import httpx

async def fetch(url: str) -> str:
    async with httpx.AsyncClient() as client:
        resp = await client.get(url)
        return resp.text

async def main() -> None:
    # like Task.WhenAll
    results = await asyncio.gather(fetch(u1), fetch(u2))

asyncio.run(main())
```

Key differences that trip up C# devs:

- **No ambient thread pool for CPU work.** `async` in Python buys you I/O concurrency (many in-flight network calls), not parallel CPU. Python has the GIL; true CPU parallelism means multiple *processes*, not threads. For AI work this is fine — you're almost always I/O-bound waiting on model APIs.
- **You can't `await` in non-async code.** There's no `.Result`/`.GetAwaiter().GetResult()` habit to fall back on; `asyncio.run(...)` is the one entry point from sync code.
- Async matters when you're firing many model calls concurrently (batch eval in module 09). For a single call, plain synchronous code is fine — don't async-poison a codebase reflexively.

## The build project

**`projects/01-python-warmup/`** — a small, typed CLI that computes text statistics (word frequency, token-ish counts, longest words) from a file or stdin. It has pydantic config, pytest tests, ruff + pyright wired up, and a Dockerfile. It's deliberately not AI — the point is to get the toolchain and Python idioms under your fingers before the models show up in module 03.

### Layout

```
projects/01-python-warmup/
├── pyproject.toml
├── Dockerfile
├── README.md
├── src/
│   └── textstats/
│       ├── __init__.py
│       ├── config.py
│       ├── stats.py
│       └── cli.py
└── tests/
    └── test_stats.py
```

The `src/` layout (package under `src/`, not at the repo root) is the modern default — it stops your tests from accidentally importing the un-installed source tree and forces you to test the *installed* package, the way it'll actually be imported. It's the equivalent of not referencing another project's `bin/Debug` directly.

### `src/textstats/config.py`

```python
"""Configuration model, validated at the trust boundary."""
from pydantic import BaseModel, Field


class StatsConfig(BaseModel):
    top_n: int = Field(default=10, ge=1, le=1000)
    min_length: int = Field(default=1, ge=1)
    ignore_case: bool = True
```

### `src/textstats/stats.py`

```python
"""Pure functions: text in, stats out. No I/O, trivially testable."""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

from textstats.config import StatsConfig

_WORD_RE = re.compile(r"[A-Za-z']+")


@dataclass(frozen=True, slots=True)
class TextStats:
    total_words: int
    unique_words: int
    top_words: list[tuple[str, int]]


def tokenize(text: str, *, ignore_case: bool = True) -> list[str]:
    words = _WORD_RE.findall(text)
    if ignore_case:
        words = [w.lower() for w in words]
    return words


def compute_stats(text: str, config: StatsConfig) -> TextStats:
    words = [
        w
        for w in tokenize(text, ignore_case=config.ignore_case)
        if len(w) >= config.min_length
    ]
    counts = Counter(words)
    return TextStats(
        total_words=len(words),
        unique_words=len(counts),
        top_words=counts.most_common(config.top_n),
    )
```

`Counter` (from the batteries-included `collections`) is a `Dictionary<T, int>` purpose-built for tallying, with `.most_common(n)` doing the sort-and-take for you — very LINQ-like. Reaching for the standard library instead of hand-rolling is idiomatic.

### `src/textstats/cli.py`

```python
"""Thin I/O shell around the pure core."""
from __future__ import annotations

import argparse
import sys

from textstats.config import StatsConfig
from textstats.stats import compute_stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Text statistics tool.")
    parser.add_argument("path", nargs="?", help="File to read; omit to read stdin.")
    parser.add_argument("--top", type=int, default=10, help="How many top words.")
    parser.add_argument("--min-length", type=int, default=1)
    parser.add_argument(
        "--no-ignore-case", action="store_true", help="Treat casing as significant."
    )
    args = parser.parse_args(argv)

    text = _read_input(args.path)
    config = StatsConfig(
        top_n=args.top,
        min_length=args.min_length,
        ignore_case=not args.no_ignore_case,
    )
    stats = compute_stats(text, config)

    print(f"Total words:  {stats.total_words}")
    print(f"Unique words: {stats.unique_words}")
    print(f"Top {config.top_n}:")
    for word, count in stats.top_words:
        print(f"  {count:>6}  {word}")
    return 0


def _read_input(path: str | None) -> str:
    if path is None:
        return sys.stdin.read()
    with open(path, encoding="utf-8") as f:
        return f.read()


if __name__ == "__main__":
    raise SystemExit(main())
```

`argparse` is the standard-library arg parser — fine for learning. (The ecosystem favorites `click` and `typer` are nicer for real CLIs; we keep dependencies minimal here.) Note the pattern: **a pure core (`stats.py`) with a thin I/O shell (`cli.py`).** Same instinct as keeping business logic out of controllers — it's what makes the tests below trivial.

### `tests/test_stats.py`

```python
import pytest

from textstats.config import StatsConfig
from textstats.stats import compute_stats, tokenize


def test_tokenize_lowercases_by_default() -> None:
    assert tokenize("The THE the") == ["the", "the", "the"]


def test_tokenize_preserves_case_when_asked() -> None:
    assert tokenize("The THE", ignore_case=False) == ["The", "THE"]


def test_compute_stats_counts_and_ranks() -> None:
    stats = compute_stats("a a a b b c", StatsConfig(top_n=2))
    assert stats.total_words == 6
    assert stats.unique_words == 3
    assert stats.top_words == [("a", 3), ("b", 2)]


@pytest.mark.parametrize(
    ("text", "min_length", "expected_total"),
    [
        ("a bb ccc", 1, 3),
        ("a bb ccc", 2, 2),
        ("a bb ccc", 3, 1),
    ],
)
def test_min_length_filters(text: str, min_length: int, expected_total: int) -> None:
    stats = compute_stats(text, StatsConfig(min_length=min_length))
    assert stats.total_words == expected_total


def test_config_rejects_bad_top_n() -> None:
    with pytest.raises(ValueError):   # pydantic raises on top_n=0 (ge=1)
        StatsConfig(top_n=0)
```

pytest vs xUnit, quickly:

- **Plain functions, plain `assert`.** No `[Fact]`, no `Assert.Equal`. pytest rewrites `assert` to give rich failure output.
- `@pytest.mark.parametrize` is `[Theory]` + `[InlineData]`. It's more ergonomic — one decorator, tuples of args.
- **Fixtures** (not shown) replace constructor/`IClassFixture` setup: a function decorated `@pytest.fixture` that a test can request by naming it as a parameter. Dependency injection by parameter name.
- Test discovery is by convention: files `test_*.py`, functions `test_*`.

### Running it locally, then in Docker

Locally first:

```bash
cd projects/01-python-warmup
uv sync                       # build the venv from the lock
uv run ruff check .           # lint
uv run ruff format --check .  # formatting
uv run pyright                # type-check (this is your "compiler")
uv run pytest                 # tests
uv run textstats README.md --top 5   # run the CLI
```

Wire those five commands into CI exactly as-is and you've reproduced the quality gates you're used to in .NET.

### `Dockerfile`

```dockerfile
# Pin a specific Python; :latest drift bites you the same way in every ecosystem.
FROM python:3.12-slim

# uv ships as a tiny static binary; copy it from the official image.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Copy dependency manifests first so this layer caches unless deps change
# (same instinct as copying .csproj before the rest for `dotnet restore`).
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

# Now the source
COPY src/ ./src/
COPY tests/ ./tests/
RUN uv sync --frozen

ENTRYPOINT ["uv", "run", "textstats"]
```

`--frozen` means "fail if the lockfile is out of date" — the CI-safe equivalent of a locked restore. Splitting the two `uv sync` calls is the layer-caching trick: dependencies (slow, rarely change) get their own cached layer; source (fast, changes constantly) doesn't invalidate it.

Build and run:

```bash
docker build -t textstats projects/01-python-warmup
docker run --rm textstats --help
cat some.txt | docker run --rm -i textstats --top 5   # -i to pipe stdin in
```

Run the tests *inside* the container (this is what CI should do — test the artifact you ship, not your laptop):

```bash
docker run --rm --entrypoint uv textstats run pytest
```

### Moving to AWS

This project is **local-only** — a warm-up, nothing to deploy. But the Dockerfile you just wrote is the unit of deployment for everything later. The mental model to plant now: **a container that runs anywhere your laptop runs also runs on AWS.** The same image can become an ECS task, a Lambda (container-image Lambda), or a Fargate job with essentially no code change — you swap the entrypoint and add config from the environment. Module 12 does this for real. For now, just notice that "runs in Docker locally" is the first half of "runs in prod," and you've already done it.

## How experts think / pitfalls

- **The type checker is not optional.** Coming from C#, the temptation is to treat hints as documentation. Don't. Run pyright strict in CI and make it fail the build, or types will silently rot and you'll lose the one safety net that maps to your C# instincts.
- **Mutable default arguments are a real trap.** `def f(items: list[str] = [])` creates *one* list shared across all calls — a classic Python bug with no C# analog. Use `def f(items: list[str] | None = None)` and assign inside. pyright/ruff will warn; listen.
- **`is` vs `==`.** `==` is value equality (like `.Equals`); `is` is reference identity (like `ReferenceEquals`). Use `is` only for `None`, `True`, `False`. `if x == None` is a smell; write `if x is None`.
- **Truthiness is broad.** Empty string, empty list, empty dict, `0`, and `None` are all falsy. `if not results:` catches "empty OR None" — convenient, but be deliberate; it's not C#'s stricter boolean.
- **Imports run top-level code.** A module's top level executes on first import (like a static constructor firing). Keep side effects out of module scope; guard entry points with `if __name__ == "__main__":`.
- **Prefer the standard library.** `collections`, `itertools`, `functools`, `pathlib`, `dataclasses` cover an enormous amount. Reaching straight for a dependency is often a tell that you don't know the stdlib yet.
- **Don't over-async.** I/O concurrency, yes. But async everywhere for its own sake makes Python code harder to read and test, and buys nothing for CPU work. Add it where you fan out network calls, not reflexively.

## Checkpoint

You're ready for module 02 when you can, without looking things up:

- Scaffold a project with `uv`, add a dependency and a dev dependency, and explain what `uv.lock` and `uv sync --frozen` do.
- Explain why a type annotation does *not* prevent a runtime type error in Python, and what does.
- Write a typed function with a keyword-only argument and a `str | None` return, and know why `X | None` matters.
- Choose correctly between `@dataclass` and a pydantic `BaseModel` for a given piece of data, and say why.
- Rewrite a LINQ `Where/Select/ToDictionary` chain as a Python comprehension, and turn a list comprehension into a streaming generator.
- Explain what `with` guarantees and why you pass `encoding="utf-8"`.
- Say what `async` does and does not buy you in Python versus `Task` in C#.
- Run lint, format, type-check, and tests both locally with `uv run` and inside the Docker container.

## Going deeper

Search terms and topics when you want more depth (check current docs — tooling here moves fast):

- "uv docs" (Astral) — workspaces, tool installation, Python version management.
- "ruff rules" — the full rule set; you can dial it up considerably from the starter selection.
- "pyright strict mode configuration" and "mypy strict" — squeezing more out of the type checker.
- "pydantic v2 validators" — custom validation, `model_validator`, settings management (`pydantic-settings`) for env-driven config.
- "Python typing: Protocol, TypeVar, Generic" — structural typing (duck typing with a checker), the closest analog to interfaces and generic constraints.
- "PEP 8" and "the Python standard library tour" — idioms and what's in the box.

Next: [02 — The AI engineering landscape](02-ai-engineering-landscape.md).
