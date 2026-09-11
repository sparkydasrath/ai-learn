# 09 — Evaluation & testing

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point.

This is the most important module in the series. If you internalize one thing from all seventeen, make it this: **quality is a number, not a feeling.** The difference between an AI engineer and a "vibe coder" is that the AI engineer can answer "did that change make it better?" with evidence. Everything before this module built systems. This module teaches you to know whether they work — and to keep knowing as models, prompts, and data drift underneath you.

## Where this fits

You've now built the things that need evaluating:

- **05** — prompts you've been tuning (by feel, if we're honest).
- **07** — a RAG pipeline with chunking and `k` knobs and no principled way to set them.
- **08** — an agent whose loop terminates but whose answers you can't grade.

Every one of those has an unanswered question hanging over it: *is it good, and did my last change help or hurt?* This module answers it. It also unblocks everything after: you can't safely deploy (12), control cost/quality trade-offs (13), or fine-tune (16) without evals. This is the hinge of the whole curriculum.

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

Quality is not the only number. A system that's 2% more accurate for 5× the cost and 3× the latency is usually a *worse* engineering choice. Track **tokens/cost per request** and **latency (p50/p95)** in the same scorecard as quality, so every comparison is quality *and* cost *and* speed — never quality alone. This is the accounting habit from modules 03/04 promoted to a release gate. The best-scoring model is frequently not the one you ship.

## The build project

**`projects/09-eval-harness/`** — a reusable, pytest-based eval harness that runs a system (reuse **05**'s prompt or **07**'s RAG) over a labeled dataset, computes **exact match**, **embedding similarity**, and an **LLM-as-judge** score, emits a **scorecard**, and **fails CI when the score drops below a threshold**. Includes a small curated eval set and a comparison of two prompt/model versions. Dockerized, and shown as a CI step.

### Layout

```
projects/09-eval-harness/
├── evalkit/
│   ├── __init__.py
│   ├── dataset.py          # load labeled examples (jsonl)
│   ├── metrics.py          # exact_match, embedding_similarity, llm_judge
│   ├── runner.py           # run system over dataset → scores
│   └── scorecard.py        # aggregate + render + threshold gate
├── systems/
│   └── qa_system.py        # thin adapter over the system under test (05/07)
├── data/
│   └── qa_eval.jsonl       # curated eval set: input → reference (+ criteria)
├── tests/
│   └── test_eval_gate.py   # pytest: FAILS if score < threshold
├── compare.py              # A/B two versions, print a diff
├── .env.example
├── pyproject.toml
├── Dockerfile
└── docker-compose.yml
```

### The eval set

```jsonl
{"id": "q1", "input": "How do I roll back a deploy?", "reference": "Run deploy --revert with the release SHA.", "must_include": ["revert"]}
{"id": "q2", "input": "When is a rollback still safe?", "reference": "Within 24 hours of the release.", "must_include": ["24"]}
{"id": "q3", "input": "What is the airspeed of an unladen swallow?", "reference": "I don't know based on the provided documents.", "must_include": ["don't know"]}
```

Note `q3`: an out-of-scope question whose *correct* answer is "I don't know." Your eval must reward abstention, or you're training your system to bluff.

### Metrics

```python
# evalkit/metrics.py
from __future__ import annotations

import numpy as np
from sentence_transformers import SentenceTransformer

_embed: SentenceTransformer | None = None


def _embedder() -> SentenceTransformer:
    global _embed
    if _embed is None:
        _embed = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _embed


def exact_match(output: str, reference: str) -> float:
    """1.0 if normalized strings match exactly, else 0.0. The cheapest signal."""
    return float(output.strip().lower() == reference.strip().lower())


def contains_all(output: str, required: list[str]) -> float:
    """Rule-based: fraction of required substrings present. Objective and free."""
    if not required:
        return 1.0
    hits = sum(1 for r in required if r.lower() in output.lower())
    return hits / len(required)


def embedding_similarity(output: str, reference: str) -> float:
    """Cosine similarity of output vs reference embeddings (the 07 math)."""
    vecs = _embedder().encode([output, reference])
    a, b = vecs[0], vecs[1]
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


JUDGE_PROMPT = """You are grading an answer for FAITHFULNESS and RELEVANCE.
Reference answer: {reference}
Candidate answer: {output}

Score 1-5 where 5 = fully correct and relevant, 1 = wrong or irrelevant.
Respond with ONLY a JSON object: {{"score": <int 1-5>, "reason": "<one sentence>"}}"""


def llm_judge(output: str, reference: str, call_model) -> float:
    """LLM-as-judge, normalized to 0-1. `call_model(prompt)->str` is your
    module-04 client. VALIDATE this judge against human labels before trusting it."""
    import json

    raw = call_model(JUDGE_PROMPT.format(reference=reference, output=output))
    try:
        score = int(json.loads(raw)["score"])
    except (json.JSONDecodeError, KeyError, ValueError):
        return 0.0
    return (score - 1) / 4  # map 1..5 → 0..1
```

