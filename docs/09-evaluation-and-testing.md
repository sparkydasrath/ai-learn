# 09 — Evaluation & testing

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point. From module 03 on, every project is built twice: Python first (the spec), then rebuilt in idiomatic C# with the same behavior.

This is the most important module in the series. If you internalize one thing from all seventeen, make it this: **quality is a number, not a feeling.** The difference between an AI engineer and a "vibe coder" is that the AI engineer can answer "did that change make it better?" with evidence. Everything before this module built systems. This module teaches you to know whether they work — and to keep knowing as models, prompts, and data drift underneath you.

## Where this fits

You've now built the things that need evaluating:

- **05** — prompts you've been tuning (by feel, if we're honest).
- **07** — a RAG pipeline with chunking and `k` knobs and no principled way to set them.
- **08** — an agent whose loop terminates but whose answers you can't grade.

Every one of those has an unanswered question hanging over it: *is it good, and did my last change help or hurt?* This module answers it. It also unblocks everything after: you can't safely deploy (12), control cost/quality trade-offs (13), or fine-tune (16) without evals. This is the hinge of the whole curriculum.

You build the harness twice: in Python on pytest, then in C# on NUnit, with module 04's client for the judge in both and `Microsoft.Extensions.AI` for the C# embeddings. Both read the same eval set and gate the same thresholds, so a regression fails `uv run pytest` and `dotnet test` alike. The cross-check also teaches something the single-language version can't: two correct harnesses scoring the same system still disagree a little, and you'll learn which metrics should match exactly and which only within tolerance.

## Why your testing instincts break

You are excellent at testing deterministic code. `Assert.Equal(expected, actual)` works because `Add(2, 2)` returns `4` every single time. That assumption is dead here.

An LLM's output is **probabilistic**. The same prompt can yield different wording each call (even at temperature 0, across model versions or minor input changes). There are *many* correct answers to "summarize this ticket" and infinitely many phrasings of each. `assertEqual` against a golden string fails on a perfectly good answer that used "fix" instead of "resolve." Your entire testing reflex — exact equality, one right answer, deterministic replay — doesn't transfer.

So you shift from **"is the output exactly this string?"** to **"is the output good enough, often enough, across a representative set of inputs?"** That reframing — from a boolean per call to a *distribution of scores over a dataset* — is the whole mental shift of this module. You're no longer testing a function; you're measuring a system's quality the way you'd measure p99 latency: a number over many samples, tracked over time, gated in CI.

## The eval mindset

Treat evaluation like a test suite you build early and run constantly:

- **Build a labeled eval set before you optimize.** A curated set of inputs with known-good outputs or graded criteria. Even 20–50 examples changes everything: now every prompt tweak is a measurable experiment, not a vibe. Build it *early* — retrofitting evals after you've been tuning by feel means you've been flying blind.
- **Track a score over time.** One number (or a small dashboard of them) per system version. Did the refactor of the RAG prompt move faithfulness from 0.82 to 0.86, or drop it to 0.71? You want to *know*.
- **Gate releases on it.** The eval is a quality gate in CI, exactly like your unit tests. Score drops below threshold → build fails → change doesn't ship. This is the single highest-leverage practice in applied AI, and it's the concrete deliverable of this module's project.
- **Make it cheap to run.** An eval you run once a month because it's painful is an eval you don't trust. Automate it so it runs on every PR.

The parallel is exact: evals are to AI systems what your test suite is to a service. Nobody senior ships a service with no tests and "I ran it once and it looked fine." Don't ship an AI system that way either.

## Types of evals

There's a spectrum from cheap-and-narrow to expensive-and-broad. Use the cheapest one that captures what you care about, and combine several.

- **Exact / rule-based.** String match, regex, JSON-schema validation, "does it contain the required field," numeric tolerance. Cheap, deterministic, unambiguous — use it wherever the correct output is constrained (classification labels, extracted fields, valid JSON). This is the closest thing to your old `assertEqual`, and you should lean on it whenever the task allows.
- **Similarity / embedding-based.** Embed the output and a reference answer, take cosine similarity (the same math from 07). Captures "means roughly the same thing" without demanding identical words. Good for summaries and free-text answers where phrasing varies but meaning shouldn't. Threshold it: similarity ≥ 0.8 passes, say — a threshold you calibrate, not guess.
- **LLM-as-judge.** Use a strong model to grade an output against a rubric ("Is this answer faithful to the provided context? Score 1–5"). Scales to subjective qualities rule-based checks can't reach — helpfulness, tone, faithfulness. It's the most flexible tool here *and the most dangerous*, so it gets its own section.
- **Human eval.** People grade outputs. The gold standard for quality and the ground truth you validate the cheaper methods against — but slow, costly, and inconsistent between raters. Use it to build and audit your eval set and to calibrate the LLM judge, not on every CI run.

The professional pattern is a **layered eval**: rule-based checks catch the objective failures for free, embedding similarity catches semantic drift, and an LLM judge grades the subjective dimensions — with periodic human spot-checks keeping all three honest.

### LLM-as-judge, and its traps

An LLM judge is powerful and it *will* mislead you if you trust it naively. Treat the judge as a system that itself needs evaluating:

- **It's biased.** Judges favor longer answers, their own model family's style, the first option in a pairwise comparison (position bias), and answers that agree with the question's framing (sycophancy). These are documented, real, and will skew your numbers.
- **It needs its own validation.** Before you trust a judge, check its grades against human labels on a sample. If the judge and your humans disagree half the time, the judge is a random number generator with good grammar. Measure their agreement; only then rely on it.
- **Pairwise beats pointwise for reliability.** "Which of A or B is better?" is more consistent than "score A from 1–10," because absolute scores drift and comparisons are more stable. Use pairwise for comparing two versions; randomize the order to fight position bias.
- **Give it a rubric, not a vibe.** A vague "rate the quality" prompt yields noise. A specific rubric with definitions and examples ("faithful = every claim is supported by the context; score 0 if any claim isn't") yields signal. The judge prompt is a prompt — engineer and version it like module 05.

The mental model: an LLM judge is an **automated code reviewer you hired without checking references.** Useful, scalable, but you verify its judgment against ground truth before you let it gate merges.

## Task-specific metrics

"Good" means different things per task. Pick metrics that match:

- **RAG (from 07):**
  - **`recall@k`** — did retrieval surface the right document in the top-k? (You built this in 07.) Measures the *retrieval* half.
  - **Faithfulness / groundedness** — is every claim in the answer supported by the retrieved context, with no invention? Usually an LLM-judge metric. This is the RAG-specific hallucination check.
  - **Answer relevance** — does the answer actually address the question (vs. being true-but-off-topic)?
  - Split retrieval metrics from generation metrics — when RAG is wrong, these tell you *which half* broke.
- **Classification:** **precision, recall, F1** per class, and a confusion matrix. You know these; they apply unchanged to an LLM classifier.
- **Extraction:** **field-level accuracy** — of the fields you asked for, what fraction were extracted correctly? Per-field, so you see *which* field the model fumbles.
- **Summarization / free text:** embedding similarity to a reference plus an LLM-judge rubric (faithfulness, coverage, conciseness).

The habit: for any system, before you build it, write down *how you'll measure it*. If you can't name the metric, you don't understand the task well enough to build it.

## Building eval datasets

Your eval is only as good as its data. Sources, in rough order of value:

- **Real usage / logs.** The best examples come from real inputs users actually send. Mine your logs (11 makes this systematic), label the outputs, and you have an eval set that reflects reality instead of your imagination.
- **Synthetic.** Have a model generate plausible inputs (and candidate answers for humans to verify) to bootstrap coverage before you have traffic. Cheap to start, but validate — synthetic data has its own blind spots.
- **Edge cases.** Deliberately include the hard ones: ambiguous questions, out-of-scope queries (the RAG "I don't know" case from 07), adversarial inputs, empty inputs, very long inputs.
- **Regression cases from bugs.** *Every production failure becomes a permanent eval example.* This is exactly your "write a failing test for the bug, then fix it" discipline. The eval set grows monotonically with every incident, and the same bug can never silently return.

Curate deliberately: a small, high-quality, well-labeled set beats a huge noisy one. Version it in git alongside the code — it's a first-class artifact, and diffs to it are meaningful history.

## Offline vs online, and guarding against overfitting

- **Offline eval** — run against your labeled set before shipping. Fast, cheap, deterministic-ish, gates the PR. This is 90% of your day-to-day.
- **Online eval** — measure on live traffic after shipping: A/B tests (route some traffic to the new version, compare outcomes), **canary** releases (a small slice first, watch the metrics, then ramp), and implicit signals (thumbs-up, retries, task completion). Real users hit cases your eval set never imagined.
- **The overfitting trap.** If you tune relentlessly against the *same* eval set, you overfit to it — the score climbs while real quality doesn't, because you've been teaching to the test. This is the LLM version of leaking your test set into training. Defenses: keep a **held-out set** you *don't* tune against and check only occasionally, refresh the eval set with new real cases regularly, and be suspicious when your eval score and your users' happiness diverge.

## Cost and latency are first-class metrics

Quality is not the only number. A system that's 2% more accurate for 5× the cost and 3× the latency is usually a *worse* engineering choice. Track **tokens/cost per request** and **latency (p50/p95)** in the same scorecard as quality, so every comparison is quality *and* cost *and* speed — never quality alone. (This module's scorecard carries p50 latency and the judge's tokens; the system's own token bill comes from its logs, as below.) This is the accounting habit from modules 03/04 promoted to a release gate. The best-scoring model is frequently not the one you ship.

## The build project

**`projects/09-eval-harness/`** is a reusable eval harness, built in Python (pytest) and then in C# (NUnit). It runs a system over a labeled set, scores every answer, writes a **scorecard**, and **fails the build when the score drops below a threshold**. Both versions:

1. Load the same labeled eval set from the shared `fixtures/`.
2. Run a system under test: module 07's RAG service at two retrieval depths (`v1` asks `/ask` with `k=1`, `v2` with `k=4`), or a file of frozen outputs.
3. Score each answer with the same four metrics under the same names (`exact_match`, `contains_all`, `similarity`, `judge`), plus p50 latency and the judge's token count.
4. Gate on the same thresholds, as a test that fails: `uv run pytest -m eval` and `dotnet test --settings eval.runsettings`.
5. Offer a `compare` command that prints a scorecard per version and writes it as JSON.
6. Label the R track's reviews with a rubric judge, so you can measure the judge against yourself ([below](#labelled-reviews-as-an-eval-set)).

### Three parts, three seams

The harness has three moving parts, and each is picked by an environment variable with the same name in both languages. Each has an offline choice, which is what the tests and the exact cross-check run on.

