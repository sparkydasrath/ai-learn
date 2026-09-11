# 17 — Capstone & portfolio

> **Background.** You're a senior/staff-level .NET engineer who set out to become an AI engineer, without a deep math background — and you're at the end of the path. This module has almost no new concepts. Its job is to make you *prove* what you can do by shipping **one substantial, evaluated, deployed system** that exercises the whole stack: a real problem, built with prompting/RAG/agents where each fits, measured with a real scorecard, deployed to AWS, observable, cost-controlled, and documented well enough that a stranger — or a hiring panel — can understand it. That artifact, not a certificate, is what makes you credible. The math you skipped along the way stays skipped; the judgment you built is what you're demonstrating here.

Everything before this was practice with a safety net. The capstone removes the net: you pick the problem, make the architecture calls, decide what "good" means, and defend the result with numbers. This is also where you set up the habits that keep you an expert as the field moves — because the half-life of specific tools is short and the half-life of good judgment is long.

## Where this fits

**Prerequisites:** all of 01–16. The capstone *assembles* them. If a module's project is shaky, that's the weak link to shore up first — the capstone will expose it.

**After this module you have:**

- One deployed, evaluated system you can demo and talk through end to end.
- A portfolio-quality repo: README, architecture doc, ADRs, an eval scorecard, cost notes.
- A reflection mapping the system back to every module — proof to yourself the stack is coherent in your head.
- A concrete routine for staying current without drowning in hype.

## Pick a real problem

The capstone must be a *real* problem you (or someone) would actually use — real problems force the trade-offs that toy demos let you dodge. It should combine **RAG + an agent/tool use + evaluation + deployment**; most good candidates do naturally. Four concrete ideas, each of which stretches the whole stack:

1. **Documentation assistant over your own docs.** RAG (07) over a real doc set — this curriculum, a product's docs, an OSS project's wiki. Answers cite sources; an agent (08) can follow links or call a search tool; evals (09) score answer correctness and citation accuracy. The most approachable capstone and a genuinely useful tool.
2. **"Ask my codebase" tool.** RAG over a repository (code + comments + commit messages), with an agent that can run read-only tools (grep, read a file, list a directory) to answer "where is X handled?" or "what calls this?". Evals check it points to the right files. Plays directly to your engineering background.
3. **Support-ticket triage + draft system.** A **classical classifier (14)** routes/prioritizes incoming tickets, RAG pulls relevant KB articles and past resolutions, and the LLM drafts a reply a human approves. Evals measure routing accuracy *and* draft quality (LLM-as-judge). Shows you know when *not* to use an LLM — the routing is classical ML, the drafting is generative.
4. **Research assistant.** An agent (08) that plans a small research task, calls search/fetch tools, synthesizes with citations, and produces a structured brief (structured outputs, 06). Evals check factual grounding and format compliance. The most agent-heavy option — pick it if orchestration is the skill you want to showcase.

Pick the one you'd actually *use*, at a scope you can *finish and deploy*. A finished, deployed, evaluated small system beats an ambitious half-built one every time — a lesson you already know from shipping software. Scope down until "done and deployed" is reachable in your available time, then build that.

## The definition of done for an expert-level project

This is the bar. "It works in a demo" is *not* done. An expert-level capstone is:

- **It works** — handles the real inputs, including the ugly ones (empty, huge, adversarial, off-topic). You broke things on purpose in earlier modules; do it here too.
- **It's evaluated with a real scorecard.** A held-out eval set, the module-09 harness, a number for quality (and one for cost and latency). "94% answer-correctness on 60 held-out questions, p95 latency 2.1s, $0.004/query" — not "it seems good." This is the single line that separates you from a vibe coder.
- **It's deployed to AWS.** Real deployment (module 12): IaC, a reachable endpoint, secrets handled properly. Running on your laptop is not deployed.
- **It has observability (11).** Traces/logs of what the model saw and did, so you can debug a bad answer after the fact. If you can't explain *why* it gave a specific answer three days ago, you're not done.
- **It has cost controls (13).** A budget alarm, token/caching awareness, and you know your cost per request. An AI system without a cost story is a liability.
- **It has guardrails (11).** Input/output checks appropriate to the use — injection defense, PII handling, refusal behavior for out-of-scope asks.
- **It's documented:** a **README** (what/why/how to run), an **architecture doc** (the diagram + the flow), and **ADRs** (the decisions and *why* — why RAG not fine-tuning, why this model, why this vector store). ADRs are the artifact that most signals senior judgment; you already write them for .NET systems — do it here.