### Runner and scorecard

```python
# evalkit/runner.py
from __future__ import annotations

import time
from dataclasses import dataclass, field

from evalkit.metrics import contains_all, embedding_similarity, exact_match, llm_judge


@dataclass
class ExampleResult:
    id: str
    scores: dict[str, float]
    latency_ms: float
    output: str


@dataclass
class RunResult:
    per_example: list[ExampleResult] = field(default_factory=list)

    def aggregate(self) -> dict[str, float]:
        if not self.per_example:
            return {}
        keys = self.per_example[0].scores.keys()
        agg = {k: sum(r.scores[k] for r in self.per_example) / len(self.per_example) for k in keys}
        agg["latency_ms_p50"] = sorted(r.latency_ms for r in self.per_example)[len(self.per_example) // 2]
        return agg


def run(dataset: list[dict], system, judge_model) -> RunResult:
    """Run `system(input)->str` over the dataset and score each example.
    Cost and latency are measured alongside quality — first-class metrics."""
    result = RunResult()
    for ex in dataset:
        start = time.perf_counter()
        output = system(ex["input"])
        latency = (time.perf_counter() - start) * 1000
        scores = {
            "exact_match": exact_match(output, ex["reference"]),
            "contains_all": contains_all(output, ex.get("must_include", [])),
            "similarity": embedding_similarity(output, ex["reference"]),
            "judge": llm_judge(output, ex["reference"], judge_model),
        }
        result.per_example.append(ExampleResult(ex["id"], scores, latency, output))
    return result
```

```python
# evalkit/scorecard.py
from __future__ import annotations

from evalkit.runner import RunResult


def render(run: RunResult, label: str) -> str:
    agg = run.aggregate()
    lines = [f"=== Scorecard: {label} ===", f"examples: {len(run.per_example)}"]
    lines += [f"  {k:20s} {v:.3f}" for k, v in agg.items()]
    return "\n".join(lines)


def passes_gate(run: RunResult, thresholds: dict[str, float]) -> tuple[bool, list[str]]:
    """Return (ok, failures). A metric below its threshold fails the gate."""
    agg = run.aggregate()
    failures = [
        f"{k}={agg.get(k, 0):.3f} < {v:.3f}"
        for k, v in thresholds.items()
        if agg.get(k, 0.0) < v
    ]
    return (not failures, failures)
```

### The CI gate (this is the point)

The eval *is* a pytest test. When quality regresses, the build goes red and the change doesn't merge — exactly like a failing unit test.

```python
# tests/test_eval_gate.py
from __future__ import annotations

import json
import os

import pytest

from evalkit.runner import run
from evalkit.scorecard import passes_gate, render
from systems.qa_system import build_system

THRESHOLDS = {"contains_all": 0.80, "similarity": 0.70, "judge": 0.75}


def _load(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


@pytest.mark.eval
def test_quality_does_not_regress():
    dataset = _load("data/qa_eval.jsonl")
    system = build_system(version=os.getenv("SYSTEM_VERSION", "v2"))
    judge = system.judge_model
    result = run(dataset, system, judge)
    print("\n" + render(result, label=os.getenv("SYSTEM_VERSION", "v2")))
    ok, failures = passes_gate(result, THRESHOLDS)
    assert ok, f"Eval gate failed: {failures}"
```

### Comparing two versions

```python
# compare.py
from __future__ import annotations

from evalkit.dataset import load
from evalkit.runner import run
from evalkit.scorecard import render
from systems.qa_system import build_system

if __name__ == "__main__":
    dataset = load("data/qa_eval.jsonl")
    for version in ("v1", "v2"):
        system = build_system(version=version)
        result = run(dataset, system, system.judge_model)
        print(render(result, label=version))
        print()
    # Read the two scorecards side by side: did v2 actually beat v1,
    # and at what cost/latency? That is the decision, made on numbers.
```