| Part | Env vars | Default | Offline |
|---|---|---|---|
| The judge | `LLM_BACKEND` and `JUDGE_MODEL`, plus 04's `OLLAMA_*` / `LLM_*` | `ollama`; `JUDGE_MODEL` required | `stub`, with `LLM_STUB_REPLY` as the verdict |
| Similarity | `EMBED_BACKEND` | `sentence-transformers` (Python) / `ollama` (C#), both all-MiniLM-L6-v2 | `hashing`, module 07's embedder |
| The system under test | `SYSTEM_VERSION`, `RAG_URL` | `v2`, at `http://localhost:8000` | `frozen`; the tests fake 07's HTTP instead |

The judge is the measuring instrument, so it gets one rule: **it's built once, from its own configuration, before any system, and nothing about the system can change it.** It goes through module 04's client like every model call, with `JUDGE_MODEL` standing in for the backend's model variable (`OLLAMA_MODEL` or `LLM_MODEL`). That matters in practice: module 10 sets `OLLAMA_MODEL` to the quant under test in the same shell, and a judge that read it would change with the system, so you'd be measuring the judge. Without `JUDGE_MODEL`, a real backend fails at startup instead of guessing. Pinned isn't the same as independent, though: with `llama3.2` judging answers that `llama3.2` wrote, expect the self-preference bias described above. A different, ideally stronger, judge model is better when you have one.

The system under test is module 07, reached over HTTP at `RAG_URL` (Python 07 publishes 8000, C# 07 8001). **For a live run, 07 must be running with its corpus ingested.** With `VECTOR_STORE=memory` its index is empty after every restart, and an empty index answers "I don't know" to everything, which shows up as a bad score, not an error. The eval set's questions come from 07's corpus, so that's the service to point it at.

### Layout

```
projects/09-eval-harness/
├── fixtures/                       # committed; shared by both languages (FIXTURES_DIR)
│   ├── qa_eval.jsonl               # THE eval set: input → reference (+ must_include)
│   └── qa_outputs.jsonl            # frozen outputs, for the cross-check
├── python/
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── pyrightconfig.json          # from the bootstrap script
│   ├── Dockerfile                  # build context: projects/
│   ├── Dockerfile.dockerignore     # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example
│   ├── README.md
│   ├── evalkit/
│   │   ├── __init__.py
│   │   ├── dataset.py              # load and validate the set; FIXTURES_DIR, EVAL_DATASET, EVAL_OUT_DIR
│   │   ├── embeddings.py           # sentence-transformers | hashing
│   │   ├── metrics.py              # exact_match, contains_all, embedding_similarity
│   │   ├── judge.py                # LLM-as-judge, and the judge's client from JUDGE_MODEL
│   │   ├── runner.py               # run a system over the set → per-example scores
│   │   ├── scorecard.py            # aggregate, render, gate, JSON
│   │   └── rubric.py               # the R track's review labels as an eval set
│   ├── systems/
│   │   ├── __init__.py
│   │   ├── qa_system.py            # v1 / v2 over module 07's /ask
│   │   └── frozen.py               # replays fixtures/qa_outputs.jsonl
│   ├── compare.py                  # score versions with one judge
│   ├── rubric_judge.py             # label reviews, write {id, label} lines
│   ├── crosscheck.py               # diff two scorecard JSONs
│   └── tests/
│       ├── fakes.py                # FakeEmbedder, fake_rag (httpx.MockTransport)
│       ├── test_metrics.py         # unit tests: no model, no network
│       ├── test_judge.py
│       ├── test_systems.py
│       ├── test_gate.py            # the whole pipeline, offline
│       ├── test_rubric.py
│       └── test_eval_gate.py       # @pytest.mark.eval: the real gate
└── csharp/
    ├── EvalHarness.slnx
    ├── Directory.Build.props
    ├── unit.runsettings                 # the default: everything but the Eval category
    ├── eval.runsettings                 # opt in: only the Eval category
    ├── Dockerfile                       # build context: projects/
    ├── Dockerfile.dockerignore          # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   ├── EvalHarness/                 # class library: what a later module would reference
    │   │   ├── EvalHarness.csproj
    │   │   ├── Dataset.cs               # EvalExample, the loader, EvalSettings
    │   │   ├── Embeddings.cs            # ollama | hashing
    │   │   ├── Metrics.cs
    │   │   ├── LlmJudge.cs              # judge on IChatClient with structured output
    │   │   ├── Runner.cs                # ExampleResult, RunResult, EvalRunner
    │   │   ├── Scorecard.cs             # thresholds, render, gate, JSON
    │   │   ├── QaSystems.cs             # IQaSystem: v1, v2, frozen
    │   │   ├── Rubric.cs
    │   │   └── EvalServices.cs          # AddEvalHarness(): one composition root, and the judge's config
    │   └── EvalHarness.Cli/             # console app: compare, rubric
    │       ├── EvalHarness.Cli.csproj
    │       └── Program.cs
    └── tests/
        └── EvalHarness.Tests/
            ├── EvalHarness.Tests.csproj # NUnit; points at unit.runsettings
            ├── Fakes.cs                 # FakeEmbeddingGenerator, FakeRag (HttpMessageHandler), TestHost
            ├── MetricsTests.cs
            ├── JudgeTests.cs
            ├── QaSystemTests.cs
            ├── GateTests.cs
            ├── RubricTests.cs
            └── EvalGateTests.cs         # [Category("Eval")]: the real gate
```

## Python implementation

Work in `projects/09-eval-harness/python/`. It's a [service-shaped](conventions.md#python-project-shapes) project: `evalkit/` and `systems/` sit at the `python/` root and are never installed. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 09-eval-harness -Mode app
cd projects/09-eval-harness/python
Remove-Item -Recurse app; Remove-Item tests/test_smoke.py   # this project's code lives in evalkit/ and systems/
mkdir evalkit, systems
New-Item evalkit/__init__.py, systems/__init__.py           # empty: they make the folders packages
uv add --editable ../../04-llm-client/python
uv add httpx numpy sentence-transformers torch
uv add --dev pytest-asyncio
```

Then make `pyproject.toml` match the one below. `torch` is listed directly so the CPU-only wheel index applies ([conventions](conventions.md#pytorch-wheels)). `asyncio_mode = "auto"` runs `async def` tests without a decorator each, because 04's client is async. The `addopts` line is what keeps the eval gate out of a plain `uv run pytest`; `-m eval` on the command line replaces it. Also point the scaffold's `pyrightconfig.json` `include` list at `evalkit`, `systems`, `tests` and the three scripts. There's no `[build-system]`: this is a service-shaped project that runs from its own folder. Module 17 reuses `evalkit` as a library and adds one then ([17, Step 0](17-capstone-and-portfolio.md#step-0-make-09s-evalkit-a-package)).

```toml
# projects/09-eval-harness/python/pyproject.toml
[project]
name = "eval-harness"
version = "0.1.0"
description = "Eval harness: score a system over a labeled set, gate CI on the scores"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.28.1",
    "llm-client",
    "numpy>=2.5.3",
    "sentence-transformers>=6.1.0",
    "torch>=2.14.1",
]

[tool.pytest.ini_options]
pythonpath = ["."]
asyncio_mode = "auto"
markers = ["eval: scores the real system with the real judge (slow, needs RAG_URL and a model)"]
addopts = "-m 'not eval'"

[tool.uv.sources]
llm-client = { path = "../../04-llm-client/python", editable = true }
torch = [{ index = "pytorch-cpu" }]

[dependency-groups]
dev = [
    "pytest>=9.1.1",
    "pytest-asyncio>=1.4.0",
]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true
```

### The eval set

`fixtures/qa_eval.jsonl` at the project root, one example per line. The questions come from module 07's corpus:

```jsonl
{"id": "q1", "input": "How do I roll back a deploy?", "reference": "Run deploy --revert with the SHA of the last good release.", "must_include": ["revert"]}
{"id": "q2", "input": "When is a rollback still safe?", "reference": "Rollbacks are safe within 24 hours of a release.", "must_include": ["24 hours"]}
{"id": "q3", "input": "How quickly do I have to acknowledge a page?", "reference": "Acknowledge a page within 15 minutes.", "must_include": ["15 minutes"]}
{"id": "q4", "input": "Who has to approve a refund that isn't a duplicate charge?", "reference": "A billing lead has to approve it.", "must_include": ["billing lead"]}
{"id": "q5", "input": "For how long can customers download past invoices?", "reference": "Customers can download past invoices for up to seven years.", "must_include": ["seven years"]}
{"id": "q6", "input": "What is the airspeed of an unladen swallow?", "reference": "I don't know based on the provided documents.", "must_include": ["don't know"]}
```

Note `q6`: an out-of-scope question whose *correct* answer is 07's exact "I don't know" sentence. Your eval must reward abstention, or you're training your system to bluff.

Write references as **answers**, in the register a good answer would use, not as terse facts. This is a calibration result, not style. With all-MiniLM-L6-v2, the reference "Within 15 minutes." scored 0.35 against the correct answer "Acknowledge a page within 15 minutes [S1].", far below the 0.70 threshold. Rewritten as "Acknowledge a page within 15 minutes.", it scores 0.94, while the wrong frozen answer below scores 0.19. A similarity threshold only means something once right and wrong answers land on opposite sides of it.

`fixtures/qa_outputs.jsonl` holds one recorded answer per question, for the cross-check. `q4` is deliberately a retrieval miss: the answer cites the duplicate-charge refund chunk, not the approval rule.

```jsonl
{"id": "q1", "input": "How do I roll back a deploy?", "output": "Run deploy --revert <sha> with the SHA of the last good release [S1]."}
{"id": "q2", "input": "When is a rollback still safe?", "output": "Rollbacks are safe within 24 hours of a release [S1]."}
{"id": "q3", "input": "How quickly do I have to acknowledge a page?", "output": "Acknowledge a page within 15 minutes [S1]."}
{"id": "q4", "input": "Who has to approve a refund that isn't a duplicate charge?", "output": "Refunds are issued automatically within five business days [S2]."}
{"id": "q5", "input": "For how long can customers download past invoices?", "output": "Customers can download past invoices for up to seven years [S1]."}
{"id": "q6", "input": "What is the airspeed of an unladen swallow?", "output": "I don't know based on the provided documents."}
```

### Loading it

```python
# evalkit/dataset.py
from __future__ import annotations

import json
import os
from pathlib import Path

REQUIRED = ("id", "input", "reference")


def fixtures_dir() -> Path:
    """The shared fixtures/ folder: ../fixtures from python/; the Dockerfile sets the container path."""
    return Path(os.environ.get("FIXTURES_DIR", "../fixtures"))


def dataset_path() -> Path:
    """EVAL_DATASET wins (another set, e.g. a held-out one); otherwise the shared eval set."""
    return Path(os.environ.get("EVAL_DATASET") or fixtures_dir() / "qa_eval.jsonl")


def out_dir() -> Path:
    """Where scorecards go. outputs/ is git-ignored: run results are artifacts, not source."""
    return Path(os.environ.get("EVAL_OUT_DIR", "outputs"))


def read_jsonl(path: str | Path) -> list[dict]:
    """One JSON object per line, blank lines skipped."""
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def load(path: str | Path) -> list[dict]:
    """The labeled set. Fails loudly on a row without id/input/reference or on a repeated id:
    a silently skipped or doubled example changes every average."""
    rows = read_jsonl(path)
    seen: set[str] = set()
    for i, row in enumerate(rows, start=1):
        missing = [k for k in REQUIRED if not row.get(k)]
        if missing:
            raise ValueError(f"{path}: row {i} is missing {', '.join(missing)}")
        if row["id"] in seen:
            raise ValueError(f"{path}: duplicate id {row['id']!r}")
        seen.add(row["id"])
    return rows
```

### Metrics

The embedder is a seam, like module 07's. `hashing` is 07's embedder copied, not imported: 07 is a service, never installed, so there's nothing to import.

```python
# evalkit/embeddings.py
from __future__ import annotations

import os
import re
from collections.abc import Sequence
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from sentence_transformers import SentenceTransformer

EMBED_BACKENDS = ("sentence-transformers", "hashing")


class Embedder(Protocol):
    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...


class SentenceTransformerEmbedder:
    """EMBED_BACKEND=sentence-transformers: all-MiniLM-L6-v2 in-process, as in module 07.
    Loaded on first use, because importing torch and loading the model takes seconds."""

    def __init__(self, model_name: str) -> None:
        self._name = model_name
        self._model: SentenceTransformer | None = None

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(self._name)   # downloads once, into the HF cache
        return self._model.encode(list(texts), convert_to_numpy=True).tolist()


class HashingEmbedder:
    """EMBED_BACKEND=hashing: module 07's offline embedder, copied (07 is a service, not a
    library). Each word is hashed into one of `dimensions` buckets: lexical, not semantic,
    but deterministic, so the stub cross-check can be exact."""

    def __init__(self, dimensions: int = 256) -> None:
        self._dims = dimensions

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [self._one(t) for t in texts]

    def _one(self, text: str) -> list[float]:
        v = [0.0] * self._dims
        for word in re.findall(r"[a-z0-9]+", text.lower()):
            v[fnv1a(word) % self._dims] += 1.0
        return v


def fnv1a(word: str) -> int:
    """32-bit FNV-1a over the UTF-8 bytes: the same number in every process, and in C#."""
    h = 0x811C9DC5
    for b in word.encode("utf-8"):
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def embedder_from_env() -> Embedder:
    """Pick the similarity embedder from EMBED_BACKEND (default: the real model)."""
    backend = os.environ.get("EMBED_BACKEND", "sentence-transformers")
    if backend == "sentence-transformers":
        return SentenceTransformerEmbedder(
            os.environ.get("EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2"))
    if backend == "hashing":
        return HashingEmbedder()
    raise ValueError(f"unknown EMBED_BACKEND {backend!r} (expected one of: {' | '.join(EMBED_BACKENDS)})")
```

```python
# evalkit/metrics.py
from __future__ import annotations

from collections.abc import Sequence

import numpy as np

from evalkit.embeddings import Embedder


def exact_match(output: str, reference: str) -> float:
    """1.0 if the strings match after trimming and lower-casing, else 0.0. The cheapest signal."""
    return float(output.strip().lower() == reference.strip().lower())


def contains_all(output: str, required: Sequence[str]) -> float:
    """Rule-based: the fraction of required substrings present, ignoring case. Objective and free."""
    if not required:
        return 1.0
    hits = sum(1 for r in required if r.lower() in output.lower())
    return hits / len(required)


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    """Cosine similarity (the 07 math). 0.0 when either vector is all zeros, e.g. an empty
    answer: it isn't similar to anything, and a NaN would poison the mean."""
    va, vb = np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)
    norms = float(np.linalg.norm(va) * np.linalg.norm(vb))
    return float(va @ vb / norms) if norms else 0.0


def embedding_similarity(embedder: Embedder, output: str, reference: str) -> float:
    """Cosine similarity of the output and reference embeddings."""
    a, b = embedder.embed([output, reference])
    return cosine(a, b)
```

### The judge

```python
# evalkit/judge.py
from __future__ import annotations

import json
import os
from dataclasses import dataclass

from llm_client.factory import client_from_env
from llm_client.types import LlmClient, Message

# Versioned like any prompt (module 05). C#'s LlmJudge.BuildPrompt is the same text, byte for byte.
JUDGE_PROMPT = """You are grading a candidate answer against a reference answer.
Question: {question}
Reference answer: {reference}
Candidate answer: {output}

Score 1-5: 5 = says what the reference says, 3 = partly right or missing a key detail,
1 = wrong, off-topic, or answers when the reference says the documents don't know.
Respond with ONLY a JSON object: {{"score": <int 1-5>, "reason": "<one sentence>"}}"""

# The variable that names the model, per backend, in module 04's factory (bedrock arrives in module 12).
MODEL_VARS = {"ollama": "OLLAMA_MODEL", "hosted": "LLM_MODEL", "bedrock": "BEDROCK_MODEL_ID"}


@dataclass(frozen=True)
class Verdict:
    score: float   # 0-1, or 0.0 when the reply isn't a valid verdict
    valid: bool    # False: the judge broke its contract (not JSON, no score, out of range)
    tokens: int    # prompt + completion tokens of this judge call: the eval's own cost


def parse_score(raw: str) -> int | None:
    """The 1-5 score in the judge's reply, or None if the reply isn't a valid verdict."""
    try:
        score = json.loads(raw)["score"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None
    # bool is an int in Python, and 4.5 isn't a score: only a real int from 1 to 5 counts.
    if type(score) is not int or not 1 <= score <= 5:
        return None
    return score


class LlmJudge:
    """LLM-as-judge, normalized to 0-1. VALIDATE it against human labels before trusting it."""

    def __init__(self, client: LlmClient) -> None:
        self._client = client

    async def score(self, question: str, output: str, reference: str) -> Verdict:
        prompt = JUDGE_PROMPT.format(question=question, reference=reference, output=output)
        reply = await self._client.complete([Message("user", prompt)])
        tokens = reply.usage.prompt_tokens + reply.usage.completion_tokens
        score = parse_score(reply.text)
        if score is None:
            # Scored 0, so a broken judge fails the gate instead of passing it, and counted,
            # so the scorecard says "the judge broke", not "the answers got worse".
            return Verdict(0.0, False, tokens)
        return Verdict((score - 1) / 4, True, tokens)   # map 1..5 to 0..1


def judge_client_from_env() -> LlmClient:
    """The judge: module 04's client, from the usual LLM_BACKEND / OLLAMA_* / LLM_* variables,
    but with JUDGE_MODEL as the model. Build it once per run, never from the system under test,
    so changing the system (or OLLAMA_MODEL, in module 10's quant runs) can't move the ruler.
    It also runs at temperature 0: a judge that samples is a noisy ruler."""
    backend = os.environ.get("LLM_BACKEND", "ollama")
    var = MODEL_VARS.get(backend)
    if var is None:
        return client_from_env()   # stub (LLM_STUB_REPLY scripts the verdict), or 04's loud error
    model = os.environ.get("JUDGE_MODEL")
    if not model:
        raise ValueError(
            f"JUDGE_MODEL is required with LLM_BACKEND={backend}: pin the judge apart from the system")
    # 04's factory reads the environment: lend it JUDGE_MODEL and temperature 0 for one call.
    lent = {var: model, "LLM_TEMPERATURE": "0"}
    saved = {name: os.environ.get(name) for name in lent}
    os.environ.update(lent)
    try:
        return client_from_env()
    finally:
        for name, value in saved.items():
            if value is None:
                del os.environ[name]
            else:
                os.environ[name] = value
```

Three decisions in there are about measurement, not code:

- **The rubric grades correctness against the reference, given the question.** It can't grade *faithfulness* (every claim supported by the retrieved chunks), because 07's `/ask` returns citations, not the chunk text. Don't call a metric faithfulness unless the judge sees the context.
- **A reply that isn't a valid verdict scores 0 and is counted.** Zero means a broken judge fails the gate rather than waving changes through. The count, `judge_invalid`, means the scorecard tells you the judge broke rather than letting you blame the answers. `parse_score` is strict on purpose: `4.5`, `true` and `9` aren't scores.
- **Temperature 0.** The judge borrows `LLM_TEMPERATURE=0` along with `JUDGE_MODEL`, and the C# judge asks for `Temperature = 0` per call, so neither samples. A sampling judge is a noisy ruler. Even at 0 a judge isn't perfectly repeatable (batching and hardware nudge the numbers), so run the same eval twice and look at the spread before you trust a difference smaller than it.

### Runner and scorecard

```python
# evalkit/runner.py
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Protocol

from evalkit.embeddings import Embedder
from evalkit.judge import LlmJudge
from evalkit.metrics import contains_all, embedding_similarity, exact_match


class QaSystem(Protocol):
    """The system under test: question in, answer out."""

    version: str

    async def answer(self, question: str) -> str: ...


@dataclass
class ExampleResult:
    id: str
    output: str
    latency_ms: float
    scores: dict[str, float]
    judge_tokens: int
    judge_valid: bool


@dataclass
class RunResult:
    per_example: list[ExampleResult] = field(default_factory=list)

    def aggregate(self) -> dict[str, float]:
        """The mean of each metric over the set, plus p50 latency. An empty run gives {}, which fails the gate."""
        if not self.per_example:
            return {}
        n = len(self.per_example)
        agg = {k: sum(r.scores[k] for r in self.per_example) / n for k in self.per_example[0].scores}
        # The upper median: element n//2 of the sorted list. C# takes the same element.
        agg["latency_ms_p50"] = sorted(r.latency_ms for r in self.per_example)[n // 2]
        return agg

    @property
    def judge_tokens(self) -> int:
        return sum(r.judge_tokens for r in self.per_example)

    @property
    def judge_invalid(self) -> int:
        return sum(not r.judge_valid for r in self.per_example)


async def run(dataset: list[dict], system: QaSystem, judge: LlmJudge, embedder: Embedder) -> RunResult:
    """Run the system over the dataset and score each answer, one at a time: concurrent calls
    would distort the latency numbers. Latency is the system's; tokens are the judge's (07's
    /ask doesn't report its own usage). A system error stops the run: that's a broken run,
    not a low score."""
    result = RunResult()
    for ex in dataset:
        start = time.perf_counter()
        output = await system.answer(ex["input"])
        latency_ms = (time.perf_counter() - start) * 1000
        verdict = await judge.score(ex["input"], output, ex["reference"])
        scores = {
            "exact_match": exact_match(output, ex["reference"]),
            "contains_all": contains_all(output, ex.get("must_include", [])),
            "similarity": embedding_similarity(embedder, output, ex["reference"]),
            "judge": verdict.score,
        }
        result.per_example.append(
            ExampleResult(ex["id"], output, latency_ms, scores, verdict.tokens, verdict.valid))
    return result
```

```python
# evalkit/scorecard.py
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from evalkit.runner import RunResult

# The gate, shared with C#'s Scorecard.Thresholds. similarity's 0.70 is calibrated for
# all-MiniLM-L6-v2: a threshold belongs to its instrument, and the hashing embedder isn't it.
THRESHOLDS = {"contains_all": 0.80, "similarity": 0.70, "judge": 0.75}


def render(run: RunResult, label: str) -> str:
    lines = [f"=== Scorecard: {label} ===", f"examples: {len(run.per_example)}"]
    lines += [f"  {k:20s} {v:.3f}" for k, v in run.aggregate().items()]
    lines += [f"  {'judge_tokens':20s} {run.judge_tokens}", f"  {'judge_invalid':20s} {run.judge_invalid}"]
    return "\n".join(lines)


def passes_gate(run: RunResult, thresholds: dict[str, float] = THRESHOLDS) -> tuple[bool, list[str]]:
    """Return (ok, failures). A metric below its threshold, or missing, fails the gate."""
    agg = run.aggregate()
    failures = [
        f"{k}={agg.get(k, 0.0):.3f} < {v:.3f}" for k, v in thresholds.items() if agg.get(k, 0.0) < v
    ]
    return (not failures, failures)


def write_json(run: RunResult, label: str, directory: str | Path) -> Path:
    """The scorecard as JSON, for CI to archive and the cross-check to diff. Same shape as C#'s."""
    Path(directory).mkdir(parents=True, exist_ok=True)
    path = Path(directory) / f"scorecard-{label}.json"
    doc = {
        "label": label,
        "examples": len(run.per_example),
        "aggregate": run.aggregate(),
        "judge_tokens": run.judge_tokens,
        "judge_invalid": run.judge_invalid,
        "per_example": [asdict(r) for r in run.per_example],
    }
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    return path
```

The scorecard reports the judge's tokens, the eval's own cost. The system's cost isn't there: 07's `/ask` doesn't return its usage, so the place to measure it is 07's own `llm_call` log lines (and, from module 11, its traces).

### The systems under test

`v1` and `v2` are the same 07 service at two retrieval depths, a real A/B you'd run. Whatever `v1` and `v2` mean here, the C# `QaSystemFactory` must mean exactly the same, or a Python-vs-C# comparison compares different systems.

```python
# systems/qa_system.py
from __future__ import annotations

import os

import httpx

from evalkit.runner import QaSystem
from systems.frozen import FrozenSystem

# What each version means: chunks retrieved per question. C#'s QaSystems.Versions must say
# exactly the same, or a Python-vs-C# comparison of v1 and v2 compares different systems.
VERSIONS = {"v1": 1, "v2": 4}


class RagQaSystem:
    """Module 07's POST /ask, either language (same contract), at a fixed k."""

    def __init__(self, version: str, k: int, http: httpx.AsyncClient) -> None:
        self.version = version
        self._k = k
        self._http = http

    async def answer(self, question: str) -> str:
        r = await self._http.post("/ask", json={"question": question, "k": self._k})
        r.raise_for_status()   # a 4xx or 5xx is a broken run, not a low score
        return r.json()["answer"]


def build_system(version: str, transport: httpx.AsyncBaseTransport | None = None) -> QaSystem:
    """v1 | v2 over 07 at RAG_URL, or the frozen outputs. Tests pass a MockTransport."""
    if version == "frozen":
        return FrozenSystem.load()
    if version not in VERSIONS:
        raise ValueError(f"unknown SYSTEM_VERSION {version!r} (expected one of: v1 | v2 | frozen)")
    # Python 07 publishes 8000 (the default), C# 07 8001. 07 must be running, with its corpus ingested.
    http = httpx.AsyncClient(
        base_url=os.environ.get("RAG_URL", "http://localhost:8000"), timeout=120.0, transport=transport)
    return RagQaSystem(version, VERSIONS[version], http)
```

```python
# systems/frozen.py
from __future__ import annotations

from pathlib import Path

from evalkit.dataset import fixtures_dir, read_jsonl


class FrozenSystem:
    """Replays recorded outputs, so you score the harness, not the system. For the cross-check."""

    version = "frozen"

    def __init__(self, outputs_by_input: dict[str, str]) -> None:
        self._outputs = outputs_by_input

    async def answer(self, question: str) -> str:
        try:
            return self._outputs[question]
        except KeyError:
            raise KeyError(f"no frozen output for {question!r}") from None

    @classmethod
    def load(cls, path: Path | None = None) -> FrozenSystem:
        rows = read_jsonl(path or fixtures_dir() / "qa_outputs.jsonl")
        return cls({r["input"]: r["output"] for r in rows})
```

### Comparing versions

```python
# compare.py
"""Score versions of the system with ONE judge: uv run python compare.py [versions...] (default: v1 v2)"""
from __future__ import annotations

import asyncio
import sys

from evalkit.dataset import dataset_path, load, out_dir
from evalkit.embeddings import embedder_from_env
from evalkit.judge import LlmJudge, judge_client_from_env
from evalkit.runner import run
from evalkit.scorecard import passes_gate, render, write_json
from systems.qa_system import build_system


async def main(versions: list[str]) -> None:
    dataset = load(dataset_path())
    judge = LlmJudge(judge_client_from_env())   # built once, before any system: the fixed ruler
    embedder = embedder_from_env()
    for version in versions:
        result = await run(dataset, build_system(version), judge, embedder)
        ok, failures = passes_gate(result)
        print(render(result, version))
        print(f"  gate: {'PASS' if ok else 'FAIL ' + '; '.join(failures)}")
        print(f"  scorecard: {write_json(result, version, out_dir())}")
        print()
    # Read the scorecards side by side: did v2 beat v1, and at what latency? Decide on numbers.


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or ["v1", "v2"]))
```

### Tests

The default `uv run pytest` runs everything except the gate, with no model and no network: 07's HTTP is faked under `httpx` with a `MockTransport`, the judge is 04's `StubClient` with scripted verdicts, and similarity uses fixed vectors or the hashing embedder.

```python
# tests/fakes.py
from __future__ import annotations

