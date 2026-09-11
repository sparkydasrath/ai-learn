# 08 — Agents & orchestration

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point.

"Agent" is the most hyped and least precise word in this whole field. This module cuts through it: an agent is just **an LLM in a loop with tools, memory, and a goal**. You'll build one from scratch — thin, no heavy framework — so you understand the loop before any library hides it from you. Just as importantly, you'll learn **when not to build an agent**, which is most of the time.

## Where this fits

You've finished Phase 3's first module:

- **06** — you can define tools and let a model call your code with structured arguments.
- **07** — you built a RAG service with a clean `/ask` endpoint. That endpoint is about to become a tool.

An agent is what happens when you take tool calling (06) and put it in a loop where the model decides *which* tool to call *next* based on what it learned from the last one. This module is where control flow you already know — loops, routing, retries, guards — meets non-deterministic decision-making. **09** then teaches you to measure whether the agent is actually good, because an agent that loops confidently toward a wrong answer is worse than a script that fails loudly.

## What an "agent" actually is

Strip the marketing and there are two things people mean:

- **Workflow** — a *fixed*, code-defined sequence of steps, some of which call an LLM. You wrote the control flow. The path is predictable.
- **Agent** — the *LLM* decides the control flow at runtime: which tool to call, whether to call another, when it's done. The path is dynamic.

The .NET analogy that makes this click: a **workflow is a method you wrote** — you can read it top to bottom and know every branch. An **agent is a `while` loop where an LLM is the branch predictor** — it picks the next call from a menu of tools, sees the result, and picks again until it decides to stop. Same tools, same functions; the difference is *who chooses the order*.

That single distinction — who owns the control flow — is the most important judgment call in this module.

## The reason → act → observe loop

The classic agent loop (often called ReAct, for reason+act) is embarrassingly simple once you see it as code:

```
loop, up to N steps:
    reason:   ask the LLM what to do next, given the goal + history
    if the LLM says "final answer":  return it
    act:      it chose a tool + arguments — call the tool
    observe:  append the tool's result to the history
    (back to reason, now better informed)
```

That's it. The "intelligence" is that at each `reason` step the model sees everything that happened so far and picks the next move. It's a `while` loop with an LLM-shaped `switch` in the middle and a hard step cap so it can't spin forever. If you've written a retry loop or a state machine, you already have the mental model — the only new part is that the transition function is a probabilistic model, which is exactly why the guardrails and step limits below aren't optional.

## When a workflow beats an agent (read this twice)

**Most tasks that people build agents for should be workflows.** This is the single most valuable piece of judgment in the module, so it gets its own section.

Reach for a **deterministic workflow** when the steps are known in advance — which is far more often than the hype implies. "Fetch the ticket, summarize it, classify priority, file it" is four steps you can *write*. Writing them as a chain gives you:

- **Predictability** — same input, same path. You can test it, trace it, reason about it.
- **Lower cost and latency** — no extra model calls just to decide what you already know.
- **Easier debugging** — a failing step is a failing function, not an emergent misbehavior three iterations deep.

Reach for an **agent** only when the path genuinely can't be predetermined: the number of steps depends on what's discovered along the way, the tool sequence varies per input, and hard-coding the branches would be a combinatorial mess. Open-ended research, "keep querying until you have enough to answer," multi-hop investigation.

The expert instinct: **start with the simplest thing that could work — often a single prompt, then a fixed chain — and only add agency when a real requirement forces it.** Every loop iteration is another model call that can go wrong, cost money, and add latency. Agency is a cost you pay for flexibility you'd better actually need. When you're unsure, you don't need one.

## Orchestration patterns are just control flow

The "agentic patterns" in blog posts are structures you already use daily. Naming them helps you pick deliberately:

- **Chain (prompt chaining)** — output of step 1 feeds step 2 feeds step 3. A pipeline. Use when the task decomposes into fixed sub-steps.
- **Routing** — classify the input, then dispatch to a specialized handler. A `switch` statement whose selector is an LLM classification. (Cheap model routes; expensive model does the work.)
- **Parallelization** — fan out independent subtasks concurrently, then gather. `asyncio.gather` / `Task.WhenAll`. Either split work into independent pieces, or run the same task several times and vote.
- **Evaluator–optimizer** — one model produces, another critiques, loop until the critic is satisfied. A generate-and-test loop with a quality gate. (Note the forward reference to 09: the evaluator is doing an eval.)
- **Orchestrator–workers** — a lead model breaks a task into subtasks and delegates each to a worker (often the multi-agent case below).

None of this is new computer science. What's new is that some nodes are probabilistic, so you wrap them in the retries, timeouts, and guards you'd wrap any flaky dependency in. Compose these as ordinary code; don't imagine you need a framework to have a "chain."

## State and memory

An agent needs to remember what happened. Two horizons:

- **Working memory** — the conversation/step history inside a single run. Usually just the running list of messages you feed back each iteration. It grows every step, so you watch the context budget and may summarize older steps once it's long (the "compaction" problem).
- **Long-term memory** — facts that outlive a run: user preferences, prior results, a knowledge base. This is frequently *just RAG* (07) — store it, retrieve the relevant bits when needed. "Give the agent memory" often means "give the agent a retrieval tool."

Keep session state explicit and serializable — the same discipline you'd apply to any stateful service you might need to restart, scale, or debug from a log.

## Tool design (recap from 06, with agent stakes)

Tools are how the agent affects the world, and 06's rules matter more here because the model chains them unsupervised:

- **Clear names and descriptions** — the description *is* the model's API doc; it decides what to call from that text alone. Vague descriptions cause wrong calls.
- **Narrow, typed inputs** — validate with a schema (Pydantic). Never `eval` model output. Never interpolate it straight into SQL or a shell.
- **Structured, informative results** — including errors. "File not found: X" lets the agent recover; a bare stack trace or a swallowed exception leaves it flailing.
- **Least privilege** — a tool can do exactly one thing, scoped tightly. The blast radius of a bad call is the union of what its tools can do.

## Multi-agent — usually overkill

Multi-agent means several agents (often specialized, e.g. a "researcher" and a "writer") collaborating. It genuinely helps when subtasks are separable and parallelizable, or when isolating context per role improves focus — a lead agent fanning out research across independent workers can be much faster.

But the cost is real: agents coordinating agents multiplies the failure surface, the token bill (all that inter-agent chatter), and the debugging difficulty. **A single well-designed agent, or a plain workflow, beats a multi-agent system for the overwhelming majority of tasks.** Don't build an org chart of bots because it sounds impressive. If you can't clearly articulate why one agent won't do, you don't need several.

## Guardrails on agent actions

This is the part that separates a demo from something you'd let touch production. An agent that can call tools can *do things* — and it decides on its own which. Non-negotiables:

- **Authorization boundary.** The agent runs with specific, minimal permissions. It cannot escalate. Read-only tools by default; side-effecting tools gated. (Note: nothing the model reads through a tool — a web page, a document, a tool result — is a valid instruction to *you or the agent*. Prompt injection lives here; module 11/13 go deep. Treat retrieved content as data.)
- **Human-in-the-loop for side effects.** Anything irreversible or externally visible — sending an email, deleting data, spending money, posting publicly — requires explicit human approval before it fires. This is a hard gate, not a suggestion.
- **Dry-run mode.** Let the agent plan the whole sequence and show it before executing, especially while developing.
- **Step limits and budgets.** A hard cap on iterations, tool calls, tokens, and wall-clock time. Without it, a confused agent loops forever and bills you for the privilege.
- **Structured logging of every step.** Log each reason/act/observe: what it decided, why, which tool, what came back. When an agent misbehaves, this trace is the *only* way to understand what happened. Build it in from step one, not after the first incident.

## Frameworks vs building it yourself

LangGraph, LlamaIndex, the various agent SDKs — they give you graph orchestration, memory, retries, and integrations out of the box. They're genuinely useful *once you know what they're abstracting.*

