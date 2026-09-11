# 02 — The AI engineering landscape

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. You already know how to design, build, test, and ship systems, so this doc doesn't re-teach that. It teaches the AI-specific layer: where *you* sit among the roles, the shape of a real GenAI system, and the one mental model that makes all of it tractable — that an AI system is mostly normal software with a probabilistic component bolted in at one spot. Math stays out of this module. The payoff is a durable map you'll hang the rest of the curriculum on.

The fastest way to feel lost in AI is to treat it as a new discipline you have to learn from scratch. You don't. Ninety percent of a production AI system is software you already know how to build — services, queues, databases, retries, deploys, dashboards. What's new is a single component that behaves *probabilistically* instead of deterministically, and the practices that spring up around containing that. This module draws the map so you can place any new tool, paper, or framework onto it in minutes.

## Where this fits

**Prerequisites:** module 01 (you can run the Python toolchain and Docker).

**After this module you can:**

- Say precisely what an AI engineer owns versus an ML engineer, ML researcher, data scientist, and data engineer — and stop applying for the wrong jobs or scoping the wrong work.
- Name the layers of a modern GenAI application stack and what each is for.
- Make a first-pass build-vs-buy and hosted-vs-open call for a feature.
- Explain where determinism breaks in an AI system and why that changes how you test.
- Read the rest of this curriculum as a connected whole, not a list of topics.

## The roles, disambiguated

These titles are used loosely in the wild, but the *ownership boundaries* are real. Mapping them to a shape you know: think of a data platform team, a backend team, and a research group.

| Role | Owns | .NET/SWE analogy | Primary tools |
|---|---|---|---|
| **Data engineer** | Pipelines, warehouses, data quality, getting bytes from A to B reliably. | The platform/infra team that owns the message bus and the data lake. | Spark, dbt, Airflow, SQL, cloud storage. |
| **Data scientist** | Answering questions with data; experiments, statistics, dashboards, sometimes a model. | The analyst-leaning engineer who turns data into decisions. | Notebooks, pandas, SQL, viz, stats. |
| **ML researcher** | Inventing new model architectures and training methods; publishing. | The people who write the compiler, not the app. | PyTorch/JAX, papers, GPUs, math. |
| **ML engineer (MLE)** | *Training and serving* models at scale; the ML lifecycle, MLOps. | SRE-meets-backend for models — owns the training pipeline and the inference service. | PyTorch, feature stores, Kubernetes, MLOps. |
| **AI engineer** | *Building products on top of existing (usually pre-trained) models* — prompting, retrieval, agents, evals, serving, observability. | **You.** A backend/full-stack engineer whose "library" happens to be a probabilistic model. | LLM APIs, vector DBs, orchestration, eval frameworks. |

The key distinction for your career: **an ML engineer trains and serves models; an AI engineer builds systems that call models.** You are not going to be deriving loss functions or babysitting a 3-week training run (not until the optional Phase 5, and even then only to *understand* it). You *are* going to be deciding whether a feature needs RAG or an agent, wiring the model into a real service, and — the differentiator — proving with evals that it actually works. Most "AI engineer" jobs in industry are this. The math-heavy research path is a different career; this curriculum deliberately isn't it.

Where the lines blur: at a small company you may wear the data-engineer and MLE hats too. That's fine — just know which hat is on, because the practices differ (a data pipeline wants correctness and idempotency; a model call wants eval coverage and cost control).

## The modern GenAI application stack

Here's the shape of a real system. Read it top to bottom as a request's journey, or think of it as the layers you'll build across modules 04–13.

```
                 ┌─────────────────────────────────────────┐
   user / API →  │  Application (your normal service code)   │  ← module 01, everywhere
                 ├─────────────────────────────────────────┤
                 │  Orchestration / prompt layer             │  ← 05, 06, 08
                 │  (build the prompt, route, call tools)    │
                 ├──────────────────┬──────────────────────┤
                 │  Retrieval        │  Tools / agents       │  ← 07 (RAG), 08 (agents)
                 │  (vector store,   │  (function calling,   │
                 │   search, RAG)    │   multi-step plans)   │
                 ├──────────────────┴──────────────────────┤
                 │  Model layer  (the probabilistic part)    │  ← 03, 04, 10
                 │  hosted API  OR  self-served open model   │
                 ├─────────────────────────────────────────┤
                 │  Eval / observability / guardrails        │  ← 09, 11
                 │  (is it good? is it safe? what happened?) │
                 └─────────────────────────────────────────┘
                 running on: Docker → AWS (Bedrock, ECS/Lambda)  ← 12, 13
```