import json
from collections.abc import Sequence

import httpx


class FakeEmbedder:
    """Maps known strings to fixed vectors, so similarity tests are exact and offline."""

    def __init__(self, vectors: dict[str, list[float]]) -> None:
        self._vectors = vectors

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [self._vectors[t] for t in texts]


def fake_rag(answers: dict[str, str], seen: list[dict] | None = None, status: int = 200) -> httpx.MockTransport:
    """Module 07's /ask, faked under the HTTP client: answers by question, records each request body."""

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        if seen is not None:
            seen.append({"path": request.url.path, **body})
        if status != 200:
            return httpx.Response(status, json={"detail": "boom"})
        return httpx.Response(200, json={"answer": answers[body["question"]], "citations": []})

    return httpx.MockTransport(handler)
```

The metrics are code, so they get ordinary unit tests, one for one with C#'s `MetricsTests`:

```python
# tests/test_metrics.py
"""The metrics are code, so they get ordinary unit tests: no model, no network. Mirrors C#'s MetricsTests."""
import math

import pytest
from llm_client.stub import StubClient

from evalkit.judge import LlmJudge
from evalkit.metrics import contains_all, embedding_similarity, exact_match
from evalkit.runner import ExampleResult, RunResult
from evalkit.scorecard import passes_gate
from tests.fakes import FakeEmbedder


@pytest.mark.parametrize("output, reference, expected", [
    ("Within 24 hours.", "within 24 hours.", 1.0),
    ("  Within 24 hours.  ", "Within 24 hours.", 1.0),
    ("Within a day.", "Within 24 hours.", 0.0),
])
def test_exact_match_normalizes_case_and_whitespace(output, reference, expected):
    assert exact_match(output, reference) == expected


@pytest.mark.parametrize("output, required, expected", [
    ("Run deploy --REVERT now", ["revert"], 1.0),
    ("Roll it back", ["revert", "sha"], 0.0),
    ("revert to the old sha", ["revert", "24"], 0.5),
    ("anything", [], 1.0),
])
def test_contains_all_is_the_fraction_present(output, required, expected):
    assert contains_all(output, required) == expected


def test_similarity_is_cosine_of_the_embeddings():
    embedder = FakeEmbedder({"a": [1.0, 0.0], "b": [1.0, 1.0]})
    assert embedding_similarity(embedder, "a", "b") == pytest.approx(math.sqrt(0.5), abs=1e-6)


def test_similarity_of_an_empty_vector_is_zero_not_nan():
    embedder = FakeEmbedder({"": [0.0, 0.0], "b": [1.0, 1.0]})
    assert embedding_similarity(embedder, "", "b") == 0.0


@pytest.mark.parametrize("judge_reply, expected, valid", [
    ('{"score": 5, "reason": "correct"}', 1.0, True),
    ('{"score": 3, "reason": "partly"}', 0.5, True),
    ('{"score": 9, "reason": "very good"}', 0.0, False),   # out of range: rejected
    ('{"score": 4.5, "reason": "between"}', 0.0, False),   # not an int
    ('{"reason": "no score"}', 0.0, False),
    ("I'd say about a 4.", 0.0, False),                     # not JSON
])
async def test_judge_maps_score_to_0_1(judge_reply, expected, valid):
    verdict = await LlmJudge(StubClient([judge_reply])).score("question", "output", "reference")
    assert (verdict.score, verdict.valid) == (expected, valid)


def _run(*judge: float) -> RunResult:
    """One example per judge score, with latencies 10, 20, 30, ..."""
    return RunResult([ExampleResult(f"q{i}", "x", 10.0 * i, {"judge": j}, 0, True) for i, j in enumerate(judge, 1)])


def test_gate_fails_when_a_metric_is_below_threshold():
    ok, failures = passes_gate(_run(0.5), {"judge": 0.75})
    assert not ok
    assert failures == ["judge=0.500 < 0.750"]


def test_gate_passes_at_the_threshold():
    ok, _ = passes_gate(_run(0.5, 1.0), {"judge": 0.75})
    assert ok


def test_an_empty_run_fails_the_gate():
    ok, failures = passes_gate(RunResult(), {"judge": 0.75})
    assert not ok
    assert failures == ["judge=0.000 < 0.750"]


def test_p50_is_the_upper_median():
    # Latencies 10, 20, 30, 40: element 4 // 2.
    assert _run(1.0, 1.0, 1.0, 1.0).aggregate()["latency_ms_p50"] == 30.0
```

```python
# tests/test_judge.py
"""The judge is built once, from JUDGE_MODEL, never from the system's model variables."""
import os

import pytest
from llm_client.stub import StubClient

from evalkit.judge import JUDGE_PROMPT, LlmJudge, judge_client_from_env


async def test_the_judge_sees_the_question_reference_and_answer_and_counts_tokens():
    judge = LlmJudge(StubClient())   # no scripted reply: the stub echoes the prompt back
    verdict = await judge.score("Q?", "the answer", "the reference")
    prompt = JUDGE_PROMPT.format(question="Q?", reference="the reference", output="the answer")
    # The echo isn't JSON, so the verdict is invalid; the tokens are still counted.
    assert not verdict.valid
    assert verdict.tokens == len(prompt.split()) + len(f"stub: {prompt}".split())


def test_the_judge_uses_judge_model_not_the_systems_model(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "ollama")
    monkeypatch.setenv("OLLAMA_MODEL", "llama3.2:3b-instruct-q4_K_M")   # module 10's quant under test
    monkeypatch.setenv("JUDGE_MODEL", "llama3.2")
    client = judge_client_from_env()
    assert client._model == "llama3.2"   # type: ignore[attr-defined]  # 04's client keeps it private
    assert client._temperature == 0.0    # type: ignore[attr-defined]  # a judge that samples is a noisy ruler
    assert os.environ["OLLAMA_MODEL"] == "llama3.2:3b-instruct-q4_K_M"   # lent, then given back
    assert "LLM_TEMPERATURE" not in os.environ


def test_a_real_backend_without_judge_model_fails_loudly(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "ollama")
    monkeypatch.delenv("JUDGE_MODEL", raising=False)
    with pytest.raises(ValueError, match="JUDGE_MODEL is required"):
        judge_client_from_env()