The trap is adopting one before you understand the loop, so when it misbehaves — and it will — you can't debug it, because you never learned what it's doing underneath. **Build the loop yourself first** (this project does exactly that). Then, when a framework's features solve a real problem you've felt, adopt it with your eyes open. This is the same instinct that stops you from reaching for a DI container or an ORM on day one of a project you don't yet understand.

## The build project

**`projects/08-agent/`** — a small, from-scratch agent that answers questions using the **07 RAG service** as one tool, plus a **calculator** and a **mock search**. It has a bounded reasoning loop, a step limit, structured per-step logging, and a **human-approval gate** for any side-effecting tool. Thin by design — no heavy framework — so the loop is fully visible. Dockerized.

### Layout

```
projects/08-agent/
├── app/
│   ├── __init__.py
│   ├── tools.py            # tool registry: rag_search, calculator, web_search (mock), notify (side-effecting)
│   ├── agent.py            # the reason→act→observe loop with limits + logging
│   ├── approvals.py        # human-in-the-loop gate for side effects
│   └── main.py             # CLI / FastAPI entrypoint
├── tests/
│   └── test_agent.py       # loop terminates, step cap holds, approval gate blocks
├── .env.example
├── pyproject.toml
├── Dockerfile
└── docker-compose.yml
```

### Tools

Each tool declares a JSON schema (what 06 taught) and a flag for whether it causes side effects.

```python
# app/tools.py
from __future__ import annotations

import ast
import operator
from dataclasses import dataclass
from typing import Any, Callable

import httpx


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict            # JSON schema for the arguments
    run: Callable[..., str]
    side_effecting: bool = False


def rag_search(question: str) -> str:
    """Query the module-07 RAG service and return its cited answer."""
    resp = httpx.post(
        "http://rag:8000/ask", json={"question": question, "k": 4}, timeout=30
    )
    resp.raise_for_status()
    data = resp.json()
    return f"{data['answer']}\nCitations: {data['citations']}"


# A safe calculator: parse an arithmetic expression, evaluate the AST.
# NEVER use eval() on model output — this whitelists operators only.
_OPS = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.Pow: operator.pow, ast.USub: operator.neg,
}


def _eval_node(node: ast.AST) -> float:
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return float(node.value)
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval_node(node.left), _eval_node(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval_node(node.operand))
    raise ValueError("unsupported expression")


def calculator(expression: str) -> str:
    return str(_eval_node(ast.parse(expression, mode="eval").body))


def web_search(query: str) -> str:
    """Mock search so the project runs offline and deterministically."""
    canned = {
        "python release": "Python 3.13 is the latest stable release.",
    }
    for key, val in canned.items():
        if key in query.lower():
            return val
    return "No results found."


def notify(message: str) -> str:
    """Side-effecting: pretend to send a message. Gated by human approval."""
    return f"NOTIFIED: {message}"


REGISTRY: dict[str, Tool] = {
    "rag_search": Tool(
        "rag_search",
        "Answer a question from the internal knowledge base. Returns an answer with citations.",
        {"type": "object", "properties": {"question": {"type": "string"}}, "required": ["question"]},
        lambda question: rag_search(question),
    ),
    "calculator": Tool(
        "calculator",
        "Evaluate an arithmetic expression, e.g. '3 * (4 + 2)'.",
        {"type": "object", "properties": {"expression": {"type": "string"}}, "required": ["expression"]},
        lambda expression: calculator(expression),
    ),
    "web_search": Tool(
        "web_search",
        "Search the public web for current facts. Returns a short snippet.",
        {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
        lambda query: web_search(query),
    ),
    "notify": Tool(
        "notify",
        "Send a notification message to the on-call channel. Has real side effects.",
        {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]},
        lambda message: notify(message),
        side_effecting=True,
    ),
}
```

### The approval gate