Layer by layer:

- **Application** — ordinary code: HTTP handlers, auth, validation, persistence. You already own this. The AI is a *dependency* it calls, like a payment gateway.
- **Orchestration / prompt** — assembles the prompt, chooses a model, decides whether to retrieve or call a tool, parses the response. This is where "prompt engineering as engineering" (module 05) and structured outputs (06) live. Think of it as the mapping/coordination layer between your domain and the model.
- **Retrieval (RAG)** — fetches relevant context (from a vector store or search index) and stuffs it into the prompt so the model answers from *your* data, not just its training. Module 07. Mentally: a read-through cache/lookup that grounds the model.
- **Tools / agents** — lets the model call your functions (query a DB, hit an API) and, for agents, loop over multiple steps toward a goal. Modules 06 and 08. This is the model reaching back into deterministic code.
- **Model layer** — the one probabilistic component. Either a **hosted API** (someone else runs the GPUs; you send tokens, get tokens) or a **self-served open model** (you run it, module 10). Everything above is deterministic software orchestrating this one non-deterministic call.
- **Eval / observability / guardrails** — the practices that make the probabilistic part shippable: measuring quality with eval sets (09), tracing and monitoring in production (11), and blocking bad inputs/outputs. This layer is the biggest thing that separates an AI engineer from someone who wired up a demo.

The whole thing runs in Docker locally and on AWS as pretend prod — the same deployment story you already know.

## The one mental model: mostly normal software, one probabilistic component

Internalize this and everything else falls into place:

> An AI system is a normal software system with exactly one component that returns *a plausible answer* instead of *the correct answer*, and you engineer around that.

Consequences of that single fact — each becomes a later module:

- **You can't assert equality on the output.** The same input can produce different output (see sampling in module 03). So testing shifts from `Assert.Equal(expected, actual)` to *evaluation*: scoring outputs against criteria, over a set, as a distribution. This is module 09 and it's the core skill.
- **You can't fully trust the output's shape.** A model asked for JSON may return prose, or malformed JSON. So you validate at the boundary (pydantic, module 06) exactly like you would an untrusted API payload — because that's what it is.
- **Failures are silent and plausible.** Deterministic code fails loudly (exceptions, 500s). A model fails by confidently saying something wrong — a *hallucination* (module 03). Your guardrails and evals are the thing that catches this, since a stack trace won't.
- **Cost and latency scale with input size.** Every token in and out costs money and time (module 03, 13). This has no real analog in the CRUD world, where a bigger request is usually still cheap. Context becomes a budget you manage.
- **The dependency is nondeterministic *and* externally versioned.** The hosted model can change under you when the provider updates it. So you pin versions where you can, and your eval set is your regression suite against silent drift.

Notice what *doesn't* change: your architecture instincts, your testing discipline (redirected, not discarded), your CI, your observability, your security posture. You're not throwing out software engineering. You're adding a probabilistic dependency and the containment around it.

## Build vs buy, hosted vs open

Two decisions you'll make on nearly every feature. First-pass heuristics (all specifics — prices, model names — age fast; the *reasoning* doesn't):

**Build vs buy the capability:**