async def test_on_the_stub_llm_stub_reply_scripts_the_verdict(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.setenv("LLM_STUB_REPLY", '{"score": 4, "reason": "stub"}')
    verdict = await LlmJudge(judge_client_from_env()).score("q", "a", "r")
    assert (verdict.score, verdict.valid) == (0.75, True)
```

```python
# tests/test_systems.py
"""The adapters over module 07, with the HTTP faked: these tests never need 07 running."""
import httpx
import pytest

from evalkit.dataset import load
from systems.qa_system import build_system
from tests.fakes import fake_rag


@pytest.mark.parametrize("version, k", [("v1", 1), ("v2", 4)])
async def test_each_version_asks_07_with_its_own_k(version, k):
    seen: list[dict] = []
    system = build_system(version, transport=fake_rag({"Q?": "A."}, seen))
    assert await system.answer("Q?") == "A."
    assert seen == [{"path": "/ask", "question": "Q?", "k": k}]


async def test_an_07_error_stops_the_run():
    system = build_system("v2", transport=fake_rag({}, status=500))
    with pytest.raises(httpx.HTTPStatusError):
        await system.answer("Q?")


def test_an_unknown_version_fails_loudly():
    with pytest.raises(ValueError, match="v1 | v2 | frozen"):
        build_system("v3")


async def test_frozen_replays_the_recorded_output_for_every_example():
    system = build_system("frozen")
    for ex in load("../fixtures/qa_eval.jsonl"):
        assert await system.answer(ex["input"])


def test_the_loader_rejects_a_row_without_a_reference(tmp_path):
    path = tmp_path / "bad.jsonl"
    path.write_text('{"id": "q1", "input": "Q?"}\n', encoding="utf-8")
    with pytest.raises(ValueError, match="missing reference"):
        load(path)


def test_the_loader_rejects_a_duplicate_id(tmp_path):
    path = tmp_path / "dup.jsonl"
    row = '{"id": "q1", "input": "Q?", "reference": "A."}\n'
    path.write_text(row + row, encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate id"):
        load(path)
```

The whole pipeline, offline. The second test pins the frozen scorecard's numbers, and C#'s `GateTests` pins the same ones, so the cross-check also runs on every build:

```python
# tests/test_gate.py
"""The whole pipeline, offline: a fake 07, the stub judge, the hashing embedder."""
import json

from llm_client.stub import StubClient

from evalkit.dataset import load
from evalkit.embeddings import HashingEmbedder
from evalkit.judge import LlmJudge
from evalkit.runner import run
from evalkit.scorecard import passes_gate, write_json
from systems.qa_system import build_system
from tests.fakes import fake_rag

DATASET = load("../fixtures/qa_eval.jsonl")


def verdict(score: int) -> str:
    return json.dumps({"score": score, "reason": "scripted"})


async def test_the_gate_passes_a_good_system_and_fails_a_regression():
    good = build_system("v2", transport=fake_rag({ex["input"]: ex["reference"] for ex in DATASET}))
    result = await run(DATASET, good, LlmJudge(StubClient([verdict(5)])), HashingEmbedder())
    assert passes_gate(result) == (True, [])

    bad = build_system("v2", transport=fake_rag({ex["input"]: "I'm not sure." for ex in DATASET}))
    result = await run(DATASET, bad, LlmJudge(StubClient([verdict(1)])), HashingEmbedder())
    ok, failures = passes_gate(result)
    assert not ok
    assert [f.split("=")[0] for f in failures] == ["contains_all", "similarity", "judge"]


async def test_the_frozen_scorecard(tmp_path):
    """Pinned numbers. C#'s GateTests pins the same ones: a drift on either side fails its own build."""
    result = await run(DATASET, build_system("frozen"), LlmJudge(StubClient([verdict(4)])), HashingEmbedder())
    agg = result.aggregate()
    assert [r.id for r in result.per_example] == ["q1", "q2", "q3", "q4", "q5", "q6"]
    assert agg["exact_match"] == 1 / 6
    assert agg["contains_all"] == 5 / 6
    assert agg["judge"] == 0.75
    assert round(agg["similarity"], 3) == 0.817   # hashing: lexical overlap, not meaning
    assert (result.judge_tokens, result.judge_invalid) == (536, 0)   # the stub counts words
    doc = json.loads(write_json(result, "frozen", tmp_path).read_text(encoding="utf-8"))
    assert doc["per_example"][0]["scores"].keys() == {"exact_match", "contains_all", "similarity", "judge"}
```

### The CI gate (this is the point)

The eval *is* a pytest test. When quality regresses, the build goes red and the change doesn't merge, exactly like a failing unit test.

```python
# tests/test_eval_gate.py
"""THE gate: the real system, the real judge. Excluded by default; run it with `uv run pytest -m eval -s`."""
import os

import pytest

from evalkit.dataset import dataset_path, load, out_dir
from evalkit.embeddings import embedder_from_env
from evalkit.judge import LlmJudge, judge_client_from_env
from evalkit.runner import run
from evalkit.scorecard import passes_gate, render, write_json
from systems.qa_system import build_system


@pytest.mark.eval
async def test_quality_does_not_regress():
    version = os.environ.get("SYSTEM_VERSION", "v2")
    judge = LlmJudge(judge_client_from_env())   # from JUDGE_MODEL, never from the system
    result = await run(load(dataset_path()), build_system(version), judge, embedder_from_env())
    print("\n" + render(result, version))
    print(f"scorecard: {write_json(result, version, out_dir())}")
    ok, failures = passes_gate(result)
    assert ok, f"Eval gate failed: {failures}"
```

### Configuration and running it

```bash
# projects/09-eval-harness/python/.env.example
# Copy to .env (git-ignored). Names: docs/conventions.md#environment-variables
# compose reads this file; a bare `uv run` doesn't, so set variables in your shell there.
# The C# stack reads the same names: copy it to csharp/.env too.

# The JUDGE, through module 04's client: stub | ollama | hosted.
# The system under test is module 07, over HTTP: its model settings live in 07's .env.
LLM_BACKEND=ollama
# Required for ollama and hosted. Replaces OLLAMA_MODEL / LLM_MODEL for the judge only.
JUDGE_MODEL=llama3.2
# ollama: the server root, without /v1. Leave it commented: compose then uses host.docker.internal.
# OLLAMA_BASE_URL=http://localhost:11434
# hosted: LLM_BASE_URL (with /v1), LLM_API_KEY and the Rates__* pair, as in module 04
# stub: set LLM_STUB_REPLY in your shell to a verdict, e.g. {"score": 4, "reason": "stub"}

# Similarity. Python: sentence-transformers | hashing. C#: ollama | hashing.
# EMBED_BACKEND=sentence-transformers
EMBED_MODEL=sentence-transformers/all-MiniLM-L6-v2
OLLAMA_EMBED_MODEL=all-minilm

# The system under test: v1 (k=1) | v2 (k=4) | frozen
SYSTEM_VERSION=v2
# Module 07, running and ingested. Leave it commented: compose then uses host.docker.internal:8000,
# and local runs default to http://localhost:8000. Python 07 is on 8000, C# 07 on 8001.
# RAG_URL=http://localhost:8000

# The defaults work from python/ and csharp/; the Dockerfiles set the container paths.
# FIXTURES_DIR=../fixtures
# EVAL_DATASET=            another labeled set, e.g. a held-out one
# EVAL_OUT_DIR=outputs     where scorecard-<version>.json lands (git-ignored)
```

Offline first. These need nothing running:

```powershell
uv run pytest                                    # unit tests and the offline pipeline; the gate is deselected

# The whole harness on frozen outputs: stub judge, hashing similarity.
$env:LLM_BACKEND = 'stub'; $env:LLM_STUB_REPLY = '{"score": 4, "reason": "stub"}'; $env:EMBED_BACKEND = 'hashing'
uv run python compare.py frozen                  # prints the scorecard, writes outputs/scorecard-frozen.json
```

The frozen scorecard shows `exact_match` 0.167 (only the abstention matches word for word), `contains_all` 0.833 (the `q4` miss), `similarity` 0.817 and `judge` 0.750 (the scripted 4, on every answer). The judge number is the lesson: a scripted judge measures nothing, so stub runs test the plumbing, never quality.

Now live. Start module 07 (either language) with a real model and ingest its corpus, as module 07 shows, then from `python/`:

```powershell
Remove-Item Env:LLM_STUB_REPLY, Env:EMBED_BACKEND -ErrorAction SilentlyContinue
$env:LLM_BACKEND = 'ollama'; $env:JUDGE_MODEL = 'llama3.2'
$env:RAG_URL = 'http://localhost:8000'           # C# 07: http://localhost:8001
uv run python compare.py                         # v1 and v2; first run downloads all-MiniLM-L6-v2 (~90 MB)
uv run pytest -m eval -s                         # the gate on SYSTEM_VERSION (default v2); the exit code is the CI signal
$env:SYSTEM_VERSION = 'v1'; uv run pytest -m eval -s
```

Run `compare.py`, read the two scorecards, and make the ship/no-ship call from the numbers, latency included. That act, *deciding on evidence*, is the skill this whole series is pointing at.

### Running the Python version in Docker

The image needs project 04 and `fixtures/`, so the build context is `projects/` and the image keeps the repo's folder layout, as in [module 07](07-retrieval-augmented-generation.md#running-the-python-version-in-docker). The scaffold's `Dockerfile.dockerignore` keeps every venv in that wide context out of the build.

```dockerfile
# projects/09-eval-harness/python/Dockerfile — build context: projects/
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
# Project 04 first: the path dependency must exist before uv can install anything.
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 09-eval-harness/python/pyproject.toml 09-eval-harness/python/uv.lock 09-eval-harness/python/
WORKDIR /src/09-eval-harness/python
# Service shape: the locked dependencies (04, CPU-only torch, and pytest from the dev group). The code is copied, never installed.
RUN uv sync --frozen --no-install-project
COPY 09-eval-harness/python/ ./
COPY 09-eval-harness/fixtures/ /src/09-eval-harness/fixtures/
ENV PATH="/src/09-eval-harness/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/09-eval-harness/fixtures
# The eval gate by default. A non-zero exit fails CI. `pytest` alone runs the unit tests.
CMD ["pytest", "-m", "eval", "-v", "-s"]
```

```yaml
# projects/09-eval-harness/python/compose.yaml
name: eval-harness-py   # otherwise the project is named after the folder: "python"
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  eval:
    build: { context: ../.., dockerfile: 09-eval-harness/python/Dockerfile }   # projects/: 04 and fixtures/ must be inside
    env_file:
      - path: .env   # hosted keys and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}   # the JUDGE's backend: the system under test is 07, over HTTP
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      JUDGE_MODEL: ${JUDGE_MODEL:-llama3.2}
      EMBED_BACKEND: ${EMBED_BACKEND:-sentence-transformers}
      SYSTEM_VERSION: ${SYSTEM_VERSION:-v2}
      RAG_URL: ${RAG_URL:-http://host.docker.internal:8000}   # 07 on the host: Python 8000, C# 8001
      EVAL_OUT_DIR: /out
    volumes:
      - ./outputs:/out                            # the scorecard JSON lands here (git-ignored)
      - hf-cache:/root/.cache/huggingface         # the embedding model downloads once
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

volumes:
  hf-cache:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

With module 07 up on the host (its compose publishes 8000) and native Ollama running:

```powershell
cd projects/09-eval-harness/python
docker compose run --rm eval                     # the gate; exit code is the CI signal; scorecard in ./outputs
docker compose run --rm eval python compare.py   # A/B the two versions
docker compose run --rm eval pytest -q           # the unit tests, offline
# Without compose (from the repo root): docker build -f projects/09-eval-harness/python/Dockerfile -t eval-harness-py projects
```

As a CI step this is "run the container; if pytest exits non-zero, fail the pipeline", identical in shape to how you already run unit tests.

## C# implementation

Work in `projects/09-eval-harness/csharp/`. Same metrics, same thresholds, same eval set, same `compare` command, same env vars. What changes:

- **A class library and a console app.** `EvalHarness` holds everything; `EvalHarness.Cli` is the command line. A later module that wants the harness references the library, never the console app (module 05's `PromptLab` is a console app, which is why this harness evaluates over HTTP instead of referencing it; to evaluate 05 in-process, first move its `Harness` and `PromptStore` into a class library, the way 04 splits `LlmClient` from `LlmClient.Demo`).
- **NUnit instead of pytest, with the same split.** The default `dotnet test` runs everything except `[Category("Eval")]`, because the test project points at `unit.runsettings`. The gate runs with `dotnet test --settings eval.runsettings`, the counterpart of `pytest -m eval`.
- **Data-driven cases via `[TestCaseSource]`.** Each eval example shows up as its own test in Test Explorer, with its scores and output in the test log. Those per-example tests never fail on their own. The gate test aggregates and asserts, because quality is a property of the set, not of one example.
- **The judge is registered once, in DI.** `AddEvalHarness` calls 04's `AddLlmClient` with a configuration that lays `JUDGE_MODEL` over the model variables, so the judge is the only `IChatClient` in the container and the system under test (07, over HTTP) can't touch it.
- **The judge uses structured output.** `GetResponseAsync<JudgeVerdict>` asks the model for JSON matching a C# record and deserializes it. Same rubric text, stricter contract, and the same 1–5 range check.

### Scaffold

From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 09-eval-harness -Template classlib -Name EvalHarness
cd projects/09-eval-harness/csharp
Remove-Item src/EvalHarness/Class1.cs, tests/EvalHarness.Tests/SmokeTests.cs
dotnet new console -n EvalHarness.Cli -o src/EvalHarness.Cli
dotnet sln add src/EvalHarness.Cli
dotnet add src/EvalHarness.Cli reference src/EvalHarness
dotnet add src/EvalHarness reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add src/EvalHarness package System.Numerics.Tensors
dotnet add src/EvalHarness package Microsoft.Extensions.Configuration
dotnet add src/EvalHarness.Cli package Microsoft.Extensions.Hosting
dotnet add tests/EvalHarness.Tests package Microsoft.Extensions.Configuration.EnvironmentVariables
```

`LlmClient` brings `Microsoft.Extensions.AI`, OllamaSharp and the HTTP client factory with it. The harness reads the shared eval set straight from `fixtures/`, with no copy in the build output: `FIXTURES_DIR` wins when set; otherwise `EvalSettings` walks up from the bin folder to the one holding `EvalHarness.slnx` and takes `../fixtures`, so `dotnet run` and NUnit both find it.

### `src/EvalHarness/Dataset.cs`

```csharp
// src/EvalHarness/Dataset.cs
using System.Text.Json;
using Microsoft.Extensions.Configuration;

namespace EvalHarness;

public sealed record EvalExample(string Id, string Input, string Reference, IReadOnlyList<string>? MustInclude = null)
{
    public IReadOnlyList<string> Required => MustInclude ?? [];
}

public static class Dataset
{
    // snake_case on disk (must_include): the same files the Python harness reads.
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    /// <summary>One JSON object per line, blank lines skipped.</summary>
    public static List<T> ReadJsonl<T>(string path) =>
        File.ReadLines(path)
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .Select(line => JsonSerializer.Deserialize<T>(line, Json) ?? throw new InvalidDataException($"{path}: null row"))
            .ToList();

    /// <summary>
    /// The labeled set. Fails loudly on a row without id/input/reference or on a repeated id:
    /// a silently skipped or doubled example changes every average.
    /// </summary>
    public static IReadOnlyList<EvalExample> Load(string path)
    {
        List<EvalExample> rows = ReadJsonl<EvalExample>(path);
        var seen = new HashSet<string>();
        for (int i = 0; i < rows.Count; i++)
        {
            EvalExample ex = rows[i];
            // The record says non-nullable, but a missing JSON property still deserializes to null.
            string[] missing = [.. new[] { ("id", ex.Id), ("input", ex.Input), ("reference", ex.Reference) }
                .Where(f => string.IsNullOrEmpty(f.Item2)).Select(f => f.Item1)];
            if (missing.Length > 0)
                throw new InvalidDataException($"{path}: row {i + 1} is missing {string.Join(", ", missing)}");
            if (!seen.Add(ex.Id))
                throw new InvalidDataException($"{path}: duplicate id '{ex.Id}'");
        }
        return rows;
    }
}

/// <summary>The harness's own settings, under the same env-var names as the Python side.</summary>
public sealed class EvalSettings(IConfiguration config)
{
    /// <summary>The shared fixtures/ folder, ../fixtures from csharp/. Containers set FIXTURES_DIR.</summary>
    public string FixturesDir => config["FIXTURES_DIR"] ?? Path.Combine(CsharpDir, "..", "fixtures");

    /// <summary>EVAL_DATASET wins (another set, e.g. a held-out one); otherwise the shared eval set.</summary>
    public string DatasetPath => config["EVAL_DATASET"] is { Length: > 0 } path ? path : Path.Combine(FixturesDir, "qa_eval.jsonl");

    /// <summary>Where scorecards go: csharp/outputs, git-ignored. Run results are artifacts, not source.</summary>
    public string OutDir => config["EVAL_OUT_DIR"] ?? Path.Combine(CsharpDir, "outputs");

    public string SystemVersion => config["SYSTEM_VERSION"] ?? "v2";

    /// <summary>Python 07 publishes 8000 (the default), C# 07 8001.</summary>
    public Uri RagUrl => new(config["RAG_URL"] ?? "http://localhost:8000");

    // dotnet run and NUnit both run from a bin folder, so walk up to the folder holding EvalHarness.slnx.
    // A container has no .slnx: the Dockerfile sets FIXTURES_DIR and EVAL_OUT_DIR instead.
    private static string CsharpDir { get; } = FindCsharpDir();

    private static string FindCsharpDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "EvalHarness.slnx")))
                return dir.FullName;
        return Directory.GetCurrentDirectory();
    }
}
```

### `src/EvalHarness/Embeddings.cs`

```csharp
// src/EvalHarness/Embeddings.cs
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using OllamaSharp;

namespace EvalHarness;

public static class Embedders
{
    public static readonly string[] Backends = ["ollama", "hashing"];

    /// <summary>Pick the similarity embedder from EMBED_BACKEND (default: the real model, via Ollama).</summary>
    public static IEmbeddingGenerator<string, Embedding<float>> FromConfig(IConfiguration config) =>
        (config["EMBED_BACKEND"] ?? "ollama") switch
        {
            // all-minilm in Ollama is all-MiniLM-L6-v2, the model the Python side loads in-process.
            "ollama" => new OllamaApiClient(
                new Uri(config["OLLAMA_BASE_URL"] ?? "http://localhost:11434"), config["OLLAMA_EMBED_MODEL"] ?? "all-minilm"),
            "hashing" => new HashingEmbeddingGenerator(),
            var other => throw new InvalidOperationException(
                $"unknown EMBED_BACKEND '{other}' (expected one of: {string.Join(" | ", Backends)})"),
        };
}

/// <summary>
/// EMBED_BACKEND=hashing: module 07's offline embedder, copied (07 is a web app, not a library).
/// Each word is hashed into one of <paramref name="dimensions"/> buckets: lexical, not semantic,
/// but deterministic, so the stub cross-check can be exact. FNV-1a, never string.GetHashCode().
/// </summary>
public sealed partial class HashingEmbeddingGenerator(int dimensions = 256) : IEmbeddingGenerator<string, Embedding<float>>
{
    public Task<GeneratedEmbeddings<Embedding<float>>> GenerateAsync(
        IEnumerable<string> values, EmbeddingGenerationOptions? options = null, CancellationToken cancellationToken = default) =>
        Task.FromResult(new GeneratedEmbeddings<Embedding<float>>(values.Select(v => new Embedding<float>(Embed(v)))));

    private float[] Embed(string text)
    {
        var v = new float[dimensions];
        foreach (Match word in Word().Matches(text.ToLowerInvariant()))
            v[Fnv1a(word.Value) % (uint)dimensions] += 1f;
        return v;
    }

    /// <summary>32-bit FNV-1a over the UTF-8 bytes: the same number in every process, and in Python.</summary>
    public static uint Fnv1a(string word)
    {
        uint h = 0x811C9DC5;
        foreach (byte b in Encoding.UTF8.GetBytes(word))
            h = unchecked((h ^ b) * 0x01000193);
        return h;
    }

    [GeneratedRegex("[a-z0-9]+")]
    private static partial Regex Word();

    public object? GetService(Type serviceType, object? serviceKey = null) =>
        serviceKey is null && serviceType.IsInstanceOfType(this) ? this : null;

    public void Dispose() { }
}
```

### `src/EvalHarness/Metrics.cs`

```csharp
// src/EvalHarness/Metrics.cs
using System.Numerics.Tensors;
using Microsoft.Extensions.AI;

namespace EvalHarness;

public static class Metrics
{
    /// <summary>1.0 if the strings match after trimming, ignoring case, else 0.0. The cheapest signal.</summary>
    public static double ExactMatch(string output, string reference) =>
        string.Equals(output.Trim(), reference.Trim(), StringComparison.OrdinalIgnoreCase) ? 1.0 : 0.0;

    /// <summary>Rule-based: the fraction of required substrings present, ignoring case. Objective and free.</summary>
    public static double ContainsAll(string output, IReadOnlyList<string> required) =>
        required.Count == 0
            ? 1.0
            : (double)required.Count(r => output.Contains(r, StringComparison.OrdinalIgnoreCase)) / required.Count;

    /// <summary>
    /// Cosine similarity (the 07 math). 0.0 when either vector is all zeros, e.g. an empty answer:
    /// it isn't similar to anything, and a NaN would poison the mean.
    /// </summary>
    public static double Cosine(ReadOnlySpan<float> a, ReadOnlySpan<float> b) =>
        TensorPrimitives.Norm(a) == 0 || TensorPrimitives.Norm(b) == 0 ? 0.0 : TensorPrimitives.CosineSimilarity(a, b);

    /// <summary>Cosine similarity of the output and reference embeddings.</summary>
    public static async Task<double> EmbeddingSimilarityAsync(
        IEmbeddingGenerator<string, Embedding<float>> embedder, string output, string reference, CancellationToken ct = default)
    {
        GeneratedEmbeddings<Embedding<float>> vectors = await embedder.GenerateAsync([output, reference], cancellationToken: ct);
        return Cosine(vectors[0].Vector.Span, vectors[1].Vector.Span);
    }
}
```

### `src/EvalHarness/LlmJudge.cs`

```csharp
// src/EvalHarness/LlmJudge.cs
using Microsoft.Extensions.AI;

namespace EvalHarness;

/// <summary>The JSON the judge must return.</summary>
public sealed record JudgeVerdict(int Score, string Reason);

/// <summary>Score is 0-1 (0.0 when the reply isn't a valid verdict); Tokens is this call's prompt + completion.</summary>
public sealed record Verdict(double Score, bool Valid, long Tokens);

/// <summary>LLM-as-judge, normalized to 0-1. VALIDATE it against human labels before trusting it.</summary>
public sealed class LlmJudge(IChatClient judge)
{
    // Python's JUDGE_PROMPT, byte for byte. $$ raw string: {{x}} interpolates, single braces are literal.
    public static string BuildPrompt(string question, string reference, string output) => $$"""
        You are grading a candidate answer against a reference answer.
        Question: {{question}}
        Reference answer: {{reference}}
        Candidate answer: {{output}}

        Score 1-5: 5 = says what the reference says, 3 = partly right or missing a key detail,
        1 = wrong, off-topic, or answers when the reference says the documents don't know.
        Respond with ONLY a JSON object: {"score": <int 1-5>, "reason": "<one sentence>"}
        """;

    public async Task<Verdict> ScoreAsync(string question, string output, string reference, CancellationToken ct = default)
    {
        ChatResponse<JudgeVerdict> response = await judge.GetResponseAsync<JudgeVerdict>(
            BuildPrompt(question, reference, output), new ChatOptions { Temperature = 0f }, cancellationToken: ct);
        long tokens = (response.Usage?.InputTokenCount ?? 0) + (response.Usage?.OutputTokenCount ?? 0);

        // Not JSON, no score, or out of range: scored 0, so a broken judge fails the gate instead of
        // passing it, and counted, so the scorecard says "the judge broke", not "the answers got worse".
        if (!response.TryGetResult(out JudgeVerdict? verdict) || verdict.Score is < 1 or > 5)
            return new Verdict(0.0, false, tokens);
        return new Verdict((verdict.Score - 1) / 4.0, true, tokens);   // map 1..5 to 0..1
    }
}
```

`GetResponseAsync<T>` generates a JSON schema from `JudgeVerdict` and sends it as the response format, so providers that support it constrain the output to that shape: module 06's "level 3" guarantee, applied to the judge. The prompt text is identical to Python's; on the stub, which ignores the schema, both sides count the same 536 judge tokens for the frozen set.

### `src/EvalHarness/Runner.cs`

```csharp
// src/EvalHarness/Runner.cs
using System.Diagnostics;
using Microsoft.Extensions.AI;

namespace EvalHarness;

// Same fields, in the same order, as Python's ExampleResult: the scorecard JSONs line up.
public sealed record ExampleResult(
    string Id, string Output, double LatencyMs, IReadOnlyDictionary<string, double> Scores, long JudgeTokens, bool JudgeValid);

public sealed class RunResult
{
    public List<ExampleResult> PerExample { get; } = [];