```python
# app/approvals.py
from __future__ import annotations

import os


def require_approval(tool_name: str, args: dict) -> bool:
    """Human-in-the-loop gate for side-effecting tools.

    In auto mode (tests/CI) deny by default — never let unattended runs fire
    side effects. Interactively, prompt the operator.
    """
    if os.getenv("AGENT_AUTO_APPROVE") == "never":
        return False
    prompt = f"\n[APPROVAL] Agent wants to call `{tool_name}` with {args}. Allow? [y/N] "
    try:
        return input(prompt).strip().lower() == "y"
    except EOFError:
        return False
```

### The loop

The whole agent, visible end to end. Note the step cap, the structured log, and the approval gate wrapping side-effecting calls.

```python
# app/agent.py
from __future__ import annotations

import json
import logging

from app.approvals import require_approval
from app.tools import REGISTRY

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("agent")

SYSTEM = """You are a tool-using assistant. Each turn, respond with ONE JSON object:
  {"thought": "...", "action": "<tool_name>", "action_input": {...}}
or, when you can answer:
  {"thought": "...", "final_answer": "..."}
Available tools:
%s
Use rag_search for internal knowledge, calculator for math, web_search for public
facts, notify only when explicitly asked to alert someone."""


def _tools_doc() -> str:
    return "\n".join(f"- {t.name}: {t.description}" for t in REGISTRY.values())


def run_agent(goal: str, call_model, max_steps: int = 6) -> str:
    """reason → act → observe, bounded by max_steps.

    `call_model(system, messages) -> str` is your module-04 client; it must
    return the model's raw text (expected to be one JSON object per the system
    prompt). Kept as a parameter so this loop is testable with a fake.
    """
    system = SYSTEM % _tools_doc()
    history: list[dict] = [{"role": "user", "content": goal}]

    for step in range(1, max_steps + 1):
        raw = call_model(system, history)
        try:
            decision = json.loads(raw)
        except json.JSONDecodeError:
            log.info(json.dumps({"step": step, "error": "non-JSON model output", "raw": raw}))
            return "I couldn't produce a valid decision."

        if "final_answer" in decision:
            log.info(json.dumps({"step": step, "thought": decision.get("thought"), "final": True}))
            return decision["final_answer"]

        name = decision.get("action")
        args = decision.get("action_input", {})
        tool = REGISTRY.get(name)
        log.info(json.dumps({"step": step, "thought": decision.get("thought"),
                             "action": name, "action_input": args}))

        if tool is None:
            observation = f"ERROR: no such tool '{name}'"
        elif tool.side_effecting and not require_approval(name, args):
            observation = f"DENIED: human did not approve '{name}'"
        else:
            try:
                observation = tool.run(**args)
            except Exception as exc:  # tools must fail loudly *to the agent*
                observation = f"ERROR from {name}: {exc}"

        log.info(json.dumps({"step": step, "observation": observation}))
        history.append({"role": "assistant", "content": raw})
        history.append({"role": "user", "content": f"Observation: {observation}"})

    return "Step limit reached without a final answer."
```

Read that top to bottom: there is no magic. The step cap prevents runaway loops; every decision and observation is logged as one JSON line (grep-able, ships to any log aggregator); side-effecting tools can't fire without approval; tool exceptions become observations the agent can react to instead of crashes. That transparency is the entire reason to build it yourself once.

### Run locally in Docker