- **Don't build AI at all** if a deterministic solution works. A regex, a lookup table, or a SQL query beats an LLM on cost, latency, and reliability every time it's applicable. The senior move is often *not* using a model. (This curriculum's whole point is judgment, and this is the first exercise of it.)
- **Buy / use a framework** for undifferentiated plumbing (a vector DB, an eval harness, an orchestration library) unless you have a specific reason to control it. You wouldn't hand-roll an ORM for a CRUD app; same instinct.
- **Build** the thin layer that encodes *your* domain, data, and evals. That's the differentiated part and nobody sells it.

**Hosted vs open (self-served) model:**

| | Hosted API (e.g. Bedrock, provider APIs) | Open model, self-served (module 10) |
|---|---|---|
| Time to first call | Minutes | Days |
| Ops burden | None (someone else's GPUs) | Yours (GPUs, scaling, uptime) |
| Cost model | Per-token, scales with usage | Fixed infra, cheaper at high volume |
| Data control / privacy | Data leaves your boundary (check terms/region) | Stays in your infra |
| Quality ceiling | Usually the strongest models | Strong and closing, but you pick/tune |
| Right when… | Starting out, bursty traffic, want best quality fast | High steady volume, strict data rules, need customization |

Default early: **hosted.** You'll start on a hosted model (via AWS Bedrock, below) so you can focus on building systems, and revisit self-serving in module 10 once you understand what you're trading.

## The build project

**`projects/02-landscape-map/`** — this module is lighter on code and heavier on judgment, by design. Two deliverables:

1. **An ADR** (architecture decision record) for a hypothetical feature — the artifact a staff engineer produces to force and document a decision. You already write these; here you write one *for an AI feature*, which surfaces exactly the new axes (build-vs-buy, hosted-vs-open, how you'll evaluate it).
2. **A tiny "hello model" script** that hits a hosted model and prints the response — just enough to prove your API key/credentials work end to end. Real API depth is deferred to module 04; this is a smoke test.

### Layout

```
projects/02-landscape-map/
├── pyproject.toml
├── Dockerfile
├── .env.example
├── docs/
│   └── adr-0001-support-summarizer.md
└── src/
    └── hello_model/
        ├── __init__.py
        └── main.py
```

### The ADR (`docs/adr-0001-support-summarizer.md`)

Write this yourself — it's the real exercise. Use your normal ADR template, but make sure it answers the AI-specific questions. A skeleton:

```markdown
# ADR 0001 — Summarize support tickets with an LLM

## Status
Proposed

## Context
Support agents spend ~2 min/ticket writing a summary for handoff.
~4,000 tickets/week. We want auto-generated draft summaries.

## Decision
Use a hosted LLM (via AWS Bedrock) behind our existing ticket service.
Prompt-only to start (no fine-tuning, no RAG) — a summary needs only the
ticket text already in the request.

## Options considered
1. Deterministic extractive summary (first + last sentence). Cheap, no model.
   Rejected: quality too low for handoff.
2. Hosted LLM, prompt-only. Chosen: fast to ship, quality high, low volume.
3. Self-hosted open model. Rejected for now: 4k/week doesn't justify GPU ops.
4. Fine-tuned model. Rejected: no evidence prompting is insufficient yet.

## How we'll know it's good  (the AI-specific section)
- Eval set: 50 tickets with human-written reference summaries.
- Metric: LLM-as-judge for faithfulness + a length check. Target ≥ 90%
  "faithful" with no hallucinated facts. (Module 09 builds this for real.)
- Guardrail: never emit PII not present in the source ticket.

## Consequences
- New probabilistic dependency; outputs vary run to run — test by eval, not equality.
- Per-token cost ≈ tracked per ticket; alarm if weekly spend exceeds $X.
- Provider can update the model; the eval set is our regression suite.
```

The section that wouldn't appear in a normal ADR is **"How we'll know it's good."** That's the tell that you're now thinking like an AI engineer: quality is a measured number with a target, not a vibe.

### The "hello model" script (`src/hello_model/main.py`)

This calls a hosted model on **AWS Bedrock** (introduced below) using the AWS SDK. API surfaces change — treat this as *the pattern*, and check current Bedrock docs for exact model IDs and the request/response shape before relying on it:

```python
"""Smoke test: prove our credentials can reach a hosted model.

Real model-calling patterns (streaming, retries, cost accounting) are module 04.
This just confirms the pipe is connected.
"""
from __future__ import annotations

import json
import os

import boto3   # the AWS SDK for Python


def main() -> int:
    # Model IDs change; read the current Bedrock model catalog. This is an example.
    model_id = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20240620-v1:0")
    region = os.environ.get("AWS_REGION", "us-east-1")

    client = boto3.client("bedrock-runtime", region_name=region)

    # Bedrock's "Converse" API gives one consistent shape across model families.
    response = client.converse(
        modelId=model_id,
        messages=[
            {"role": "user", "content": [{"text": "Say hello in one short sentence."}]}
        ],
        inferenceConfig={"maxTokens": 64, "temperature": 0.0},
    )

    text = response["output"]["message"]["content"][0]["text"]
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Add `boto3` as a dependency (`uv add boto3`). `.env.example` documents what credentials are needed (never commit the real `.env`):

```dotenv
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-5-sonnet-20240620-v1:0
# AWS credentials come from your environment / AWS CLI config / IAM role,
# not from this file. Run `aws configure` or use an SSO/role locally.
```

### Running locally in Docker

```dockerfile
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project
COPY src/ ./src/
RUN uv sync --frozen
ENTRYPOINT ["uv", "run", "python", "-m", "hello_model.main"]
```

```bash
docker build -t hello-model projects/02-landscape-map

# Pass AWS credentials in from your host environment; never bake them into the image.
docker run --rm \
  -e AWS_REGION \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e BEDROCK_MODEL_ID \
  hello-model
```

Passing secrets as `-e` env vars (referencing your host's already-set values) rather than `COPY`-ing an `.env` into the image is the habit to build now: **credentials never live in the image layers.** If it prints a sentence, your pipe to a hosted model works and you're ready for module 04.

### Moving to AWS

You just used the AWS component you'll lean on for the rest of the series: **Amazon Bedrock**, AWS's managed, multi-provider hosted-model service. The mental model:

- Bedrock is a single API in front of *many* model families (Anthropic, Meta Llama, Amazon's own, and others). You pick a `modelId`; AWS runs the GPUs. It's the "hosted API" box from the stack diagram, delivered as an AWS service.
- Its **Converse API** normalizes the request/response shape across those families, so switching models is mostly a config change — useful when you're comparing models on cost/quality later.
- Auth is standard **IAM**, not a bespoke API key: your service assumes a role with permission to invoke a model. This is the same auth story as any other AWS call you've made, which is exactly why AWS is our pretend-prod target — the surrounding machinery is stuff you already know.
- Billing is per-token, visible in Cost Explorer. Set a budget alarm early (module 13); it's easy to leave a loop running.

You don't deploy anything to AWS in this module — the script runs locally against Bedrock. But you've now placed the model layer of the stack onto a concrete AWS service, and every later module builds on that.

## How experts think / pitfalls

- **"Do we need AI here at all?" is the first question, every time.** Reaching for an LLM when a query or a rule would do is the most common junior mistake. The strongest AI engineers remove models as often as they add them.
- **Don't confuse a demo with a system.** A prompt that works in a notebook once is a demo. A system has evals, error handling, cost controls, and observability around the same call. The gap between the two is most of the job — and most of this curriculum.
- **Respect the trust boundary.** The model's output is untrusted input to the rest of your system. Validate it, constrain it, and never let it drive a side effect (delete a record, send an email, spend money) without a guardrail. Prompt injection (module 13) makes this a security concern, not just a correctness one.
- **Frameworks are conveniences, not the skill.** LangChain, LlamaIndex, and friends can accelerate you, but they hide the mechanics you need to understand to debug. Build the first version of each thing (a retrieval loop, an agent loop) *by hand* — then adopt a framework knowing what it does for you.
- **Pin what you can; expect drift anyway.** Hosted models can change behavior under a stable-looking name. Your eval set is your defense: it turns "the model got worse" from a support ticket into a failing test.
- **Match the role to the work.** If a task is really "train and serve a model at scale," that's ML-engineering work with different practices. Knowing you've wandered off the AI-engineer map saves you from applying the wrong playbook.

## Checkpoint

You're ready for module 03 when you can:

- Explain the difference between an AI engineer and an ML engineer in one sentence, and say which this curriculum trains you for.
- Draw the GenAI stack from memory and say what each layer is for and which module covers it.
- State the "mostly normal software, one probabilistic component" model and list three concrete consequences it has for how you build and test.
- Give a first-pass build-vs-buy and hosted-vs-open recommendation for a described feature, with reasons.
- Write an ADR for an AI feature that includes a "how we'll know it's good" section.
- Run the hello-model script in Docker against Bedrock and explain why credentials are passed as env vars, not baked into the image.
- Say in one sentence what AWS Bedrock is and how its auth differs from a raw API key.

## Going deeper

Topics and search terms (verify current details against provider docs — this layer moves fast):

- "AWS Bedrock Converse API" and "Bedrock supported models" — the current model catalog and request shape.
- "emerging architectures for LLM applications" / "LLM app stack" — several good industry write-ups map this territory; read a couple and note where they agree.
- "MLOps vs LLMOps" — how the ops discipline differs when the model is pre-trained and called, not trained by you.
- "architecture decision records" (Michael Nygard's original template) — if ADRs are new to you, though as a staff engineer they likely aren't.
- "when not to use an LLM" — worth actively seeking the skeptical take to calibrate your build-vs-buy instinct.

Next: [03 — LLM fundamentals for engineers](03-llm-fundamentals-for-engineers.md).