## How to present it

The build is half the value; being able to *show* it is the other half. A great capstone that no one can understand doesn't move your career. Assemble:

- **A portfolio README** — problem, approach, architecture diagram, how to run, and *the eval numbers up top*. Lead with the scorecard; it's your credibility.
- **An architecture diagram** — the boxes and arrows: ingestion → retrieval → model → guardrails → serving, with where AWS pieces sit. One clear diagram beats paragraphs.
- **A short writeup of the evals** — what "good" means for this system, how you measured it, what the numbers are, and *what you learned* (including what didn't work — that reads as senior, not weak).
- **A demo** — a short recorded walkthrough or a live endpoint. Show it answering well, and show it handling a hard/adversarial input gracefully. The second one impresses more.

## The reflection checklist — map it back to every module

Walk your capstone against the whole curriculum. If a box is empty, you either made a deliberate choice (fine — note it in an ADR) or you have a gap to close:

- **01 Python** — typed, linted, tested, `uv`-managed? CI green?
- **02 Landscape** — can you say where each component sits and why?
- **03 LLM fundamentals** — token/context/cost budget understood and respected?
- **04 Calling models** — retries, timeouts, streaming, cost/latency accounting?
- **05 Prompt engineering** — prompts versioned and eval-driven, not vibes?
- **06 Structured outputs / tools** — reliable JSON / safe tool calls where needed?
- **07 RAG** — chunking, embeddings, vector store, retrieval you measured?
- **08 Agents** — multi-step/tool use where it *earns its place* (and not where it doesn't)?
- **09 Evaluation** — the scorecard exists and gates changes?
- **10 Serving** — local Docker path works; you understand the serving choice?
- **11 Observability & guardrails** — traces + input/output safety?
- **12 AWS deploy** — IaC, reachable, secrets handled?
- **13 Cost/scaling/security** — budget alarm, caching, injection defense?
- **14 Classical ML** — used where it beats an LLM (routing/triage), or consciously not needed?
- **15 DL intuition** — you can explain what any model in the system is doing?
- **16 Fine-tuning** — used only if RAG/prompting couldn't do it, and proven with evals — or consciously skipped?

A capstone that can honestly check most of these is the portfolio piece. The gaps you find are your personal syllabus for the next month.

## The build project

**`projects/17-capstone/`** — not a prescribed app but a **scaffold, checklist, and rubric** to assemble your earlier projects into one deployed, evaluated system. The point is that you drive it; this gives you the skeleton and the bar.

### Suggested repo structure

```
projects/17-capstone/
├── README.md                 # problem, architecture diagram, HOW TO RUN, eval numbers up top
├── ARCHITECTURE.md           # the flow, the components, where AWS pieces sit
├── docs/
│   └── adr/
│       ├── 0001-use-rag-not-finetuning.md
│       ├── 0002-model-and-provider-choice.md
│       └── 0003-vector-store-choice.md
├── src/
│   └── app/                  # the system: ingestion, retrieval, agent, serving
├── eval/
│   ├── dataset.jsonl         # held-out eval set — the heart of "done"
│   ├── run_evals.py          # the module-09 harness producing the scorecard
│   └── scorecard.md          # latest results: quality, cost, latency
├── infra/                    # IaC (module 12): the AWS deployment
├── tests/
├── Dockerfile
├── NOTES.md                  # your lab notebook (per module 00)
└── .env.example
```

### `eval/run_evals.py` (the scorecard is the deliverable)

```python
"""Produce the capstone scorecard: quality, cost, latency on a held-out set.

This is the module-09 harness pointed at your deployed system. The numbers it
prints are what make the capstone 'done'. Wire `answer` to your real app.
"""
from __future__ import annotations

import json
import time
from collections.abc import Callable
from pathlib import Path

# answer(question) -> (text, usd_cost). Point this at YOUR system.
AnswerFn = Callable[[str], tuple[str, float]]


def run(answer: AnswerFn, dataset: str = "eval/dataset.jsonl") -> dict[str, float]:
    rows = [json.loads(line) for line in Path(dataset).read_text("utf-8").splitlines()]
    n = len(rows)
    correct = 0
    total_cost = 0.0
    latencies: list[float] = []

    for row in rows:
        start = time.perf_counter()
        text, cost = answer(row["question"])
        latencies.append(time.perf_counter() - start)
        total_cost += cost
        # Replace with your real judge (exact-match, rubric, or LLM-as-judge from 09).
        if _judge(text, row["expected"]):
            correct += 1

    latencies.sort()
    return {
        "quality": correct / n,
        "avg_cost_usd": total_cost / n,
        "p95_latency_s": latencies[min(int(0.95 * n), n - 1)],
        "n": float(n),
    }


def _judge(answer_text: str, expected: str) -> bool:
    # Placeholder. Use your module-09 judge here.
    return expected.lower() in answer_text.lower()


if __name__ == "__main__":
    def _stub(_q: str) -> tuple[str, float]:
        return ("wire me to the real app", 0.0)

    print(json.dumps(run(_stub), indent=2))
```

### The "done" checklist

Copy this into your capstone README and don't call it done until every line is checked or consciously waived in an ADR:

```
[ ] Handles real inputs, including empty / huge / adversarial / off-topic
[ ] Held-out eval set exists and is version-controlled
[ ] Scorecard: quality number + cost/request + p95 latency, in the README
[ ] Evals gate changes (a regression fails the run)
[ ] Deployed to AWS via IaC; endpoint reachable; secrets in a real secret store
[ ] Observability: traces/logs of model inputs/outputs, queryable after the fact
[ ] Cost control: budget alarm set; caching where it helps; cost/request known
[ ] Guardrails: input/output checks; injection defense; graceful out-of-scope refusal
[ ] README (run instructions) + ARCHITECTURE.md (diagram) + >=2 ADRs
[ ] NOTES.md lab notebook of what you tried and what the evals said
[ ] A demo (recording or live endpoint), including a hard-input example
```

### The rubric (grade yourself honestly)

| Dimension | Not yet | Solid | Expert |
|---|---|---|---|
| Problem fit | toy demo | real but narrow | real, useful, right-sized |
| Evaluation | "seems good" | quality number on held-out set | quality + cost + latency, gates changes |
| Architecture | one script | sensible components | components justified in ADRs |
| Deployment | laptop only | manually deployed | IaC, reproducible, secrets handled |
| Observability | none | logs | traces you can debug a past answer with |
| Cost | unknown | measured | measured + controlled (alarm, caching) |
| Guardrails | none | basic input checks | input+output, injection-aware |
| Docs | sparse README | README + diagram | README + architecture + ADRs |

Aim for "Solid" across the board before "Expert" in any one column. Breadth of done-ness reads as more senior than one gold-plated dimension next to empty ones.

### Run it locally, then in Docker

Your capstone follows the same pattern as every project in this series: it runs locally in Docker first (compose up its dependencies — vector store, the app, any local model from module 10), you run the eval harness against it and read the scorecard, and only then do you deploy. There's no new mechanics here — you've done all of it. The Dockerfile and compose file are assembled from your module 07/08/10/12 projects.

### Moving to AWS

For the capstone, **this is not a "someday" section — deploying to AWS *is* the culmination.** Everything you practiced in module 12 (IaC, Bedrock or a served model, ECS/Lambda, secrets) and module 13 (budget alarm, caching, injection defense) is applied for real here. The definition of done above requires it. When the endpoint is live, the scorecard is green, the budget alarm is armed, and the traces are flowing, the capstone is complete — and so is the deployment story the whole series was building toward.

## How experts think / pitfalls

- **Scope down until "done and deployed" is reachable.** The commonest capstone failure is over-ambition — a sprawling system that's 70% built and never deployed. A small system that clears the whole checklist is worth far more.
- **Build the eval set first.** Before writing much app code, write 30–60 held-out examples with expected answers. It defines "done," catches regressions from day one, and stops you tuning by feel.
- **Lead with numbers, everywhere.** In the README, the demo, the interview. "Here's the scorecard" is the most senior sentence you can say about an AI system.
- **Show a failure gracefully handled.** Anyone can demo the happy path. Showing your system decline an out-of-scope question, or handle an injection attempt, demonstrates the judgment that got you here.
- **Write the ADRs while deciding, not after.** "Why RAG not fine-tuning here" captured in the moment is honest and valuable; reconstructed later it's fiction.
- **Don't gold-plate one dimension.** A dazzling agent with no evals and no deployment is a worse portfolio piece than a plain RAG app that's measured, deployed, observable, and documented.

## Staying expert — habits, not headlines

The field moves fast, and that's exactly why *judgment* — not memorized API shapes — is what you built here. To keep it sharp:

- **Read model cards and system cards, not hype threads.** When a model ships, read the card: what it's good at, its limits, its evals. That's signal; a viral demo is noise.
- **Follow evals, not vibes.** Trust independent benchmarks and — better — *your own* eval set run against the new thing. "Is it better *for my task*?" is the only question that matters, and you have the harness to answer it. Re-run your capstone's scorecard against each new model; that habit alone keeps you current and honest.
- **Re-run your own benchmarks.** Your eval sets are a durable asset. New model, new library, new prompt — run it through your scorecard before believing anyone's claims, including your own.
- **Build small things often.** A weekend project on each genuinely new capability beats reading about ten. The reps are what kept .NET sharp; same here.
- **Keep the lab notebook habit.** A running `NOTES.md` of what you tried and what the evals said compounds into real expertise over months.
- **Go one level deeper on demand, not preemptively.** When a problem forces you to understand attention or a loss function, learn it then. You don't need to front-load the math you deliberately skipped — pull it in when a real problem asks for it.

### Avoiding skill decay

- **Ship, don't just read.** Reading keeps you conversant; building keeps you good. The ratio should favor building.
- **Rotate the stack.** Periodically rebuild something with a different model/provider/tool so you're not fluent in exactly one vendor's shapes — the mental models transfer; the APIs are disposable.
- **Teach it.** Explaining RAG or evals to a colleague exposes every soft spot in your understanding faster than anything else.
- **Keep one real system live.** Maintaining something deployed — watching its costs, its traces, its eval drift — teaches you things no tutorial can.

## Checkpoint

You've truly finished when you can:

- Point to one deployed, evaluated AI system and demo it, happy path and hard input.
- State its scorecard from memory: quality, cost per request, p95 latency, on a held-out set.
- Walk someone through its architecture diagram and justify each major decision (with the ADRs to back you).
- Map the system to every module and name any conscious gaps.
- Explain your routine for evaluating a new model or technique against *your* work.
- Say, honestly, "I can take a vague product ask, decide whether it needs AI at all and what kind, build it, measure whether it's good, deploy it, and debug it when it's wrong, slow, or expensive." That was the whole goal.

## Going deeper

- "How to write an ADR" (Michael Nygard's ADR format) — the template; you likely already use it for .NET.
- "arch diagram as code" (Mermaid, `diagrams` Python library) — keep the architecture diagram in the repo, versioned with the code.
- Model and system cards from the major providers — make reading these a standing habit; they're the highest signal-per-minute in the field.
- "LLM eval frameworks" — survey the current landscape and see how your hand-rolled module-09 harness maps onto them; the concepts transfer, the tools change.
- Independent evaluation efforts and leaderboards — useful as a starting signal, never as a substitute for your own eval set.

## You made it

That's the whole path — from "senior .NET engineer" to "AI engineer with a deployed, evaluated system to prove it." You did it the way you learned everything else that stuck: by building real things, measuring them, and shipping them, not by accumulating reading. The math you deliberately kept minimal never blocked you, because the job was always judgment and engineering, and you already had those.

Go back to [the curriculum index](README.md) whenever you want to shore up a module or lift a pattern into a new project. But the real continuing education isn't re-reading these docs — it's the habits from the section above: read the cards, trust the evals, re-run your own benchmarks, build small things often, and keep one real system alive. The tools will keep changing. The way you reason about them — the thing you actually built here — won't. Now go ship something.