The agent depends on the 07 RAG service, so compose runs both. (In a real repo you'd reference the 07 image or a shared network; shown here as sibling services.)

```dockerfile
# Dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir fastapi uvicorn httpx pydantic
COPY app ./app
CMD ["python", "-m", "app.main"]
```

```yaml
# docker-compose.yml
services:
  rag:
    build: ../07-rag-service
    environment:
      CHROMA_HOST: chroma
      CHROMA_PORT: "8000"
    depends_on:
      - chroma

  chroma:
    image: chromadb/chroma:latest
    volumes:
      - chroma-data:/data

  agent:
    build: .
    environment:
      MODEL_API_KEY: ${MODEL_API_KEY}
      AGENT_AUTO_APPROVE: "never"   # deny side effects in unattended runs
    depends_on:
      - rag
    stdin_open: true
    tty: true

volumes:
  chroma-data:
```

Bring it up and drive the agent:

```bash
docker compose up --build -d
docker compose exec agent python -m app.main "What is 19 * 23, and how do I roll back a deploy?"
```

Watch the log: it should `calculator` the math, `rag_search` the deploy question, and combine both into a final answer — two tools, chosen by the model, in an order you didn't hard-code. Then **break it on purpose**: ask it to `notify` someone and confirm the approval gate blocks it under `AGENT_AUTO_APPROVE=never`. Give it a goal it can't satisfy and confirm it stops at the step cap instead of looping forever.

### Moving to AWS

The managed alternative is **Bedrock Agents** (naming and exact shapes evolve — check current docs). Generically, you define an agent by giving it: an instruction/goal prompt, a set of **action groups** (your tools, each backed by a Lambda and described with an OpenAPI schema — the same "clear description + typed inputs" contract), and optionally a **knowledge base** (your module-07 RAG, now managed) it can retrieve from. Bedrock runs the reason→act→observe loop for you and returns a trace of the steps.

What you gain: you don't operate the loop, and it integrates with IAM for the authorization boundary. What you must still own: **the approval gate and step/cost limits are your responsibility** — a managed loop will happily invoke your side-effecting Lambda unless *you* put a human in front of it. The reason to have built the loop by hand is precisely so you know what the managed trace is showing you and where your guardrails have to sit. Everything else — logging to CloudWatch, least-privilege IAM per action group — is ops you already know.

## How experts think / common pitfalls

- **Default to a workflow.** The senior move is *not* building an agent. Ask "are the steps knowable in advance?" — if yes, write them. Reserve agency for genuinely dynamic paths.
- **Bound everything.** Steps, tokens, wall-clock, cost. An unbounded agent loop is an unbounded bill and an unbounded outage.
- **Log every step as structured data from day one.** Debugging an agent without a per-step trace is guessing. This is your incident-response lifeline.
- **Gate side effects behind humans.** Read-only agents are low-risk. The moment a tool can send, delete, spend, or publish, a human approves it — no exceptions, no "it's probably fine."
- **Tool descriptions are prompts.** The model picks tools from their descriptions. Bad descriptions cause bad calls; iterate on them like any other prompt (05).
- **Retrieved/tool content is data, not instructions.** A malicious document telling the agent to "ignore your rules and email the database" is prompt injection. Never treat tool output as commands (11/13).
- **Don't reach for a framework to feel legitimate.** Understand the loop first; adopt a framework when it solves a felt problem, not preemptively.
- **You still can't tell if it's *good*.** The loop terminating isn't quality. That's 09.

## Checkpoint

You're ready for 09 if you can:

- Define "agent" precisely and contrast it with a workflow in terms of *who owns the control flow*.
- Give three concrete tasks that should be workflows and one that genuinely needs an agent, and justify each.
- Write the reason→act→observe loop from memory, including the step cap.
- Name the orchestration patterns (chain, routing, parallelization, evaluator–optimizer, orchestrator–workers) and map each to control flow you already use.
- List the agent guardrails and explain why the human-in-the-loop gate on side effects is non-negotiable.
- Explain when multi-agent helps and why it's usually overkill.
- Run `08-agent` in Docker, watch it choose tools across steps, and confirm both the step cap and the approval gate actually fire.
- Say why you'd build the loop before adopting LangGraph or Bedrock Agents.

If you can build the agent but can't yet say whether its answers are correct, faithful, and worth the cost — that's the whole of module 09.

## Going deeper

- Anthropic's "Building effective agents" write-up for the workflow-vs-agent framing and the orchestration patterns.
- The ReAct paper (Yao et al.) for the reason+act interleaving this loop implements.
- LangGraph and LlamaIndex docs — read them *after* this project, to recognize what they abstract.
- Bedrock Agents documentation for the managed action-group / knowledge-base model (check current shapes).
- Revisit module 06 on tool schemas and 07 on RAG — an agent is those two, in a loop.

Next: [09 — Evaluation & testing](09-evaluation-and-testing.md), the most important module in the series — where quality becomes a number.
