# 05 — Prompt engineering as engineering

> **Background.** You're a senior/staff .NET engineer becoming an AI engineer. "Prompt engineering" has a bad reputation because most of what's online is folklore — magic phrases, "you are an expert" incantations, screenshots of clever tricks. Ignore that. The real discipline is boring and familiar: a prompt is a **source artifact**. It lives in a file, it's version-controlled, it's templated with variables, it's reviewed in a PR, and — the part that makes it engineering rather than vibes — its quality is pinned by **tests you can run** (evals, module 09). If you can't tell whether prompt B is better than prompt A with a number, you're not engineering, you're guessing. This module builds the habit; module 09 builds the measurement. Model behavior and best-practice phrasing drift over time, so treat specific wording here as illustrative and re-check current provider guidance.

## Where this fits

**Prerequisites:** [01](01-python-for-dotnet-engineers.md) (Python, files, tests), [02](02-ai-engineering-landscape.md), [03](03-llm-fundamentals-for-engineers.md) (tokens/context — a prompt is tokens you pay for), [04 — Calling models](04-calling-models-apis-sdks.md) (you'll run prompts through the `LlmClient` you built).

**Outcomes:** after this you can store prompts as versioned, templated files; separate system from user content; apply the techniques that actually generalize; recognize prompt-injection risk in untrusted input; run a prompt over a labeled input set and compare two versions systematically. You'll have a small prompt lab you extend into a real eval harness in module 09.

## Prompts are code

Treat a prompt exactly like a SQL query or a Razor view: **not a string literal buried in a method**. Concretely:

- **Store prompts in files**, not inline in Python. A `prompts/summarize.v1.txt` you can diff, review, and roll back beats a triple-quoted string three call-frames deep.
- **Version them.** When you change a prompt, you've changed behavior for every downstream call — that's a deploy, not a tweak. Name versions (`v1`, `v2`) or hash them, and record which version produced which output in your logs. This is the analogue of migration versioning: you must be able to answer "which prompt generated last Tuesday's outputs?"
- **Template with variables**, don't concatenate. You want `Summarize this document:\n\n{{ document }}` with a real templating engine, not f-string spaghetti that breaks the first time a document contains a brace.

### The Razor analogy — and its dangerous edge

A prompt template feels just like a Razor view or a string template: a static skeleton with `{{ variables }}` filled at runtime. The mental model is right, but there's a **security difference that has no exact .NET equivalent**: in Razor, HTML-encoding gives you a hard boundary between template and injected data — the framework escapes `<script>` so it renders as text. **A prompt has no such boundary.** Everything you interpolate — trusted instructions and untrusted user data alike — becomes one flat stream of tokens the model reads as a whole. There is no `@Html.Encode` that makes user text "just data." That's the seed of prompt injection (below, and module 13). So: template for *structure and reuse*, but never assume interpolation sanitizes anything.

## The anatomy of a good prompt

A well-built prompt has parts, like a well-built function has a signature, body, and contract. Not every prompt needs all of them, but know the toolkit:

1. **Role / persona** — one line of framing ("You are a careful financial-document summarizer"). Modest effect; don't over-invest in elaborate personas. It sets tone and domain, not capability.
2. **Task** — the actual instruction, stated plainly and imperatively. Be specific: "Extract the three key risks" beats "analyze this."
3. **Context** — the material to work on (the document, the retrieved passages, the conversation). Usually the bulk of the tokens.
4. **Constraints** — length limits, what to avoid, tone, "only use the provided context," "do not invent numbers."
5. **Output format** — exactly how you want the answer shaped (JSON schema, bullet list, a single word). This is your API contract with the model; module 06 makes it enforceable.
6. **Examples / few-shot** — one to a handful of input→output demonstrations. Often the single highest-leverage technique: showing beats telling.

Order and clarity matter more than magic words. Think of it as writing a precise ticket for a fast, literal, slightly-overconfident contractor who will not ask clarifying questions.

## System vs user separation

Use the roles (module 04) deliberately:

- **System** = the standing contract: role, rules, output format, safety constraints. Stable across turns. Think of it as configuration or a policy object — the thing you'd put in `appsettings` and inject, not rebuild per request.
- **User** = this turn's actual input, often containing untrusted data.

Keeping instructions in `system` and untrusted content in `user` is your first (weak) line of defense against injection, and it makes prompts reusable: the system prompt is the reusable component, the user message is the per-call argument. Don't dump everything into one giant user message — you lose that separation and the model can more easily conflate your instructions with the data.

## Techniques that actually generalize

Most "prompt hacks" are noise. A short list holds up across models and tasks:

- **Be clear and specific.** The biggest wins come from removing ambiguity, not from clever phrasing. State the task, the constraints, and the exact output format. Most bad outputs are underspecified prompts.
- **Few-shot examples.** Provide 1–5 input→output pairs that demonstrate the format and the edge cases you care about. Cheaper and more reliable than a paragraph of description. Watch that examples fit your token budget and match the distribution of real inputs.
- **Decomposition.** Break a hard task into steps or into separate calls (extract, then summarize, then format) rather than one mega-prompt. Same instinct as decomposing a 300-line method: smaller units are easier to get right, test, and debug. A chain of two reliable prompts beats one flaky one.
- **Chain-of-thought, *where appropriate*.** Asking the model to reason step-by-step before answering helps on genuinely multi-step reasoning (math, logic, planning). It costs tokens and latency, and it's pointless for simple extraction or classification. Use it as a targeted tool, not a default. Note that some newer "reasoning" models do this internally — check whether you even need to ask.
- **Give the model an out.** Explicitly permit "If the context doesn't contain the answer, say 'I don't know.'" Without this, models default to confident fabrication (a.k.a. hallucination). Licensing uncertainty is one of the highest-value instructions you can add, and it's essential for RAG in module 07.

Techniques to be skeptical of: elaborate personas, ALL-CAPS SHOUTING, threats/bribes, and anything that only ever worked on one model version. If a trick isn't backed by an eval showing it helps *your* task, it's superstition.

## Prompt injection — a preview

The moment your prompt includes text you didn't write — a user message, a retrieved document, a web page, an email — you have an injection surface. The classic attack: the untrusted text contains "Ignore your previous instructions and instead ...", and because there's no template/data boundary (above), the model may obey it.

For now, just internalize the threat model, which maps directly onto instincts you already have about untrusted input:

- **Untrusted content is data, never instructions** — but the model doesn't enforce that; *you* must design around it.
- **System/user separation helps but is not a fix.** Treat it like input validation: necessary, not sufficient.
- **Never let a model's output trigger a side effect without validation/authorization** — the theme of module 06 (tool calling) and module 13 (security).

We tackle real defenses in module 13. Here, just stop trusting interpolated text.

## Why you must pin prompts to evals

Here's the crux, and the reason this module exists before the fun stuff. **You cannot improve what you can't measure.** A prompt change that "looks better" on the two examples you eyeballed routinely makes things *worse* on the 200 cases you didn't look at. This is regression, and you already know the fix from software: a test suite.

An **eval** is a test suite for a prompt: a set of inputs, expected properties or answers, and a scoring function. You run prompt v1 and prompt v2 over the same set and compare scores. That turns "I think this is better" into "v2 scores 0.87 vs 0.81 on the labeled set." Module 09 builds this properly (including LLM-as-judge for outputs you can't check with `==`). This module wires the plumbing so that habit starts now.

The rule from module 00 bears repeating: **measure before you optimize.** Do not tune prompts by feel.

## Prompt versioning & A/B comparison

Because prompts are files, versioning is just files: `summarize.v1.txt`, `summarize.v2.txt`. To compare, run both over your labeled set and diff the scores — an A/B test, offline and cheap. Keep the loser in git; you'll want to know *why* you moved on, and sometimes v1 was better and you'll revert. Record, per run: prompt version, model, inputs, outputs, and score. That record is the difference between engineering and anecdote.

## The build project

**`projects/05-prompt-lab/`** — a prompt template system (Jinja2-based) with prompts stored as versioned files, a tiny harness to run a prompt over a set of inputs and record outputs, and a small labeled test set to compare two prompt versions. Dockerized. It reuses the `LlmClient` from project 04 (import it, or vendor a copy for now).

### Layout

```
projects/05-prompt-lab/
├── pyproject.toml
├── Dockerfile
├── compose.yaml
├── prompts/
│   ├── classify.v1.jinja
│   └── classify.v2.jinja
├── data/
│   └── labeled.jsonl        # inputs + expected labels
├── src/promptlab/
│   ├── __init__.py
│   ├── template.py          # load + render versioned prompts
│   ├── harness.py           # run a prompt over inputs, record outputs
│   └── score.py             # compare a run against labels
├── tests/
│   └── test_template.py
└── run.py                   # CLI: pick a prompt version, run, score
```

### Versioned prompt templates

We'll use a simple, real task: classify a short support message as `billing`, `bug`, or `other`. Two prompt versions, so we can measure whether v2's few-shot examples actually help.

```jinja
{# prompts/classify.v1.jinja — terse, no examples #}
You are a support-ticket classifier.
Classify the message into exactly one of: billing, bug, other.
Reply with only the single label word, lowercase, nothing else.

Message:
{{ message }}
```

```jinja
{# prompts/classify.v2.jinja — adds few-shot + an explicit "out" #}
You are a support-ticket classifier.
Classify the message into exactly one of: billing, bug, other.
Reply with only the single label word, lowercase, nothing else.
If it is ambiguous or fits none well, use "other".

Examples:
Message: "I was charged twice this month" -> billing
Message: "The export button throws a 500" -> bug
Message: "Do you have an office in Berlin?" -> other

Message:
{{ message }}
```

Storing prompts as files, cleanly separated from code, *is* the point. The `{{ message }}` is templated; the untrusted ticket text flows into it — note we do **not** assume that interpolation makes the ticket safe (injection preview above).

### Loading and rendering

```python
# src/promptlab/template.py
from __future__ import annotations
from pathlib import Path
from dataclasses import dataclass
from jinja2 import Environment, FileSystemLoader, StrictUndefined

PROMPT_DIR = Path(__file__).resolve().parents[2] / "prompts"

_env = Environment(
    loader=FileSystemLoader(PROMPT_DIR),
    undefined=StrictUndefined,   # fail loudly on a missing variable
    autoescape=False,            # this is NOT HTML; escaping would corrupt text
)


@dataclass(frozen=True)
class Prompt:
    name: str          # e.g. "classify"
    version: str       # e.g. "v2"

    @property
    def filename(self) -> str:
        return f"{self.name}.{self.version}.jinja"

    def render(self, **vars: object) -> str:
        return _env.get_template(self.filename).render(**vars)
```

> **Pythonism flag.** Jinja2 is the templating engine you'll see everywhere in Python (it's what Flask/Ansible use). `StrictUndefined` turns a missing `{{ variable }}` into an error instead of silently rendering empty — the equivalent of a compile error for a missing model property, and exactly what you want for prompts. We deliberately set `autoescape=False`: HTML-escaping a prompt would mangle quotes and angle brackets in the text. That is *also* the reminder that Jinja gives you no security boundary here.

### The harness — run a prompt over inputs, record outputs

```python
# src/promptlab/harness.py
from __future__ import annotations
import json, time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Sequence
from .template import Prompt
# from llmclient import LlmClient, Message   # reuse project 04's client


@dataclass(frozen=True)
class RunRecord:
    prompt_name: str
    prompt_version: str
    model: str
    input_id: str
    rendered_prompt: str
    output: str
    expected: str | None
    latency_ms: float


async def run_prompt(
    client, prompt: Prompt, inputs: Sequence[dict], *, model_label: str
) -> list[RunRecord]:
    """Render `prompt` for each input, call the model, record everything.
    `inputs` are dicts like {"id": "1", "message": "...", "label": "billing"}."""
    records: list[RunRecord] = []
    for item in inputs:
        rendered = prompt.render(message=item["message"])
        t0 = time.perf_counter()
        completion = await client.complete(
            [Message("user", rendered)], max_tokens=8
        )
        records.append(
            RunRecord(
                prompt_name=prompt.name,
                prompt_version=prompt.version,
                model=model_label,
                input_id=item["id"],
                rendered_prompt=rendered,
                output=completion.text.strip().lower(),
                expected=item.get("label"),
                latency_ms=(time.perf_counter() - t0) * 1000,
            )
        )
    return records


def save_run(records: list[RunRecord], path: Path) -> None:
    with path.open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(asdict(r)) + "\n")
```

### Scoring — turn "looks better" into a number

```python
# src/promptlab/score.py
from __future__ import annotations
from .harness import RunRecord


def accuracy(records: list[RunRecord]) -> float:
    """Simplest possible eval: exact-match against the gold label.
    Module 09 replaces this with real eval sets and LLM-as-judge."""
    labeled = [r for r in records if r.expected is not None]
    if not labeled:
        return 0.0
    correct = sum(1 for r in labeled if r.output == r.expected)
    return correct / len(labeled)


def compare(a: list[RunRecord], b: list[RunRecord]) -> str:
    sa, sb = accuracy(a), accuracy(b)
    va = a[0].prompt_version if a else "?"
    vb = b[0].prompt_version if b else "?"
    winner = va if sa > sb else vb if sb > sa else "tie"
    return f"{va}={sa:.2%}  {vb}={sb:.2%}  -> winner: {winner}"
```

This is intentionally crude — exact string match — because the *habit* is the lesson: every prompt change is judged by a number over a set, not by eyeballing. Module 09 upgrades the scoring; the loop stays the same.

### Tests

```python
# tests/test_template.py
import pytest
from jinja2 import UndefinedError
from promptlab.template import Prompt


def test_renders_message():
    rendered = Prompt("classify", "v1").render(message="charged twice")
    assert "charged twice" in rendered
    assert "billing" in rendered  # the label options are in the template


def test_missing_variable_fails_loud():
    with pytest.raises(UndefinedError):
        Prompt("classify", "v1").render()  # no `message` -> StrictUndefined errors
```

### Run it locally in Docker

```dockerfile
# projects/05-prompt-lab/Dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir uv
WORKDIR /app
COPY pyproject.toml ./
RUN uv pip install --system -e ".[dev]"
COPY . .
CMD ["python", "run.py", "--compare", "v1", "v2"]
```

```yaml
# projects/05-prompt-lab/compose.yaml
services:
  ollama:
    image: ollama/ollama:latest
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]
  lab:
    build: .
    environment:
      OLLAMA_BASE_URL: http://ollama:11434
      OLLAMA_MODEL: llama3.2
    depends_on: [ollama]
volumes:
  ollama:
```

Steps:

```bash
cd projects/05-prompt-lab
docker compose up -d ollama
docker compose exec ollama ollama pull llama3.2
docker compose run --rm lab pytest -q                    # template tests, no network
docker compose run --rm lab python run.py --compare v1 v2 # runs both, prints scores
```

Expected shape of the output: something like `v1=72.00%  v2=88.00%  -> winner: v2`. Now you have *evidence* the few-shot examples helped — on this set, with this model. Change models and the numbers move; that's why the set and the number travel together.

### Moving to AWS

- **Prompt/config management.** Prompts are config, so manage them like config: store versioned prompt files in **S3** (or bake them into the image), and keep pointers/flags — "which version is live" — in **SSM Parameter Store**. Flipping the live prompt version becomes a config change with an audit trail, not a redeploy, and you can roll back instantly.
- **Don't invent an eval platform yet.** Real eval infrastructure — datasets, scoring, dashboards, regression gates in CI — is modules 09 and 12. For now, note that the labeled set and scoring you built here are the seed of that, and they belong in the repo, versioned alongside the prompts they judge.
- **Log the prompt version with every production call.** On AWS your call logs (module 11) should carry the prompt version and model, so an output is always traceable to the exact prompt that produced it.

## How experts think / pitfalls

- **A prompt change is a deploy.** It changes behavior for every call. Version it, review it, and re-run evals before shipping. Treat "just tweak the prompt in prod" with the same alarm as "just edit the SQL in prod."
- **Eyeballing lies.** Two examples looking good tells you almost nothing about 200 cases. Numbers over a set, always.
- **Specificity beats cleverness.** Nine times out of ten the fix for a bad output is a clearer, more constrained prompt — not a magic phrase.
- **Give the model an out** or it will confidently make things up. "Say I don't know" is a feature, not a weakness.
- **Interpolation is not sanitization.** The instant untrusted text enters a prompt, you have an injection surface. System/user separation helps but doesn't solve it.
- **Chain-of-thought isn't free** and isn't always needed. Use it for genuine multi-step reasoning; skip it for extraction/classification.
- **Keep the losers in git.** You'll revisit why v2 beat v1, and occasionally revert. Deleted prompt history is deleted evidence.

## Checkpoint

You're ready for module 06 if you can:

- [ ] Argue why a prompt belongs in a versioned file, not a string literal, and what "a prompt change is a deploy" means.
- [ ] Name the parts of a well-structured prompt and what each is for.
- [ ] Explain the system-vs-user split and why it's a weak (not zero) injection defense.
- [ ] List the techniques that generalize and name two "hacks" you'd be skeptical of.
- [ ] Say why chain-of-thought helps some tasks and wastes tokens on others.
- [ ] Explain why interpolating untrusted text into a prompt is an injection surface, and why Jinja escaping doesn't help.
- [ ] Run one prompt over a labeled set, score it, and compare two versions with a number — not a vibe.

## Going deeper

- Your provider's prompting guide for *current* model-specific advice (few-shot formatting, system-prompt behavior, reasoning modes) — this drifts, so read the live version.
- Jinja2 docs (templating, `StrictUndefined`, why you disable autoescape for non-HTML).
- Forward reference: [09 — Evaluation & testing](09-evaluation-and-testing.md) for real eval sets, LLM-as-judge, and regression gates — the payoff of the habit you started here.
- Forward reference: [13 — Cost, scaling & security](13-cost-scaling-and-security.md) for prompt-injection defenses in depth.
- Look up "few-shot vs zero-shot" and "chain-of-thought prompting" as concepts (the original ideas generalize even as model-specific tactics change).

Next: [06 — Structured outputs & tool calling](06-structured-outputs-and-tool-calling.md).