Run `compare.py`, read the two scorecards, and make the ship/no-ship call from the numbers — including latency and cost, not quality alone. That act — *deciding on evidence* — is the skill this entire series is pointing at.

### Run locally in Docker

```dockerfile
# Dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir \
    pytest sentence-transformers numpy httpx pydantic
COPY evalkit ./evalkit
COPY systems ./systems
COPY data ./data
COPY tests ./tests
COPY compare.py .
# Run the eval gate by default; non-zero exit fails CI.
CMD ["pytest", "-m", "eval", "-v", "-s"]
```

```yaml
# docker-compose.yml
services:
  eval:
    build: .
    environment:
      MODEL_API_KEY: ${MODEL_API_KEY}
      SYSTEM_VERSION: v2
    command: ["pytest", "-m", "eval", "-v", "-s"]
```

```bash
docker compose run --rm eval          # runs the gate; exit code is the CI signal
docker compose run --rm eval python compare.py   # A/B the two versions
```

As a CI step, this is just "run the container; if pytest exits non-zero, fail the pipeline" — identical in shape to how you already run unit tests in CI. Wire it into your PR checks and no change that tanks quality can merge.

### Moving to AWS

- **Evals in CI → CodeBuild** (or GitHub Actions against AWS). Same container, run on every PR; a failing gate blocks the merge. Nothing exotic — it's your existing CI muscle pointed at a quality metric instead of a compile.
- **Scorecards → S3.** Write each run's scorecard (JSON) to a bucket keyed by commit/version. Now you have a durable, queryable history of quality over time — the raw material for "did quality trend down over the last month?"
- **Dashboards later.** Those stored scorecards feed the observability dashboards in **11** and the production monitoring in **12** — offline eval history and online metrics in one view.
- Keep the eval **dataset in git** even as scorecards go to S3: the data is code, the results are artifacts.

The AWS specifics (CodeBuild buildspec, S3 layout) change — check current docs — but "container runs eval, gate blocks merge, results archived, trend watched" is the durable shape.

## How experts think / common pitfalls

- **No eval, no opinion.** The senior reflex to "I improved the prompt" is "show me the number on the eval set." Refuse to tune by feel; it's the defining habit.
- **Build the eval set before optimizing, and grow it from real failures.** Every bug becomes a permanent regression case. The set only ever gets stronger.
- **Layer cheap and expensive metrics.** Rule-based first (free, objective), similarity next, LLM-judge for the subjective — with human spot-checks keeping them honest.
- **Distrust your LLM judge until you've validated it against humans.** It's biased (length, position, sycophancy) and needs its own eval. An unvalidated judge is confident noise.
- **Beware overfitting to the eval set.** Hold out data you don't tune against; be alarmed when eval scores and user happiness diverge.
- **Cost and latency belong in the scorecard.** The highest-quality option is often not shippable. Decide on the whole vector, not one axis.
- **Reward abstention.** Include out-of-scope cases where "I don't know" is the correct answer, so you don't optimize your system into a confident liar.
- **The eval is a release gate, not a report.** If it doesn't block a bad merge, it's decoration.

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

If you can do these, you've crossed the line from "builds AI systems" to "engineers AI systems." Everything after this is production discipline layered on top of a foundation you can now *measure*.

## Going deeper

- The RAGAS framework's metric definitions (faithfulness, answer relevance, context precision/recall) for how the RAG-specific metrics are formalized.
- "Judging LLM-as-a-Judge" (Zheng et al., the MT-Bench work) for the empirical study of judge biases and pairwise vs pointwise reliability.
- Standard classification-metrics references (precision/recall/F1, confusion matrices) — the scikit-learn user guide is a solid, practical treatment (you'll use it again in 14).
- Writing on eval-set curation and regression-from-bugs practices from teams running LLMs in production — read a couple to see how the "test suite for AI" discipline plays out at scale.
- Revisit module 05 (prompts as tested artifacts) and 07 (`recall@k`) — this module is the rigorous version of the measurement instinct they introduced.

Next: [10 — Serving & inference (local)](10-serving-and-inference-local.md), where Phase 4 begins and you start running open models yourself.