    /// <summary>The mean of each metric over the set, plus p50 latency. An empty run gives {}, which fails the gate.</summary>
    public IReadOnlyDictionary<string, double> Aggregate()
    {
        if (PerExample.Count == 0)
            return new Dictionary<string, double>();

        var agg = PerExample[0].Scores.Keys.ToDictionary(k => k, k => PerExample.Average(r => r.Scores[k]));
        // The upper median: element n/2 of the sorted list, as in Python.
        agg["latency_ms_p50"] = PerExample.Select(r => r.LatencyMs).Order().ElementAt(PerExample.Count / 2);
        return agg;
    }

    public long JudgeTokens => PerExample.Sum(r => r.JudgeTokens);
    public int JudgeInvalid => PerExample.Count(r => !r.JudgeValid);
}

/// <summary>
/// Runs a system over the dataset and scores each answer. The judge and the embedder are injected
/// once and stay fixed while the system under test changes.
/// </summary>
public sealed class EvalRunner(IEmbeddingGenerator<string, Embedding<float>> embedder, LlmJudge judge)
{
    public async Task<ExampleResult> RunOneAsync(IQaSystem system, EvalExample ex, CancellationToken ct = default)
    {
        long start = Stopwatch.GetTimestamp();
        string output = await system.AnswerAsync(ex.Input, ct);   // an error stops the run: broken, not low
        double latencyMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;

        Verdict verdict = await judge.ScoreAsync(ex.Input, output, ex.Reference, ct);
        var scores = new Dictionary<string, double>
        {
            ["exact_match"] = Metrics.ExactMatch(output, ex.Reference),
            ["contains_all"] = Metrics.ContainsAll(output, ex.Required),
            ["similarity"] = await Metrics.EmbeddingSimilarityAsync(embedder, output, ex.Reference, ct),
            ["judge"] = verdict.Score,
        };
        return new ExampleResult(ex.Id, output, latencyMs, scores, verdict.Tokens, verdict.Valid);
    }

    // Sequential on purpose, like Python: concurrent calls would distort the latency numbers.
    public async Task<RunResult> RunAsync(IQaSystem system, IEnumerable<EvalExample> dataset, CancellationToken ct = default)
    {
        var result = new RunResult();
        foreach (EvalExample ex in dataset)
            result.PerExample.Add(await RunOneAsync(system, ex, ct));
        return result;
    }
}
```

The metric keys are snake_case strings, not C# names, so the two scorecards line up key for key and you can diff them.

### `src/EvalHarness/Scorecard.cs`

```csharp
// src/EvalHarness/Scorecard.cs
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace EvalHarness;

public static class Scorecard
{
    /// <summary>The gate, shared with Python's THRESHOLDS. similarity's 0.70 is calibrated for all-MiniLM-L6-v2.</summary>
    public static readonly IReadOnlyDictionary<string, double> Thresholds = new Dictionary<string, double>
    {
        ["contains_all"] = 0.80, ["similarity"] = 0.70, ["judge"] = 0.75,
    };

    public static string Render(RunResult run, string label)
    {
        var sb = new StringBuilder()
            .AppendLine($"=== Scorecard: {label} ===")
            .AppendLine($"examples: {run.PerExample.Count}");
        foreach (var (k, v) in run.Aggregate())
            sb.AppendLine(string.Create(CultureInfo.InvariantCulture, $"  {k,-20} {v:F3}"));
        sb.AppendLine($"  {"judge_tokens",-20} {run.JudgeTokens}")
          .AppendLine($"  {"judge_invalid",-20} {run.JudgeInvalid}");
        return sb.ToString().TrimEnd();
    }

    /// <summary>Returns (ok, failures). A metric below its threshold, or missing, fails the gate.</summary>
    public static (bool Ok, IReadOnlyList<string> Failures) PassesGate(
        RunResult run, IReadOnlyDictionary<string, double>? thresholds = null)
    {
        var agg = run.Aggregate();
        var failures = (thresholds ?? Thresholds)
            .Where(t => agg.GetValueOrDefault(t.Key) < t.Value)
            .Select(t => string.Create(CultureInfo.InvariantCulture,
                $"{t.Key}={agg.GetValueOrDefault(t.Key):F3} < {t.Value:F3}"))
            .ToList();
        return (failures.Count == 0, failures);
    }

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,   // LatencyMs -> latency_ms; dictionary keys stay as they are
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,   // "don't", not "don't"
    };

    /// <summary>The scorecard as JSON, for CI to archive and the cross-check to diff. Same shape as Python's.</summary>
    public static async Task<string> WriteJsonAsync(RunResult run, string label, string directory, CancellationToken ct = default)
    {
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, $"scorecard-{label}.json");
        var doc = new
        {
            Label = label,
            Examples = run.PerExample.Count,
            Aggregate = run.Aggregate(),
            run.JudgeTokens,
            run.JudgeInvalid,
            run.PerExample,
        };
        await using FileStream stream = File.Create(path);
        await JsonSerializer.SerializeAsync(stream, doc, Json, ct);
        return path;
    }
}
```

### `src/EvalHarness/QaSystems.cs`

```csharp
// src/EvalHarness/QaSystems.cs
using System.Net.Http.Json;

namespace EvalHarness;

/// <summary>The system under test: question in, answer out.</summary>
public interface IQaSystem
{
    string Version { get; }
    Task<string> AnswerAsync(string question, CancellationToken ct = default);
}

/// <summary>Module 07's POST /ask, either language (same contract), at a fixed k.</summary>
public sealed class RagQaSystem(HttpClient http, string version, int k) : IQaSystem
{
    private sealed record AskResponse(string? Answer);

    public string Version => version;

    public async Task<string> AnswerAsync(string question, CancellationToken ct = default)
    {
        using HttpResponseMessage resp = await http.PostAsJsonAsync("/ask", new { question, k }, ct);
        resp.EnsureSuccessStatusCode();   // a 4xx or 5xx is a broken run, not a low score
        AskResponse? body = await resp.Content.ReadFromJsonAsync<AskResponse>(ct);
        return body?.Answer ?? throw new InvalidDataException("07's /ask returned no answer");
    }
}

/// <summary>Replays recorded outputs, so you score the harness, not the system. For the cross-check.</summary>
public sealed class FrozenQaSystem(IReadOnlyDictionary<string, string> outputsByInput) : IQaSystem
{
    private sealed record Row(string Input, string Output);

    public string Version => "frozen";

    public Task<string> AnswerAsync(string question, CancellationToken ct = default) =>
        outputsByInput.TryGetValue(question, out string? output)
            ? Task.FromResult(output)
            : throw new KeyNotFoundException($"no frozen output for '{question}'");

    public static FrozenQaSystem Load(string path) =>
        new(Dataset.ReadJsonl<Row>(path).ToDictionary(r => r.Input, r => r.Output));
}

/// <summary>Builds a system by version name, with the "rag" HttpClient from DI.</summary>
public sealed class QaSystemFactory(IHttpClientFactory http, EvalSettings settings)
{
    /// <summary>What each version means: chunks retrieved per question. Python's VERSIONS says exactly the same.</summary>
    public static readonly IReadOnlyDictionary<string, int> Versions = new Dictionary<string, int> { ["v1"] = 1, ["v2"] = 4 };

    public IQaSystem Build(string version) =>
        version == "frozen" ? FrozenQaSystem.Load(Path.Combine(settings.FixturesDir, "qa_outputs.jsonl"))
        : Versions.TryGetValue(version, out int k) ? new RagQaSystem(http.CreateClient("rag"), version, k)
        : throw new ArgumentException($"unknown SYSTEM_VERSION '{version}' (expected one of: v1 | v2 | frozen)");
}
```

### `src/EvalHarness/EvalServices.cs`

One composition root for the CLI and the tests, so the gate measures exactly what `compare` measures:

```csharp
// src/EvalHarness/EvalServices.cs
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness;

public static class EvalServices
{
    /// <summary>One composition root for the CLI and the tests, so the gate measures exactly what compare measures.</summary>
    public static IServiceCollection AddEvalHarness(this IServiceCollection services, IConfiguration config)
    {
        var settings = new EvalSettings(config);
        services.AddSingleton(settings);
        services.AddLogging();   // 04's cost logging wants an ILogger; the CLI adds a console provider

        // The judge: module 04's IChatClient for LLM_BACKEND, with JUDGE_MODEL as the model. The only
        // IChatClient here: the system under test is 07, over HTTP, so nothing else can move the ruler.
        services.AddLlmClient(JudgeConfig(config));
        services.AddSingleton<LlmJudge>();
        services.AddSingleton(Embedders.FromConfig(config));
        services.AddSingleton<EvalRunner>();

        services.AddHttpClient("rag", c =>
        {
            c.BaseAddress = settings.RagUrl;
            c.Timeout = TimeSpan.FromSeconds(120);
        });
        services.AddSingleton<QaSystemFactory>();
        return services;
    }

    /// <summary>
    /// The configuration 04's AddLlmClient sees: yours, with JUDGE_MODEL laid over the backend's model variable,
    /// so changing the system (or OLLAMA_MODEL, in module 10's quant runs) can't change the judge.
    /// </summary>
    public static IConfiguration JudgeConfig(IConfiguration config)
    {
        string backend = config["LLM_BACKEND"] ?? "ollama";
        if (backend is not ("ollama" or "hosted" or "bedrock"))   // bedrock arrives in module 12
            return config;   // stub (LLM_STUB_REPLY scripts the verdict), or 04's loud error
        string model = config["JUDGE_MODEL"] is { Length: > 0 } m
            ? m
            : throw new InvalidOperationException(
                $"JUDGE_MODEL is required with LLM_BACKEND={backend}: pin the judge apart from the system");
        return new ConfigurationBuilder()
            .AddConfiguration(config)
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["OLLAMA_MODEL"] = model, ["LLM_MODEL"] = model, ["BEDROCK_MODEL_ID"] = model,
            })
            .Build();
    }
}
```

### `src/EvalHarness.Cli/Program.cs`

```csharp
// src/EvalHarness.Cli/Program.cs
using System.Globalization;
using System.Text.Json;
using EvalHarness;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// No args to the host: our commands aren't configuration keys.
HostApplicationBuilder builder = Host.CreateApplicationBuilder();
// Logs go to stderr, as in Python, so stdout is only the scorecards.
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Services.AddEvalHarness(builder.Configuration);
using IHost host = builder.Build();
IServiceProvider services = host.Services;

return args switch
{
    ["compare", .. var versions] => await CompareAsync(versions.Length > 0 ? versions : ["v1", "v2"]),
    ["rubric", var rubric, var evalSet, var labelsOut] => await RubricAsync(rubric, evalSet, labelsOut),
    _ => Usage(),
};

// compare.py's twin: score versions of the system with ONE judge, built before any system.
async Task<int> CompareAsync(string[] versions)
{
    var settings = services.GetRequiredService<EvalSettings>();
    var runner = services.GetRequiredService<EvalRunner>();
    var systems = services.GetRequiredService<QaSystemFactory>();
    IReadOnlyList<EvalExample> dataset = Dataset.Load(settings.DatasetPath);
    foreach (string version in versions)
    {
        RunResult result = await runner.RunAsync(systems.Build(version), dataset);
        var (ok, failures) = Scorecard.PassesGate(result);
        Console.WriteLine(Scorecard.Render(result, version));
        Console.WriteLine($"  gate: {(ok ? "PASS" : "FAIL " + string.Join("; ", failures))}");
        Console.WriteLine($"  scorecard: {await Scorecard.WriteJsonAsync(result, version, settings.OutDir)}");
        Console.WriteLine();
    }
    // Read the scorecards side by side: did v2 beat v1, and at what latency? Decide on numbers.
    return 0;
}

// rubric_judge.py's twin: label review-lab's eval set, write {"id","label"} lines for agreement.py.
async Task<int> RubricAsync(string rubricPath, string evalSetPath, string labelsOut)
{
    List<ReviewRow> rows = Dataset.ReadJsonl<ReviewRow>(evalSetPath);
    // Here the judge IS the system under test: JUDGE_MODEL names the model you're calibrating.
    IReadOnlyList<Labeled> labeled = await Rubric.LabelReviewsAsync(
        rows, await File.ReadAllTextAsync(rubricPath), services.GetRequiredService<IChatClient>());
    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(labelsOut))!);
    await File.WriteAllLinesAsync(labelsOut, labeled.Select(x => JsonSerializer.Serialize(new { id = x.Id, label = x.Label })));
    int invalid = labeled.Count(x => x.Label == Rubric.Invalid);
    Console.WriteLine(string.Create(CultureInfo.InvariantCulture,
        $"items={labeled.Count} accuracy={Rubric.Accuracy(labeled):F2} invalid={invalid}"));
    foreach (Labeled x in labeled.Where(x => x.Label != x.Expected))
        Console.WriteLine($"  {x.Id}: judge={x.Label} you={x.Expected}");
    return 0;
}

static int Usage()
{
    Console.Error.WriteLine("usage: EvalHarness.Cli compare [versions...]   (default: v1 v2)");
    Console.Error.WriteLine("       EvalHarness.Cli rubric <rubric.md> <eval_set.jsonl> <labels_out.jsonl>");
    return 2;
}
```

### Tests

`TestHost` builds the real composition root from an in-memory configuration (never your shell's environment), with the stub judge, the hashing embedder, and 07 faked under the `rag` `HttpClient` by swapping its primary handler.

```csharp
// tests/EvalHarness.Tests/Fakes.cs
using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using EvalHarness;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness.Tests;

/// <summary>Maps known strings to fixed vectors, so similarity tests are exact and offline.</summary>
public sealed class FakeEmbeddingGenerator(Dictionary<string, float[]> vectors) : IEmbeddingGenerator<string, Embedding<float>>
{
    public Task<GeneratedEmbeddings<Embedding<float>>> GenerateAsync(
        IEnumerable<string> values, EmbeddingGenerationOptions? options = null, CancellationToken cancellationToken = default) =>
        Task.FromResult(new GeneratedEmbeddings<Embedding<float>>(values.Select(v => new Embedding<float>(vectors[v]))));

    public object? GetService(Type serviceType, object? serviceKey = null) => null;
    public void Dispose() { }
}

/// <summary>Module 07's /ask, faked under the HttpClient: answers by question, records each request body.</summary>
public sealed class FakeRag(Dictionary<string, string> answers, HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
{
    public List<(string Path, JsonNode Body)> Seen { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        JsonNode body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(ct))!;
        Seen.Add((request.RequestUri!.AbsolutePath, body));
        if (status != HttpStatusCode.OK)
            return new HttpResponseMessage(status) { Content = JsonContent.Create(new { detail = "boom" }) };
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new { answer = answers[body["question"]!.GetValue<string>()], citations = Array.Empty<object>() }),
        };
    }
}

public static class TestHost
{
    /// <summary>Configuration from a dictionary, never from the process environment: tests stay independent of your shell.</summary>
    public static IConfiguration Config(params (string Key, string Value)[] values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values.Select(v => new KeyValuePair<string, string?>(v.Key, v.Value)))
            .Build();

    /// <summary>The real composition root, offline: stub judge, hashing embedder, and 07 faked under the "rag" HttpClient.</summary>
    public static ServiceProvider Services(HttpMessageHandler rag, params (string Key, string Value)[] extra)
    {
        (string, string)[] values = [("LLM_BACKEND", "stub"), ("EMBED_BACKEND", "hashing"), .. extra];
        var services = new ServiceCollection().AddEvalHarness(Config(values));
        services.AddHttpClient("rag").ConfigurePrimaryHttpMessageHandler(() => rag);
        return services.BuildServiceProvider();
    }
}
```

```csharp
// tests/EvalHarness.Tests/MetricsTests.cs
using EvalHarness;
using LlmClient;

namespace EvalHarness.Tests;

/// <summary>The metrics are code, so they get ordinary unit tests: no model, no network. Mirrors test_metrics.py.</summary>
public class MetricsTests
{
    [TestCase("Within 24 hours.", "within 24 hours.", 1.0)]
    [TestCase("  Within 24 hours.  ", "Within 24 hours.", 1.0)]
    [TestCase("Within a day.", "Within 24 hours.", 0.0)]
    public void ExactMatch_normalizes_case_and_whitespace(string output, string reference, double expected) =>
        Assert.That(Metrics.ExactMatch(output, reference), Is.EqualTo(expected));

    [TestCase("Run deploy --REVERT now", new[] { "revert" }, 1.0)]
    [TestCase("Roll it back", new[] { "revert", "sha" }, 0.0)]
    [TestCase("revert to the old sha", new[] { "revert", "24" }, 0.5)]
    [TestCase("anything", new string[0], 1.0)]
    public void ContainsAll_is_the_fraction_present(string output, string[] required, double expected) =>
        Assert.That(Metrics.ContainsAll(output, required), Is.EqualTo(expected));

    [Test]
    public async Task Similarity_is_cosine_of_the_embeddings()
    {
        var embedder = new FakeEmbeddingGenerator(new() { ["a"] = [1f, 0f], ["b"] = [1f, 1f] });
        double score = await Metrics.EmbeddingSimilarityAsync(embedder, "a", "b");
        Assert.That(score, Is.EqualTo(Math.Sqrt(0.5)).Within(1e-6));
    }

    [Test]
    public async Task Similarity_of_an_empty_vector_is_zero_not_NaN()
    {
        var embedder = new FakeEmbeddingGenerator(new() { [""] = [0f, 0f], ["b"] = [1f, 1f] });
        Assert.That(await Metrics.EmbeddingSimilarityAsync(embedder, "", "b"), Is.EqualTo(0.0));
    }

    [TestCase("""{"score": 5, "reason": "correct"}""", 1.0, true)]
    [TestCase("""{"score": 3, "reason": "partly"}""", 0.5, true)]
    [TestCase("""{"score": 9, "reason": "very good"}""", 0.0, false)]   // out of range: rejected
    [TestCase("""{"score": 4.5, "reason": "between"}""", 0.0, false)]   // not an int
    [TestCase("""{"reason": "no score"}""", 0.0, false)]
    [TestCase("I'd say about a 4.", 0.0, false)]                         // not JSON
    public async Task Judge_maps_score_to_0_1(string judgeReply, double expected, bool valid)
    {
        Verdict verdict = await new LlmJudge(new StubChatClient([judgeReply])).ScoreAsync("question", "output", "reference");
        Assert.That((verdict.Score, verdict.Valid), Is.EqualTo((expected, valid)));
    }

    // One example per judge score, with latencies 10, 20, 30, ...
    private static RunResult Run(params double[] judge)
    {
        var run = new RunResult();
        for (int i = 0; i < judge.Length; i++)
            run.PerExample.Add(new ExampleResult(
                $"q{i + 1}", "x", 10.0 * (i + 1), new Dictionary<string, double> { ["judge"] = judge[i] }, 0, true));
        return run;
    }

    [Test]
    public void Gate_fails_when_a_metric_is_below_threshold()
    {
        var (ok, failures) = Scorecard.PassesGate(Run(0.5), new Dictionary<string, double> { ["judge"] = 0.75 });
        Assert.That(ok, Is.False);
        Assert.That(failures, Is.EqualTo(new[] { "judge=0.500 < 0.750" }));
    }

    [Test]
    public void Gate_passes_at_the_threshold()
    {
        var (ok, _) = Scorecard.PassesGate(
            Run(0.5, 1.0), new Dictionary<string, double> { ["judge"] = 0.75 });
        Assert.That(ok, Is.True);
    }

    [Test]
    public void An_empty_run_fails_the_gate()
    {
        var (ok, failures) = Scorecard.PassesGate(new RunResult(), new Dictionary<string, double> { ["judge"] = 0.75 });
        Assert.That(ok, Is.False);
        Assert.That(failures, Is.EqualTo(new[] { "judge=0.000 < 0.750" }));
    }

    [Test]
    public void P50_is_the_upper_median()
    {
        // Latencies 10, 20, 30, 40: element 4 / 2.
        Assert.That(Run(1.0, 1.0, 1.0, 1.0).Aggregate()["latency_ms_p50"], Is.EqualTo(30.0));
    }
}
```

```csharp
// tests/EvalHarness.Tests/JudgeTests.cs
using EvalHarness;
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness.Tests;

/// <summary>The judge is built once, from JUDGE_MODEL, never from the system's model variables. Mirrors test_judge.py.</summary>
public class JudgeTests
{
    private static int Words(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    [Test]
    public async Task The_judge_sees_the_question_reference_and_answer_and_counts_tokens()
    {
        var judge = new LlmJudge(new StubChatClient());   // no scripted reply: the stub echoes the prompt back
        Verdict verdict = await judge.ScoreAsync("Q?", "the answer", "the reference");
        string prompt = LlmJudge.BuildPrompt("Q?", "the reference", "the answer");
        // The echo isn't JSON, so the verdict is invalid; the tokens are still counted.
        Assert.That(verdict.Valid, Is.False);
        Assert.That(verdict.Tokens, Is.EqualTo(Words(prompt) + Words($"stub: {prompt}")));
    }

    [Test]
    public void The_judge_uses_JUDGE_MODEL_not_the_systems_model()
    {
        var config = TestHost.Config(
            ("LLM_BACKEND", "ollama"),
            ("OLLAMA_MODEL", "llama3.2:3b-instruct-q4_K_M"),   // module 10's quant under test
            ("JUDGE_MODEL", "llama3.2"));
        using ServiceProvider services = new ServiceCollection().AddEvalHarness(config).BuildServiceProvider();
        var judge = services.GetRequiredService<IChatClient>();
        Assert.That(judge.GetService<ChatClientMetadata>()?.DefaultModelId, Is.EqualTo("llama3.2"));
        Assert.That(config["OLLAMA_MODEL"], Is.EqualTo("llama3.2:3b-instruct-q4_K_M"));   // yours, untouched
    }

    [Test]
    public void A_real_backend_without_JUDGE_MODEL_fails_loudly()
    {
        var ex = Assert.Throws<InvalidOperationException>(() =>
            new ServiceCollection().AddEvalHarness(TestHost.Config(("LLM_BACKEND", "ollama"))));
        Assert.That(ex!.Message, Does.Contain("JUDGE_MODEL is required"));
    }

    [Test]
    public async Task On_the_stub_LLM_STUB_REPLY_scripts_the_verdict()
    {
        using ServiceProvider services = TestHost.Services(new FakeRag([]), ("LLM_STUB_REPLY", """{"score": 4, "reason": "stub"}"""));
        Verdict verdict = await services.GetRequiredService<LlmJudge>().ScoreAsync("q", "a", "r");
        Assert.That((verdict.Score, verdict.Valid), Is.EqualTo((0.75, true)));
    }
}
```

```csharp
// tests/EvalHarness.Tests/QaSystemTests.cs
using System.Net;
using EvalHarness;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness.Tests;

/// <summary>The adapters over module 07, with the HTTP faked: these tests never need 07 running. Mirrors test_systems.py.</summary>
public class QaSystemTests
{
    [TestCase("v1", 1)]
    [TestCase("v2", 4)]
    public async Task Each_version_asks_07_with_its_own_k(string version, int k)
    {
        var rag = new FakeRag(new() { ["Q?"] = "A." });
        using ServiceProvider services = TestHost.Services(rag);
        IQaSystem system = services.GetRequiredService<QaSystemFactory>().Build(version);

        Assert.That(await system.AnswerAsync("Q?"), Is.EqualTo("A."));
        Assert.That(rag.Seen, Has.Count.EqualTo(1));
        Assert.That(rag.Seen[0].Path, Is.EqualTo("/ask"));
        Assert.That(rag.Seen[0].Body.ToJsonString(), Is.EqualTo($$"""{"question":"Q?","k":{{k}}}"""));
    }

    [Test]
    public void An_07_error_stops_the_run()
    {
        using ServiceProvider services = TestHost.Services(new FakeRag([], HttpStatusCode.InternalServerError));
        IQaSystem system = services.GetRequiredService<QaSystemFactory>().Build("v2");
        Assert.ThrowsAsync<HttpRequestException>(() => system.AnswerAsync("Q?"));
    }

    [Test]
    public void An_unknown_version_fails_loudly()
    {
        using ServiceProvider services = TestHost.Services(new FakeRag([]));
        var ex = Assert.Throws<ArgumentException>(() => services.GetRequiredService<QaSystemFactory>().Build("v3"));
        Assert.That(ex!.Message, Does.Contain("v1 | v2 | frozen"));
    }

    [Test]
    public async Task Frozen_replays_the_recorded_output_for_every_example()
    {
        using ServiceProvider services = TestHost.Services(new FakeRag([]));
        var settings = services.GetRequiredService<EvalSettings>();
        IQaSystem system = services.GetRequiredService<QaSystemFactory>().Build("frozen");
        foreach (EvalExample ex in Dataset.Load(settings.DatasetPath))
            Assert.That(await system.AnswerAsync(ex.Input), Is.Not.Empty);
    }

    [Test]
    public void The_loader_rejects_a_row_without_a_reference()
    {
        string path = Path.GetTempFileName();
        File.WriteAllText(path, """{"id": "q1", "input": "Q?"}""" + "\n");
        var ex = Assert.Throws<InvalidDataException>(() => Dataset.Load(path));
        Assert.That(ex!.Message, Does.Contain("missing reference"));
    }

    [Test]
    public void The_loader_rejects_a_duplicate_id()
    {
        string path = Path.GetTempFileName();
        string row = """{"id": "q1", "input": "Q?", "reference": "A."}""" + "\n";
        File.WriteAllText(path, row + row);
        var ex = Assert.Throws<InvalidDataException>(() => Dataset.Load(path));
        Assert.That(ex!.Message, Does.Contain("duplicate id"));
    }
}
```

```csharp
// tests/EvalHarness.Tests/GateTests.cs
using EvalHarness;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness.Tests;

/// <summary>The whole pipeline, offline: a fake 07, the stub judge, the hashing embedder. Mirrors test_gate.py.</summary>
public class GateTests
{
    private static string Verdict(int score) => $$"""{"score": {{score}}, "reason": "scripted"}""";

    private static async Task<RunResult> RunAsync(string version, Dictionary<string, string> answers, int judgeScore)
    {
        using ServiceProvider services = TestHost.Services(new FakeRag(answers), ("LLM_STUB_REPLY", Verdict(judgeScore)));
        var settings = services.GetRequiredService<EvalSettings>();
        IQaSystem system = services.GetRequiredService<QaSystemFactory>().Build(version);
        return await services.GetRequiredService<EvalRunner>().RunAsync(system, Dataset.Load(settings.DatasetPath));
    }

    private static IReadOnlyList<EvalExample> DatasetRows() =>
        Dataset.Load(new EvalSettings(TestHost.Config()).DatasetPath);

    [Test]
    public async Task The_gate_passes_a_good_system_and_fails_a_regression()
    {
        RunResult good = await RunAsync("v2", DatasetRows().ToDictionary(ex => ex.Input, ex => ex.Reference), judgeScore: 5);
        Assert.That(Scorecard.PassesGate(good).Ok, Is.True);

        RunResult bad = await RunAsync("v2", DatasetRows().ToDictionary(ex => ex.Input, _ => "I'm not sure."), judgeScore: 1);
        var (ok, failures) = Scorecard.PassesGate(bad);
        Assert.That(ok, Is.False);
        Assert.That(failures.Select(f => f.Split('=')[0]), Is.EqualTo(new[] { "contains_all", "similarity", "judge" }));
    }

    [Test]
    public async Task The_frozen_scorecard()
    {
        // Pinned numbers. test_gate.py pins the same ones: a drift on either side fails its own build.
        RunResult run = await RunAsync("frozen", [], judgeScore: 4);
        var agg = run.Aggregate();
        Assert.That(run.PerExample.Select(r => r.Id), Is.EqualTo(new[] { "q1", "q2", "q3", "q4", "q5", "q6" }));
        Assert.That(agg["exact_match"], Is.EqualTo(1.0 / 6));
        Assert.That(agg["contains_all"], Is.EqualTo(5.0 / 6));
        Assert.That(agg["judge"], Is.EqualTo(0.75));
        Assert.That(Math.Round(agg["similarity"], 3), Is.EqualTo(0.817));   // hashing: lexical overlap, not meaning
        Assert.That((run.JudgeTokens, run.JudgeInvalid), Is.EqualTo((536L, 0)));   // the stub counts words
    }
}
```

### `tests/EvalHarness.Tests/EvalGateTests.cs`

This is the point. When quality regresses, `dotnet test` exits non-zero and the build goes red.

```csharp
// tests/EvalHarness.Tests/EvalGateTests.cs
using EvalHarness;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace EvalHarness.Tests;

/// <summary>
/// THE gate: the real system, the real judge. Category Eval, which eval.runsettings excludes by default;
/// run it with dotnet test --settings eval.runsettings -- 'NUnit.Where=cat == Eval'.
/// </summary>
[TestFixture, Category("Eval")]
public class EvalGateTests
{
    private ServiceProvider _services = null!;
    private EvalSettings _settings = null!;
    private EvalRunner _runner = null!;
    private IQaSystem _system = null!;
    private readonly Dictionary<string, ExampleResult> _results = [];   // each example runs once per fixture

    // NUnit evaluates sources before OneTimeSetUp, so this reads the environment itself.
    public static IEnumerable<TestCaseData> Examples() =>
        Dataset.Load(new EvalSettings(new ConfigurationBuilder().AddEnvironmentVariables().Build()).DatasetPath)
            .Select(ex => new TestCaseData(ex).SetName($"Example_{ex.Id}"));

    [OneTimeSetUp]
    public void SetUp()
    {
        IConfiguration config = new ConfigurationBuilder().AddEnvironmentVariables().Build();
        _services = new ServiceCollection().AddEvalHarness(config).BuildServiceProvider();
        _settings = _services.GetRequiredService<EvalSettings>();
        _runner = _services.GetRequiredService<EvalRunner>();   // holds the judge: from JUDGE_MODEL, never the system
        _system = _services.GetRequiredService<QaSystemFactory>().Build(_settings.SystemVersion);
    }

    [OneTimeTearDown]
    public void TearDown() => _services.Dispose();

    private async Task<ExampleResult> ScoreAsync(EvalExample ex)
    {
        if (!_results.TryGetValue(ex.Id, out ExampleResult? result))
            _results[ex.Id] = result = await _runner.RunOneAsync(_system, ex);
        return result;
    }

    // One test per example: visible in Test Explorer, never fails on its own.
    [TestCaseSource(nameof(Examples))]
    public async Task Example(EvalExample ex)
    {
        ExampleResult r = await ScoreAsync(ex);
        TestContext.Out.WriteLine(string.Join(", ", r.Scores.Select(s => $"{s.Key}={s.Value:F3}")));
        TestContext.Out.WriteLine($"output: {r.Output}");
    }

    // The gate. Order-independent: it scores any example the per-example tests haven't.
    [Test]
    public async Task Quality_does_not_regress()
    {
        var run = new RunResult();
        foreach (EvalExample ex in Dataset.Load(_settings.DatasetPath))
            run.PerExample.Add(await ScoreAsync(ex));

        TestContext.Out.WriteLine(Scorecard.Render(run, _settings.SystemVersion));
        string path = await Scorecard.WriteJsonAsync(run, _settings.SystemVersion, _settings.OutDir);
        TestContext.Out.WriteLine($"scorecard: {path}");
        TestContext.AddTestAttachment(path, "scorecard");

        var (ok, failures) = Scorecard.PassesGate(run);
        Assert.That(ok, Is.True, $"Eval gate failed: {string.Join("; ", failures)}");
    }
}
```

Why the cache: NUnit doesn't promise that the per-example tests run before the gate, and a filter can skip them entirely. Each example is scored at most once per run, whichever test asks first, so the model bill doesn't double.

### Keeping the gate out of `dotnet test`

Two run-settings files at the `csharp/` root. `unit.runsettings` is the default, because the test project names it:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- The default for dotnet test (the test project points at it): everything except the eval gate. -->
<RunSettings>
  <RunConfiguration>
    <TestCaseFilter>TestCategory!=Eval</TestCaseFilter>
  </RunConfiguration>
</RunSettings>
```

```xml
<!-- tests/EvalHarness.Tests/EvalHarness.Tests.csproj, in the first PropertyGroup -->
<RunSettingsFilePath>$(MSBuildThisFileDirectory)..\..\unit.runsettings</RunSettingsFilePath>
```

`eval.runsettings` selects only the gate, and a `--settings` on the command line replaces the default:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- Only the eval gate (the Eval category). Opt in by passing this file as the test settings. -->
<RunSettings>
  <RunConfiguration>
    <TestCaseFilter>TestCategory=Eval</TestCaseFilter>
  </RunConfiguration>
</RunSettings>
```

Use the file, not `--filter "TestCategory=Eval"`: a command-line filter is *combined* with the run-settings one, so against the default it becomes `(TestCategory!=Eval)&(TestCategory=Eval)` and matches nothing.

Run locally (the same offline-then-live order as Python):

```powershell
dotnet test                                      # unit tests: fast, free, no model, no network

$env:LLM_BACKEND = 'stub'; $env:LLM_STUB_REPLY = '{"score": 4, "reason": "stub"}'; $env:EMBED_BACKEND = 'hashing'
dotnet run --project src/EvalHarness.Cli -- compare frozen    # writes outputs/scorecard-frozen.json

# Live: 07 running and ingested, Ollama with the judge and embedding models pulled.
Remove-Item Env:LLM_STUB_REPLY, Env:EMBED_BACKEND -ErrorAction SilentlyContinue
ollama pull llama3.2; ollama pull all-minilm
$env:LLM_BACKEND = 'ollama'; $env:JUDGE_MODEL = 'llama3.2'; $env:RAG_URL = 'http://localhost:8000'   # C# 07: 8001
dotnet run --project src/EvalHarness.Cli -- compare                         # v1 and v2
dotnet test --settings eval.runsettings --logger "console;verbosity=detailed"   # the gate; exit code is the CI signal
$env:SYSTEM_VERSION = 'v1'; dotnet test --settings eval.runsettings
```

### Where Microsoft.Extensions.AI.Evaluation fits

This harness is hand-rolled on purpose, like the Python one, so you see every piece. The .NET library for this job is **Microsoft.Extensions.AI.Evaluation**, the counterpart of Python eval frameworks like RAGAS or DeepEval. It's a family of packages:

- `Microsoft.Extensions.AI.Evaluation`: the core abstractions (`IEvaluator`, `EvaluationResult`, metrics such as `NumericMetric`).
- `Microsoft.Extensions.AI.Evaluation.Quality`: LLM-judged evaluators for qualities like relevance, coherence, fluency, groundedness and completeness.
- `Microsoft.Extensions.AI.Evaluation.Reporting`: caches model responses between runs, stores results, and generates HTML reports, with a `dotnet` tool (`aieval`) to produce them.

The shape, roughly. Evaluator class and metric names have changed between releases, so check the current docs before copying:

```csharp
// Shape only. Verify evaluator and metric names against the current package docs.
IEvaluator evaluator = new CoherenceEvaluator();
EvaluationResult result = await evaluator.EvaluateAsync(messages, response, new ChatConfiguration(judgeClient));
NumericMetric coherence = result.Get<NumericMetric>(CoherenceEvaluator.CoherenceMetricName);
```

What it adds over this harness: tested judge prompts, response caching so re-runs don't re-bill, and reporting. What it doesn't remove: you still need your own labeled set, your own thresholds, and a validated judge. Its built-in evaluators are LLM judges, and everything in "LLM-as-judge, and its traps" applies to them. Adopt it once you've felt the pain it solves, the same rule as agent frameworks in module 08.

### Running the C# version in Docker

Same context as the Python image, `projects/`, for the same reason: the `ProjectReference` to 04. The unit tests run during the build, so a broken metric never makes an image; the `test` stage runs the gate.

```dockerfile
# projects/09-eval-harness/csharp/Dockerfile — build context: projects/
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer: every .csproj, plus 04's Directory.Build.props (MSBuild applies the nearest one).
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 09-eval-harness/csharp/EvalHarness.slnx 09-eval-harness/csharp/Directory.Build.props 09-eval-harness/csharp/
COPY 09-eval-harness/csharp/src/EvalHarness/EvalHarness.csproj 09-eval-harness/csharp/src/EvalHarness/
COPY 09-eval-harness/csharp/src/EvalHarness.Cli/EvalHarness.Cli.csproj 09-eval-harness/csharp/src/EvalHarness.Cli/
COPY 09-eval-harness/csharp/tests/EvalHarness.Tests/EvalHarness.Tests.csproj 09-eval-harness/csharp/tests/EvalHarness.Tests/
WORKDIR /src/09-eval-harness/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 09-eval-harness/csharp/ 09-eval-harness/csharp/
COPY 09-eval-harness/fixtures/ 09-eval-harness/fixtures/
WORKDIR /src/09-eval-harness/csharp
# The unit tests gate the image: no model, no network (unit.runsettings skips the Eval category).
RUN dotnet test --no-restore
RUN dotnet publish src/EvalHarness.Cli -c Release -o /app --no-restore

# The eval gate: needs a model and the system under test. A non-zero exit fails CI.
FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore", "--settings", "eval.runsettings", "--logger", "console;verbosity=normal"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 09-eval-harness/fixtures/ ./fixtures/
# Scorecards go to EVAL_OUT_DIR, so the non-root user must own it.
RUN mkdir outputs && chown "$APP_UID" outputs
ENV FIXTURES_DIR=/app/fixtures \
    EVAL_OUT_DIR=/app/outputs
USER $APP_UID
ENTRYPOINT ["dotnet", "EvalHarness.Cli.dll"]
CMD ["compare", "v1", "v2"]
```

```yaml
# projects/09-eval-harness/csharp/compose.yaml
name: eval-harness-cs   # otherwise the project is named after the folder: "csharp"

x-eval-env: &eval-env
  LLM_BACKEND: ${LLM_BACKEND:-ollama}   # the JUDGE's backend: the system under test is 07, over HTTP
  OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
  JUDGE_MODEL: ${JUDGE_MODEL:-llama3.2}
  OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-all-minilm}
  EMBED_BACKEND: ${EMBED_BACKEND:-ollama}
  SYSTEM_VERSION: ${SYSTEM_VERSION:-v2}
  RAG_URL: ${RAG_URL:-http://host.docker.internal:8000}   # 07 on the host: Python 8000, C# 8001

services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  eval:   # the gate
    build: { context: ../.., dockerfile: 09-eval-harness/csharp/Dockerfile, target: test }   # projects/: 04 must be inside
    env_file:
      - path: .env   # same variables as the Python .env.example; optional
        required: false
    environment:
      <<: *eval-env
      EVAL_OUT_DIR: /out
    volumes: ["./outputs:/out"]   # the scorecard JSON lands here (git-ignored)
    extra_hosts: ["host.docker.internal:host-gateway"]

  compare:
    build: { context: ../.., dockerfile: 09-eval-harness/csharp/Dockerfile, target: final }
    env_file:
      - path: .env
        required: false
    environment: *eval-env
    extra_hosts: ["host.docker.internal:host-gateway"]

volumes:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

```powershell
cd projects/09-eval-harness/csharp
docker compose run --rm eval                     # the gate; exit code is the CI signal; scorecard in ./outputs
docker compose run --rm compare                  # A/B the two versions
# Without compose (from the repo root):
# docker build -f projects/09-eval-harness/csharp/Dockerfile --target test -t eval-harness-cs projects
```

### The CI gate, both languages

One workflow, one job per language; either failing blocks the merge. Each job runs Ollama as a service container for the judge, starts module 07 in the same language on the runner, ingests, then runs the unit tests and the gate. CPU runners make this slow, which is fine for a set this size and a reason to keep the set small and sharp.

```yaml
# .github/workflows/eval-gate.yml
name: eval-gate
on: pull_request

env:
  LLM_BACKEND: ollama            # the judge's backend (07's compose reads it too)
  JUDGE_MODEL: llama3.2          # pinned: the same judge on every run
  SYSTEM_VERSION: v2
  # No OLLAMA_BASE_URL here: 07's compose would pass it into its container, where localhost is the container.

jobs:
  eval-python:
    runs-on: ubuntu-latest
    services:
      ollama: { image: "ollama/ollama", ports: ["11434:11434"] }
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
      - name: Pull the judge and 07's model
        run: curl -sf http://localhost:11434/api/pull -d '{"model": "llama3.2"}'
      - name: Start module 07 and ingest
        working-directory: projects/07-rag-service/python
        run: |
          docker compose up -d --build
          until curl -sf localhost:8000/health; do sleep 2; done
          curl -sf -X POST localhost:8000/ingest
      - name: Unit tests, then the gate
        working-directory: projects/09-eval-harness/python
        env:
          RAG_URL: http://localhost:8000
        run: |
          uv run pytest
          uv run pytest -m eval -v -s
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: scorecard-python, path: projects/09-eval-harness/python/outputs }

  eval-csharp:
    runs-on: ubuntu-latest
    services:
      ollama: { image: "ollama/ollama", ports: ["11434:11434"] }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with: { dotnet-version: "10.0.x" }
      - name: Pull the judge, the embedder and 07's model
        run: |
          curl -sf http://localhost:11434/api/pull -d '{"model": "llama3.2"}'
          curl -sf http://localhost:11434/api/pull -d '{"model": "all-minilm"}'
      - name: Start module 07 and ingest
        working-directory: projects/07-rag-service/csharp
        run: |
          docker compose up -d --build
          until curl -sf localhost:8001/health; do sleep 2; done
          curl -sf -X POST localhost:8001/ingest
      - name: Unit tests, then the gate
        working-directory: projects/09-eval-harness/csharp
        env:
          RAG_URL: http://localhost:8001
        run: |
          dotnet test
          dotnet test --settings eval.runsettings --logger trx
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: scorecard-csharp, path: projects/09-eval-harness/csharp/outputs }
```

The `if: always()` matters: the scorecard is most useful exactly when the gate fails. To judge with a hosted model instead, set `LLM_BACKEND: hosted`, `JUDGE_MODEL` to its model name, `LLM_BASE_URL`, the `Rates__*` pair, and `LLM_API_KEY: ${{ secrets.LLM_API_KEY }}`.

## Labelled reviews as an eval set

This is where the [R track](R-reviewing-ai-written-code.md#from-reviews-to-a-module-09-eval-set) converges with this module. Your hand-labelled reviews become an eval set, and an LLM judge using your rubric becomes the *system under test*. The R track defines the row format, `{"id", "input": {"claim", "diff"}, "expected"}` in `projects/review-lab/rubric/eval_set.jsonl`, with `expected` one of the four review labels.

```python
# evalkit/rubric.py
from __future__ import annotations

from dataclasses import dataclass

from llm_client.types import LlmClient, Message

# The R track's four review labels (docs/R-reviewing-ai-written-code.md#rubric-and-agreement).
LABELS = ("accept", "accept-with-nits", "reject-incorrect", "reject-gamed")
INVALID = "invalid"   # anything else the judge says: counted wrong, never guessed


def build_prompt(rubric: str, claim: str, diff: str) -> str:
    """rubric.md is the instructions; the review's claim and diff are the item."""
    return (
        f"{rubric.strip()}\n\n"
        "Label the change below using the rubric above.\n"
        f"What the agent claimed: {claim}\n"
        f"The diff:\n{diff}\n\n"
        f"Answer with exactly one label: {' | '.join(LABELS)}"
    )


def parse_label(raw: str) -> str:
    """One of LABELS, or INVALID. Forgives case and wrapping punctuation, nothing else."""
    label = raw.strip().strip("`*.\"'").strip().lower()
    return label if label in LABELS else INVALID


@dataclass(frozen=True)
class Labeled:
    id: str
    label: str      # the judge's
    expected: str   # yours


async def label_reviews(rows: list[dict], rubric: str, client: LlmClient) -> list[Labeled]:
    """Ask the judge for one label per review row: {"id", "input": {"claim", "diff"}, "expected"}."""
    labeled = []
    for row in rows:
        prompt = build_prompt(rubric, row["input"]["claim"], row["input"]["diff"])
        reply = await client.complete([Message("user", prompt)])
        labeled.append(Labeled(row["id"], parse_label(reply.text), row["expected"]))
    return labeled


def accuracy(labeled: list[Labeled]) -> float:
    """Exact label match: no partial credit, and INVALID is always wrong."""
    if not labeled:
        raise ValueError("no labeled rows")
    return sum(x.label == x.expected for x in labeled) / len(labeled)
```

```python
# rubric_judge.py
"""Label review-lab's eval set with an LLM judge, using the rubric as its prompt:
uv run python rubric_judge.py <rubric.md> <eval_set.jsonl> <labels_out.jsonl>"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from evalkit.dataset import read_jsonl
from evalkit.judge import judge_client_from_env
from evalkit.rubric import INVALID, accuracy, label_reviews


async def main(rubric_path: str, eval_set_path: str, labels_out: str) -> None:
    rows = read_jsonl(eval_set_path)
    # Here the judge IS the system under test: JUDGE_MODEL names the model you're calibrating.
    labeled = await label_reviews(rows, Path(rubric_path).read_text(encoding="utf-8"), judge_client_from_env())
    out = Path(labels_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # {"id", "label"} lines: the format review-lab's rubric/agreement.py reads.
    out.write_text("".join(json.dumps({"id": x.id, "label": x.label}) + "\n" for x in labeled), encoding="utf-8")
    invalid = sum(x.label == INVALID for x in labeled)
    print(f"items={len(labeled)} accuracy={accuracy(labeled):.2f} invalid={invalid}")
    for x in labeled:
        if x.label != x.expected:
            print(f"  {x.id}: judge={x.label} you={x.expected}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: rubric_judge.py <rubric.md> <eval_set.jsonl> <labels_out.jsonl>")
    asyncio.run(main(*sys.argv[1:]))
```

```python
# tests/test_rubric.py
"""The R track's review labels as an eval set: the judge is the system under test."""
import pytest
from llm_client.stub import StubClient

from evalkit.rubric import INVALID, accuracy, label_reviews, parse_label


@pytest.mark.parametrize("raw, expected", [
    ("reject-gamed", "reject-gamed"),
    ("  Accept-With-Nits.\n", "accept-with-nits"),
    ("**reject-incorrect**", "reject-incorrect"),
    ("`accept`", "accept"),
    ("I'd accept it", INVALID),          # a sentence isn't a label
    ("reject", INVALID),                 # neither is half of one
])
def test_parse_label_forgives_case_and_wrapping_only(raw, expected):
    assert parse_label(raw) == expected


async def test_label_reviews_scores_exact_label_match():
    rows = [
        {"id": "r1", "input": {"claim": "added retries", "diff": "+retry"}, "expected": "reject-incorrect"},
        {"id": "r2", "input": {"claim": "fixed typo", "diff": "-teh +the"}, "expected": "accept"},
        {"id": "r3", "input": {"claim": "tests pass", "diff": "+skip"}, "expected": "reject-gamed"},
    ]
    judge = StubClient(["reject-incorrect", "accept-with-nits", "looks fine to me"])
    labeled = await label_reviews(rows, "# Rubric\n...", judge)
    assert [(x.id, x.label) for x in labeled] == [("r1", "reject-incorrect"), ("r2", "accept-with-nits"), ("r3", INVALID)]
    assert accuracy(labeled) == 1 / 3
```

The C# twin is `Rubric.cs` and the CLI's `rubric` command, with the same prompt, the same label parsing and the same output:

```csharp
// src/EvalHarness/Rubric.cs
using Microsoft.Extensions.AI;

namespace EvalHarness;

public sealed record ReviewInput(string Claim, string Diff);
public sealed record ReviewRow(string Id, ReviewInput Input, string Expected);
public sealed record Labeled(string Id, string Label, string Expected);

/// <summary>The R track's review labels as an eval set: here the judge is the system under test.</summary>
public static class Rubric
{
    public static readonly string[] Labels = ["accept", "accept-with-nits", "reject-incorrect", "reject-gamed"];
    public const string Invalid = "invalid";   // anything else the judge says: counted wrong, never guessed

    /// <summary>rubric.md is the instructions; the review's claim and diff are the item. Python's build_prompt, char for char.</summary>
    public static string BuildPrompt(string rubric, string claim, string diff) =>
        $"{rubric.Trim()}\n\n" +
        "Label the change below using the rubric above.\n" +
        $"What the agent claimed: {claim}\n" +
        $"The diff:\n{diff}\n\n" +
        $"Answer with exactly one label: {string.Join(" | ", Labels)}";

    /// <summary>One of <see cref="Labels"/>, or <see cref="Invalid"/>. Forgives case and wrapping punctuation, nothing else.</summary>
    public static string ParseLabel(string raw)
    {
        string label = raw.Trim().Trim('`', '*', '.', '"', '\'').Trim().ToLowerInvariant();
        return Labels.Contains(label) ? label : Invalid;
    }

    public static async Task<IReadOnlyList<Labeled>> LabelReviewsAsync(
        IEnumerable<ReviewRow> rows, string rubric, IChatClient judge, CancellationToken ct = default)
    {
        var labeled = new List<Labeled>();
        foreach (ReviewRow row in rows)
        {
            ChatResponse reply = await judge.GetResponseAsync(
                BuildPrompt(rubric, row.Input.Claim, row.Input.Diff), new ChatOptions { Temperature = 0f }, ct);
            labeled.Add(new Labeled(row.Id, ParseLabel(reply.Text), row.Expected));
        }
        return labeled;
    }

    /// <summary>Exact label match: no partial credit, and Invalid is always wrong.</summary>
    public static double Accuracy(IReadOnlyList<Labeled> labeled) =>
        labeled.Count == 0
            ? throw new ArgumentException("no labeled rows")
            : (double)labeled.Count(x => x.Label == x.Expected) / labeled.Count;
}
```

```csharp
// tests/EvalHarness.Tests/RubricTests.cs
using EvalHarness;
using LlmClient;

namespace EvalHarness.Tests;

/// <summary>The R track's review labels as an eval set: the judge is the system under test. Mirrors test_rubric.py.</summary>
public class RubricTests
{
    [TestCase("reject-gamed", "reject-gamed")]
    [TestCase("  Accept-With-Nits.\n", "accept-with-nits")]
    [TestCase("**reject-incorrect**", "reject-incorrect")]
    [TestCase("`accept`", "accept")]
    [TestCase("I'd accept it", Rubric.Invalid)]   // a sentence isn't a label
    [TestCase("reject", Rubric.Invalid)]          // neither is half of one
    public void ParseLabel_forgives_case_and_wrapping_only(string raw, string expected) =>
        Assert.That(Rubric.ParseLabel(raw), Is.EqualTo(expected));

    [Test]
    public async Task LabelReviews_scores_exact_label_match()
    {
        ReviewRow[] rows =
        [
            new("r1", new("added retries", "+retry"), "reject-incorrect"),
            new("r2", new("fixed typo", "-teh +the"), "accept"),
            new("r3", new("tests pass", "+skip"), "reject-gamed"),
        ];
        var judge = new StubChatClient(["reject-incorrect", "accept-with-nits", "looks fine to me"]);
        IReadOnlyList<Labeled> labeled = await Rubric.LabelReviewsAsync(rows, "# Rubric\n...", judge);
        Assert.That(labeled.Select(x => (x.Id, x.Label)),
            Is.EqualTo(new[] { ("r1", "reject-incorrect"), ("r2", "accept-with-nits"), ("r3", Rubric.Invalid) }));
        Assert.That(Rubric.Accuracy(labeled), Is.EqualTo(1.0 / 3));
    }
}
```

Run it against review-lab with the model you're calibrating as `JUDGE_MODEL`, then score the labels with the R track's agreement script. From `projects/09-eval-harness/python`:

```powershell
$env:LLM_BACKEND = 'ollama'; $env:JUDGE_MODEL = 'llama3.2'
uv run python rubric_judge.py ../../review-lab/rubric/rubric.md ../../review-lab/rubric/eval_set.jsonl ../../review-lab/rubric/labels/judge_llama3.2.jsonl
# C#, from ../csharp: dotnet run --project src/EvalHarness.Cli -- rubric <the same three paths>
cd ../../review-lab
uv run python rubric/agreement.py rubric/labels/me_round2.jsonl rubric/labels/judge_llama3.2.jsonl
```

`rubric_judge.py` prints exact-label accuracy and the disagreements; `agreement.py` prints Cohen's kappa. Report both, for the reason the R track gives: when one label dominates, accuracy flatters a judge that always says it, and kappa doesn't. Your own round-1 vs round-2 kappa is the ceiling. This is the "validate the judge against humans" step from this module's theory, with you as the human, and it's the evidence you need before letting any judge gate a merge.

## Cross-check the two

Two harnesses scoring a live system will never agree exactly, because the system's answers change between runs. So cross-check the **harness** first, on frozen answers, then the scores.

**Exact, offline.** Score `fixtures/qa_outputs.jsonl` in both languages with the stub judge and the hashing embedder, then diff the two scorecard JSONs with `crosscheck.py`. From `projects/09-eval-harness`:

```powershell
$env:LLM_BACKEND = 'stub'; $env:LLM_STUB_REPLY = '{"score": 4, "reason": "stub"}'; $env:EMBED_BACKEND = 'hashing'
cd python; uv run python compare.py frozen
cd ../csharp; dotnet run --project src/EvalHarness.Cli -- compare frozen
cd ../python; uv run python crosscheck.py outputs/scorecard-frozen.json ../csharp/outputs/scorecard-frozen.json
# 6 examples: MATCH
```

```python
# crosscheck.py
"""Diff two scorecard JSONs, e.g. Python's and C#'s for the same frozen outputs:
uv run python crosscheck.py <a.json> <b.json> [--similarity-tol 1e-6] [--judge-tol 0]"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

RULES = ("exact_match", "contains_all")   # string rules and arithmetic: always exact


def check(a: dict, b: dict, similarity_tol: float, judge_tol: float) -> list[str]:
    ids_a = [r["id"] for r in a["per_example"]]
    ids_b = [r["id"] for r in b["per_example"]]
    if ids_a != ids_b:
        return [f"ids differ: {ids_a} vs {ids_b}"]
    problems = []
    for ra, rb in zip(a["per_example"], b["per_example"]):
        for k in RULES:
            if ra["scores"][k] != rb["scores"][k]:
                problems.append(f"{ra['id']} {k}: {ra['scores'][k]} vs {rb['scores'][k]}")
        if abs(ra["scores"]["similarity"] - rb["scores"]["similarity"]) > similarity_tol:
            problems.append(f"{ra['id']} similarity: {ra['scores']['similarity']} vs {rb['scores']['similarity']}")
        # A scripted (stub) judge must agree per example, token counts included.
        if judge_tol == 0 and (ra["scores"]["judge"], ra["judge_tokens"]) != (rb["scores"]["judge"], rb["judge_tokens"]):
            problems.append(f"{ra['id']} judge/tokens: {ra['scores']['judge']}/{ra['judge_tokens']} "
                            f"vs {rb['scores']['judge']}/{rb['judge_tokens']}")
    # A live judge only has to agree on the aggregate.
    if abs(a["aggregate"]["judge"] - b["aggregate"]["judge"]) > judge_tol:
        problems.append(f"aggregate judge: {a['aggregate']['judge']} vs {b['aggregate']['judge']}")
    return problems


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--similarity-tol", type=float, default=1e-6)
    p.add_argument("--judge-tol", type=float, default=0.0)
    args = p.parse_args()
    a, b = (json.loads(Path(x).read_text(encoding="utf-8")) for x in (args.a, args.b))
    problems = check(a, b, args.similarity_tol, args.judge_tol)
    for line in problems:
        print(line)
    print(f"{len(a['per_example'])} examples: {'MATCH' if not problems else f'{len(problems)} difference(s)'}")
    sys.exit(1 if problems else 0)
```

On the stub everything must match: the example ids, `exact_match` and `contains_all` per example, the judge's score and token count per example (536 in total), and `similarity` to within `1e-6` (measured: 7e-8, float32 in C# against float64 in numpy). A mismatch is a harness bug. The same numbers are pinned in `test_gate.py` and `GateTests.cs`, so drift fails a build before you even run this. The usual culprits:

- **Case folding.** `str.lower()` and `OrdinalIgnoreCase` agree on ASCII. Non-ASCII text is where they can diverge.
- **The prompt.** One changed character in either judge prompt changes the stub's token count, which is exactly why the count is compared.
- **JSON.** C# writes `don't` as `don't` unless the encoder is relaxed. Both parse to the same string, but a raw-text diff would flag it.

The same check works against a live 07. With C# 07 running on its offline seams and `$env:RAG_URL = 'http://localhost:8001'`, `compare v1 v2` in both languages gives scorecards that `crosscheck.py` reports as matching. Look at them, too: on the stub, 07's "answer" echoes its prompt, so `contains_all` climbs from 0.50 at `k=1` to 0.83 at `k=4` with no model in the loop. More text contains more substrings. That's a metric gamed by length, the same bias you watch for in judges.

**Approximate, on real models.** Clear the three variables, set `JUDGE_MODEL`, run the same two `compare frozen` commands, and compare with tolerances:

```powershell
uv run python crosscheck.py outputs/scorecard-frozen.json ../csharp/outputs/scorecard-frozen.json --similarity-tol 0.02 --judge-tol 0.1
```

- **Must still match exactly:** the ids, `exact_match`, `contains_all`, and the gate decision for a given set of aggregates. These are string rules and arithmetic.
- **Should match to about two decimal places:** `similarity`. Both sides use all-MiniLM-L6-v2, but Python runs it through sentence-transformers and C# through Ollama, which may serve a lower-precision build. If they differ in the first decimal place, check that it's really the same model (384 dimensions).
- **Only approximately, on the aggregate:** `judge`. LLM judges vary run to run even at temperature 0 (both sides use 0), and C# sends a JSON schema while Python parses a plain-text score. Before you settle on `--judge-tol`, run each language twice: the run-to-run spread is the floor. A gap between the languages larger than that tells you how sensitive the judge is to small request changes, which is worth knowing before you let it gate merges.
- **Not comparable:** `latency_ms_p50`. Different runtimes, different clients, and on frozen answers it measures a dictionary lookup.

Only after the harnesses agree on frozen answers does it make sense to compare live scorecards from the two languages.

| Concern | Python | C# / .NET |
|---|---|---|
| Test runner | pytest, `@pytest.mark.eval`, `addopts = "-m 'not eval'"` | NUnit, `[Category("Eval")]`, `unit.runsettings` / `eval.runsettings` |
| Run the gate | `uv run pytest -m eval -s` | `dotnet test --settings eval.runsettings` |
| Data-driven cases | one test loops over the set | `[TestCaseSource]`, one test per example, plus the gate test |
| Eval set | `jsonl` in shared `fixtures/`, via `FIXTURES_DIR` | same file, same `FIXTURES_DIR` |
| Rule-based metrics | `str.strip().lower()`, `in` | `Trim()`, `OrdinalIgnoreCase` |
| Embeddings | sentence-transformers (in-process), or hashing | `IEmbeddingGenerator` (Ollama `all-minilm`), or hashing |
| Cosine | `numpy`, 0 for a zero vector | `TensorPrimitives.CosineSimilarity`, 0 for a zero vector |
| LLM judge | prompt + `json.loads` + strict int check | `GetResponseAsync<JudgeVerdict>` (structured output) + range check |
| Judge wiring | `judge_client_from_env()`: 04's factory with `JUDGE_MODEL` lent in | `AddEvalHarness`: 04's `AddLlmClient` over a config with `JUDGE_MODEL` laid on top |
| System under test | `httpx.AsyncClient` to 07; tests use `MockTransport` | named `HttpClient` to 07; tests swap the primary handler |
| Scorecard | printed, plus `outputs/scorecard-<version>.json` | the same, plus attached to the test result |
| Gate failure | `assert ok` → pytest exits non-zero | `Assert.That(ok, Is.True)` → `dotnet test` exits non-zero |
| Eval library | RAGAS, DeepEval, etc. | Microsoft.Extensions.AI.Evaluation (+ `.Quality`, `.Reporting`) |

## Moving to AWS

- **Evals in CI → CodeBuild** (or GitHub Actions against AWS). Same container, run on every PR; a failing gate blocks the merge. Nothing exotic: it's your existing CI muscle pointed at a quality metric instead of a compile.
- **Scorecards → S3.** Both harnesses already write `scorecard-<version>.json`. Upload each run's file to a bucket keyed by commit and version, and you have a durable, queryable history of quality over time: the raw material for "did quality trend down over the last month?"
- **Dashboards later.** Those stored scorecards feed the observability dashboards in **11** and the production monitoring in **12**: offline eval history and online metrics in one view.
- Keep the eval **dataset in git** even as scorecards go to S3: the data is code, the results are artifacts.

The seams per language:

- **Python:** `write_json` produces the file; the buildspec runs `aws s3 cp` on `outputs/`, or the harness calls `boto3`'s `put_object`. The judge moves to Bedrock when module 12 adds `LLM_BACKEND=bedrock` to module 04's library: `judge_client_from_env()` already lends `JUDGE_MODEL` to `BEDROCK_MODEL_ID`.
- **C#:** `Scorecard.WriteJsonAsync` writes the same file, so the buildspec can `aws s3 cp` the `outputs` folder, or the harness can upload with the `AWSSDK.S3` package (`PutObjectAsync`). The judge follows `AddLlmClient` to Bedrock the same way. The embedder needs a Bedrock-backed `IEmbeddingGenerator` behind a new `EMBED_BACKEND` value (`AWSSDK.Extensions.Bedrock.MEAI`; check its docs for the current method names). The metrics, runner and gate don't change.
- **Both:** if the judge model changes, re-validate it against your human labels before trusting its scores. A new judge is a new measuring instrument, and so is a new embedding model: recalibrate the similarity threshold.

The AWS specifics (CodeBuild buildspec, S3 layout) change, so check current docs, but "container runs eval, gate blocks merge, results archived, trend watched" is the durable shape.

## How experts think / common pitfalls

- **No eval, no opinion.** The senior reflex to "I improved the prompt" is "show me the number on the eval set." Refuse to tune by feel; it's the defining habit.
- **Build the eval set before optimizing, and grow it from real failures.** Every bug becomes a permanent regression case. The set only ever gets stronger.
- **Layer cheap and expensive metrics.** Rule-based first (free, objective), similarity next, LLM-judge for the subjective — with human spot-checks keeping them honest.
- **Distrust your LLM judge until you've validated it against humans.** It's biased (length, position, sycophancy) and needs its own eval. An unvalidated judge is confident noise.
- **Beware overfitting to the eval set.** Hold out data you don't tune against; be alarmed when eval scores and user happiness diverge.
- **Cost and latency belong in the scorecard.** The highest-quality option is often not shippable. Decide on the whole vector, not one axis.
- **Reward abstention.** Include out-of-scope cases where "I don't know" is the correct answer, so you don't optimize your system into a confident liar.
- **The eval is a release gate, not a report.** If it doesn't block a bad merge, it's decoration.
- **A test runner is not an eval runner.** NUnit's `[TestCaseSource]` makes it tempting to assert on every example. Don't: one hard example would fail the build forever, and you'd end up deleting it from the set. Gate on the aggregate, report per example. Keep evals out of the default run too (pytest `addopts`, a default `.runsettings`), so a plain `uv run pytest` or `dotnet test` stays fast, free and offline.
- **The judge is an instrument: pin it.** Build it once, from its own setting (`JUDGE_MODEL`), never from the system under test. A judge that changes with the system turns every A/B into a measurement of the judge.
- **A threshold belongs to its instrument.** 0.70 similarity means something for all-MiniLM-L6-v2 and the way your references are written, nothing for another embedder. Calibrate it on known-good and known-bad answers, and recalibrate when either changes.
- **A broken judge must fail loudly.** Count unparseable verdicts separately and score them 0, so a judge outage fails the gate and the scorecard says why.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). **Convergence point:** the track's hand-labelled reviews meet this module's harness.

- **During the build:** write the track's [rubric](R-reviewing-ai-written-code.md#rubric-and-agreement) and run the first full calibration round (label 30, re-label blind a week later, run `agreement.py`).
- **Wire them together:** feed your labelled reviews to `09-eval-harness` with `rubric_judge.py` (or the C# `rubric` command), then run `agreement.py` on its output ([how](#labelled-reviews-as-an-eval-set)). Your labels are the human ground truth this module tells you to validate the judge against; measure the judge's kappa against you.
- **Red-team the spec:** before trusting the eval gate, ask how a change could pass it without improving quality. This module's own set has an answer: `contains_all` rewards length (on the stub, echoing more context raised it from 0.50 to 0.83), and `judge` is only as good as a judge you haven't validated yet.
- **C#-specific watch:** `Microsoft.Extensions.AI.Evaluation` evaluator classes, metric-name constants and `EvaluateAsync` overloads changed across its early releases, so agent-written code often uses names that no longer exist. NUnit 4 moved the classic asserts (`Assert.AreEqual`, `Assert.IsTrue`) to `ClassicAssert`, and agents still write the NUnit 3 forms; NUnit also requires `[TestCaseSource]` members to be static. Check the `IEmbeddingGenerator` calls against the current API (`GenerateAsync` vs older `GenerateEmbeddingAsync` / `GenerateEmbeddingVectorAsync` helpers), and make sure a "gate" test actually asserts. An eval test that only prints is the C# version of a gate that can't fail. Two quieter ones: `dotnet test --filter` is ANDed with a run-settings `TestCaseFilter`, so "run only the evals" written as a filter can silently select nothing; and an eval fixture that builds its judge from the same configuration as the system under test, which compiles, passes, and measures nothing.

## Checkpoint

This is the module to be hard on yourself about. You're ready for Phase 4 if you can:

- Explain precisely why `assertEqual` fails for LLM output and what replaces it.
- Describe the four eval types (rule-based, similarity, LLM-judge, human) and when to use each.
- List three biases of an LLM judge and how you'd validate one before trusting it.
- Name the right metrics for RAG, classification, and extraction — and split retrieval from generation quality.
- Describe where eval data comes from and why every production bug becomes a permanent eval case.
- Explain offline vs online eval, and how overfitting to an eval set happens and how to defend against it.
- Justify treating cost and latency as first-class metrics alongside quality.
- Build and run `09-eval-harness`: score a system, produce a scorecard, compare two versions, and make the eval gate fail CI on a regression.
- Make the same regression fail both `uv run pytest -m eval` and `dotnet test --settings eval.runsettings`, from the same eval set, while a plain `uv run pytest` and `dotnet test` stay offline and green.
- Explain why the judge is built from `JUDGE_MODEL` and never from the system's settings, and show a scorecard's `judge_invalid` count.
- Score frozen outputs in both harnesses, run `crosscheck.py` on the two scorecards, and say which metrics must match exactly, which only within tolerance, and why.
- Run the rubric judge over your review-lab eval set and report its accuracy and its kappa against your own labels.

If you can do these, you've crossed the line from "builds AI systems" to "engineers AI systems." Everything after this is production discipline layered on top of a foundation you can now *measure*.

## Going deeper

- The RAGAS framework's metric definitions (faithfulness, answer relevance, context precision/recall) for how the RAG-specific metrics are formalized.
- "Judging LLM-as-a-Judge" (Zheng et al., the MT-Bench work) for the empirical study of judge biases and pairwise vs pointwise reliability.
- Standard classification-metrics references (precision/recall/F1, confusion matrices) — the scikit-learn user guide is a solid, practical treatment (you'll use it again in 14).
- Writing on eval-set curation and regression-from-bugs practices from teams running LLMs in production — read a couple to see how the "test suite for AI" discipline plays out at scale.
- "Microsoft.Extensions.AI.Evaluation": the .NET evaluation libraries (`.Quality`, `.Reporting`, the `aieval` report tool). Read the current docs and samples, since names were still settling.
- "NUnit TestCaseSource" and "runsettings TestCaseFilter": data-driven tests, and keeping eval suites out of the default test run.
- "Microsoft.Extensions.AI structured output GetResponseAsync<T>": how the typed judge call builds its schema, and which providers enforce it.
- Revisit module 05 (prompts as tested artifacts) and 07 (`recall@k`) — this module is the rigorous version of the measurement instinct they introduced.

*Last verified: 2026-10-05. Built: Python (pytest 39 passed, 1 eval test deselected; pyright clean) and C# (dotnet test 39 passed, 7 Eval tests excluded by `unit.runsettings`) in a throwaway build against module 04's built library. Run: `compare frozen` in both languages on the stub judge and hashing embedder with `crosscheck.py` reporting a match (similarity within 7e-8); both gates (`pytest -m eval`, `dotnet test --settings eval.runsettings`) on frozen outputs; both harnesses' `compare v1 v2` against a running C# module 07 on its offline seams, matching; both `rubric` commands on a stub; the Python frozen scorecard with real all-MiniLM-L6-v2 embeddings (similarity 0.831; the numbers quoted under "The eval set"). Read-only: Docker images (compose files validated with `docker compose config`), the CI workflow, and every run with a live judge (Ollama or hosted) or Ollama's `all-minilm`.*

**Verify on first build:**

- That `GetResponseAsync<JudgeVerdict>` gets schema-constrained JSON from your Ollama model rather than prose (on the stub, which ignores the schema, the request text matched Python's exactly).
- The run-to-run spread of each language's judge score on the frozen set at temperature 0, before you pick a `--judge-tol`.
- That C#'s `all-minilm` similarities land within 0.02 of Python's sentence-transformers numbers on the frozen set.

Next: [10 — Serving & inference (local)](10-serving-and-inference-local.md), where Phase 4 begins and you start running open models yourself.
