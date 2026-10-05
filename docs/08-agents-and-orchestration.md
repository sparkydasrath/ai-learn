# 08 — Agents & orchestration

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point. From module 03 on, every project is built twice: Python first (the spec), then rebuilt in idiomatic C# with the same behavior.

"Agent" is the most hyped and least precise word in this whole field. This module cuts through it: an agent is just **an LLM in a loop with tools, memory, and a goal**. You'll build one from scratch — thin, no heavy framework — so you understand the loop before any library hides it from you. Just as importantly, you'll learn **when not to build an agent**, which is most of the time.

## Where this fits

You've finished Phase 2 and the first module of Phase 3:

- **06** — you can define tools and let a model call your code with structured arguments, through a validated JSON protocol.
- **07** — you built a RAG service with a clean `/ask` endpoint. That endpoint is about to become a tool.

An agent is what happens when you take tool calling (06) and put it in a loop where the model decides *which* tool to call *next* based on what it learned from the last one. This module is where control flow you already know — loops, routing, retries, guards — meets non-deterministic decision-making. **09** then teaches you to measure whether the agent is actually good, because an agent that loops confidently toward a wrong answer is worse than a script that fails loudly.

You build the agent twice, as in every module since 03: Python first, then C# on `Microsoft.Extensions.AI`'s `IChatClient`, both on module 04's client. Writing the loop by hand in .NET shows you exactly what `UseFunctionInvocation()` and Microsoft Agent Framework would otherwise do for you, so you can judge when to let them.

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

**`projects/08-agent/`** — a small, from-scratch agent, built in Python and then in C#, that answers questions using the **07 RAG service** as one tool, plus a **calculator**, a **mock web search**, and a side-effecting **notify**. Both versions have:

1. A bounded reason → act → observe loop with a step cap and a wall-clock budget.
2. Structured per-step logging, one JSON object per event, on stderr.
3. A **human-approval gate** in front of the side-effecting tool.
4. The same four tools, the same decision protocol, and the same CLI: pass a goal, get a transcript and an answer on stdout.

Thin by design — no framework — so the loop is fully visible. Three decisions carry over from earlier modules:

- **The model comes from project 04.** A uv path dependency in Python, a `ProjectReference` in C#, so `LLM_BACKEND` picks the model (and fails loudly on an unknown value), and every call gets 04's cost logging. No model adapter of its own.
- **The protocol is module 06's.** The system prompt lists each tool with its argument schema, and the model replies `{"tool": ..., "arguments": {...}}` or `{"answer": ...}`, plus an optional `"thought"` that the log records as the reason step. Replies are validated like any untrusted input, and tool results go back as a `user` message. It runs on every backend, the stub included, which is what makes the cross-check exact.
- **07 is a service, reached through `RAG_URL`.** Either 07 implementation works, since they share one `/ask` contract. Nothing here imports 07's code. The tests fake the HTTP call (`httpx.MockTransport` in Python, a stub `HttpMessageHandler` in C#), so they never need 07 running.

On a bare `LLM_BACKEND=stub`, both programs play a scripted model from `fixtures/stub_replies.jsonl`, one reply per call: a calculator call, a `rag_search`, a `notify` for the gate to rule on, and a final answer. That's the whole loop with no model: deterministic, and offline apart from the 07 service that `rag_search` calls (which the tests fake too).

### Layout

```
projects/08-agent/
├── fixtures/
│   └── stub_replies.jsonl       # the scripted "model" for LLM_BACKEND=stub, one reply per line
├── python/
│   ├── pyproject.toml           # from the scaffold + uv add: path dependency on 04
│   ├── uv.lock                  # committed: pins exact dependency versions
│   ├── Dockerfile               # build context is projects/, to reach project 04
│   ├── Dockerfile.dockerignore  # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example             # committed; copy to .env (git-ignored)
│   ├── app/
│   │   ├── __init__.py
│   │   ├── tools.py             # the four tools, their argument models, the registry
│   │   ├── approvals.py         # the human-in-the-loop gate, picked by AGENT_AUTO_APPROVE
│   │   ├── agent.py             # the reason→act→observe loop: protocol, choke point, step cap, log
│   │   └── main.py              # CLI: pass a goal, get a transcript
│   └── tests/
│       ├── conftest.py          # every test runs unattended
│       ├── fakes.py             # project 04's stub plus a call record; a fake 07
│       ├── test_tools.py
│       ├── test_approvals.py
│       ├── test_agent.py        # terminates, step cap, deny, unknown tool, non-JSON, ...
│       └── test_main.py         # the CLI end to end on the stub
└── csharp/
    ├── Agent.slnx
    ├── Directory.Build.props            # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                       # build context is projects/, to reach project 04
    ├── Dockerfile.dockerignore          # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json            # from the bootstrap script
    ├── README.md                        # from the bootstrap script
    ├── src/
    │   └── Agent/
    │       ├── Agent.csproj             # ProjectReference to project 04's LlmClient library
    │       ├── Tools.cs                 # argument records, AgentTool, the registry, the mock search
    │       ├── Calculator.cs            # safe arithmetic parser (no eval)
    │       ├── RagClient.cs             # typed HttpClient for the 07 /ask endpoint
    │       ├── Approvals.cs             # IApprovalGate + the console implementation
    │       ├── AgentLoop.cs             # the reason→act→observe loop on IChatClient
    │       └── Program.cs               # host, DI, logging, budget, CLI
    └── tests/
        └── Agent.Tests/
            ├── Agent.Tests.csproj       # NUnit
            ├── Fakes.cs                 # RecordingChatClient, Fake07, FixedGate, TestPaths
            ├── AgentLoopTests.cs
            ├── CalculatorTests.cs
            └── ToolTests.cs
```

### The fixture

`fixtures/stub_replies.jsonl`, what the stub "model" says, in order:

```jsonl
{"thought": "Multiply first.", "tool": "calculator", "arguments": {"expression": "19 * 23"}}
{"thought": "Rollbacks are in the runbook.", "tool": "rag_search", "arguments": {"question": "How do I roll back a deploy?"}}
{"thought": "The goal asks me to alert on-call.", "tool": "notify", "arguments": {"message": "Deploy failed; rolling back."}}
{"thought": "I have what I need.", "answer": "19 * 23 = 437. To roll back, run deploy --revert <sha> with the last good SHA. On-call was not notified: the operator denied it."}
```

The stub doesn't read the goal or the tool results. It only replays the script, so the run exercises the loop and the tools, not judgment. Judgment is what a real model adds, and what module 09 measures.

## Python implementation

Work in `projects/08-agent/python/`. It's a [Service-shaped](conventions.md#python-project-shapes) project: code in `app/` at the `python/` root, never installed, and pytest finds it through `pythonpath = ["."]`, which the script writes. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 08-agent -Mode app
cd projects/08-agent/python
uv add httpx pydantic
uv add --editable ../../04-llm-client/python
uv add --dev pytest-asyncio
Remove-Item tests/test_smoke.py
```

The script names the distribution `agent`. This doc was built against httpx 0.28 and pydantic 2.13.

```toml
# projects/08-agent/python/pyproject.toml
[project]
name = "agent"
version = "0.1.0"
description = "A from-scratch agent: reason, act, observe, with a step cap and an approval gate"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.28.1",
    "llm-client",
    "pydantic>=2.13.5",
]

[tool.pytest.ini_options]
pythonpath = ["."]

[tool.uv.sources]
llm-client = { path = "../../04-llm-client/python", editable = true }

[dependency-groups]
dev = [
    "pytest>=9.1.1",
    "pytest-asyncio>=1.4.0",
]
```

### Tools

Each tool has a pydantic model for its arguments. The schema goes into the prompt, so the model sees the argument names, and the same model validates whatever the model sends back. `rag_search` is bound to an `httpx.AsyncClient` whose `base_url` is the 07 service, so a test can hand it a client with a fake transport instead.

```python
# app/tools.py
from __future__ import annotations

import ast
import math
import operator
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import httpx
from pydantic import BaseModel, Field


# Each tool's arguments are a pydantic model: the schema goes into the prompt, and the
# model's arguments are validated against it before anything runs (module 06).
class RagArgs(BaseModel):
    question: str = Field(description="A self-contained question for the knowledge base.")


class CalcArgs(BaseModel):
    expression: str = Field(description="Arithmetic only: numbers, + - * / ** and parentheses.")


class SearchArgs(BaseModel):
    query: str


class NotifyArgs(BaseModel):
    message: str


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    args_model: type[BaseModel]
    run: Callable[[Any], Awaitable[str]]   # takes an instance of args_model, returns the observation
    side_effecting: bool = False


# --- rag_search: the module-07 service, over HTTP --------------------------------------

class Citation(BaseModel):
    tag: str
    source: str


class AskResponse(BaseModel):
    """The part of 07's /ask contract this tool reads. chunk_id and any new fields are ignored."""
    answer: str
    citations: list[Citation]


def rag_search(http: httpx.AsyncClient) -> Callable[[RagArgs], Awaitable[str]]:
    """Bind the tool to an HTTP client whose base_url is the 07 service (RAG_URL)."""

    async def run(args: RagArgs) -> str:
        resp = await http.post("/ask", json={"question": args.question, "k": 4})
        resp.raise_for_status()   # a 4xx/5xx becomes an exception, and the loop turns it into an observation
        data = AskResponse.model_validate_json(resp.content)
        cites = ", ".join(f"{c.tag} ({c.source})" for c in data.citations)
        return f"{data.answer}\nCitations: {cites}"   # text for the model, never a Python repr

    return run


# --- calculator: a safe arithmetic evaluator --------------------------------------------
# Parse the expression and evaluate the AST, whitelisting operators.
# NEVER use eval() on model output.
_OPS: dict[type[ast.AST], Callable[..., Any]] = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.Pow: operator.pow, ast.USub: operator.neg,
}


def _eval(node: ast.AST) -> float:
    value = node.value if isinstance(node, ast.Constant) else None
    if isinstance(value, (int, float)) and not isinstance(value, bool):   # True is an int, but not arithmetic
        return float(value)
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.operand))
    raise ValueError("unsupported expression")


def calculate(expression: str) -> str:
    try:
        value = _eval(ast.parse(expression, mode="eval").body)
    except SyntaxError:
        raise ValueError("unsupported expression") from None
    except OverflowError:
        raise OverflowError("result out of range") from None
    # (-8) ** 0.5 is a complex number in Python, and float overflow can give inf: refuse both.
    if not isinstance(value, float) or not math.isfinite(value):
        raise OverflowError("result out of range")
    return str(value)   # 437.0, 0.25: the C# side formats to match


async def calculator(args: CalcArgs) -> str:
    return calculate(args.expression)


# --- web_search: a mock, so the project runs offline and deterministically -------------

_CANNED = {"python release": "Python 3.14 was released in October 2025."}


async def web_search(args: SearchArgs) -> str:
    for key, snippet in _CANNED.items():
        if key in args.query.lower():
            return snippet
    return "No results found."


# --- notify: the side-effecting tool -----------------------------------------------------

async def notify(args: NotifyArgs) -> str:
    """Pretend to page someone. The loop only gets here past the approval gate."""
    return f"NOTIFIED: {args.message}"


def build_registry(http: httpx.AsyncClient) -> dict[str, Tool]:
    tools = [
        Tool("rag_search",
             "Answer a question from the internal knowledge base (runbooks, billing policy). "
             "Returns an answer with citations.",
             RagArgs, rag_search(http)),
        Tool("calculator", "Evaluate an arithmetic expression, e.g. '3 * (4 + 2)'.", CalcArgs, calculator),
        Tool("web_search", "Search the public web for current facts. Returns a short snippet.",
             SearchArgs, web_search),
        Tool("notify", "Send a message to the on-call channel. Has real side effects.",
             NotifyArgs, notify, side_effecting=True),
    ]
    return {t.name: t for t in tools}
```

`rag_search` turns 07's JSON into plain text for the model: the answer, then `Citations: S1 (oncall.md), ...`. Formatting it yourself matters. Interpolating the parsed list straight into an f-string would show the model Python's `repr` of a list of dicts, which C# can't reproduce and no model needs.

### The approval gate

```python
# app/approvals.py
from __future__ import annotations

import json
import os
import sys
from typing import Any, Protocol


class Approver(Protocol):
    def __call__(self, tool: str, args: dict[str, Any]) -> bool: ...


def ask_operator(tool: str, args: dict[str, Any]) -> bool:
    """Ask on the terminal. Only "y" approves; end of input or no usable stdin denies."""
    # The prompt goes to stderr, so stdout stays the agent's transcript.
    print(f"[APPROVAL] Agent wants to call {tool} with {json.dumps(args, separators=(',', ':'))}. Allow? [y/N] ",
          end="", file=sys.stderr, flush=True)
    try:
        answer = sys.stdin.readline()   # "" at end of input
    except OSError:                     # e.g. pytest's captured stdin: deny, never crash
        return False
    return answer.strip().lower() == "y"


def deny_all(tool: str, args: dict[str, Any]) -> bool:
    return False


def approver_from_env() -> Approver:
    """The human-in-the-loop gate for side-effecting tools, picked by AGENT_AUTO_APPROVE.

    never  -> deny without asking. Set it for every unattended run: tests, CI, containers.
    unset  -> ask the operator on the terminal.
    There is deliberately no "always": nothing approves side effects on its own.
    """
    mode = os.environ.get("AGENT_AUTO_APPROVE", "")
    if mode == "never":
        return deny_all
    if mode:
        raise ValueError(f"unknown AGENT_AUTO_APPROVE {mode!r} (expected: never, or unset to ask)")
    return ask_operator
```

The gate is picked once, when the run starts, so a typo like `AGENT_AUTO_APPROVE=nevr` fails before the first model call instead of quietly prompting. The prompt reads `sys.stdin` directly rather than calling `input()`: `input()` writes its prompt to stdout, which is the transcript. It also catches `OSError`, which is what pytest's captured stdin raises (not `EOFError`). The tests never get that far anyway, because they run with `AGENT_AUTO_APPROVE=never`.

### The loop

The whole agent, visible end to end. Note the step cap, the one choke point that every tool call goes through, and the log line per step.

```python
# app/agent.py
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any

from llm_client.types import LlmClient, Message
from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from app.approvals import Approver, approver_from_env
from app.tools import Tool

log = logging.getLogger("agent")

# Module 06's protocol, plus an optional "thought": the reason step, logged with each action.
REPLY_FORMAT = (
    'Reply with ONE JSON object and nothing else: {"thought": "<why>", "tool": "<name>", "arguments": {...}} '
    'to call a tool, or {"thought": "<why>", "answer": "<text>"} when you can answer.'
)
STEP_LIMIT = "Step limit reached without a final answer."


def system_prompt(tools: dict[str, Tool]) -> str:
    """Names, descriptions and argument schemas: the model can't call what it can't see."""
    listed = "\n".join(
        f"- {t.name}: {t.description} Arguments (JSON Schema): {json.dumps(t.args_model.model_json_schema())}"
        for t in tools.values()
    )
    return (
        "You are a tool-using assistant. Work towards the user's goal one step at a time.\n"
        f"Tools:\n{listed}\n"
        "Use rag_search for internal knowledge, calculator for arithmetic, web_search for public facts, "
        "and notify only when the user explicitly asks you to alert someone.\n"
        f"{REPLY_FORMAT}"
    )


class Decision(BaseModel):
    """One model turn: call a tool, or answer. Untrusted input, validated like any other."""
    model_config = ConfigDict(extra="forbid")

    thought: str | None = None
    tool: str | None = None
    arguments: dict[str, Any] = {}
    answer: str | None = None

    @model_validator(mode="after")
    def _exactly_one(self) -> Decision:
        if (self.tool is None) == (self.answer is None):
            raise ValueError("set exactly one of 'tool' or 'answer'")
        return self


@dataclass(frozen=True)
class Step:
    number: int
    tool: str
    arguments: dict[str, Any]
    observation: str


@dataclass
class AgentRun:
    answer: str
    steps: list[Step] = field(default_factory=list)

    def transcript(self) -> str:
        """What the CLI prints: every action, what came back, then the answer."""
        lines: list[str] = []
        for s in self.steps:
            lines += [f"step {s.number}: {s.tool} {_compact(s.arguments)}", f"  -> {s.observation}"]
        lines.append(f"answer: {self.answer}")
        return "\n".join(lines)


def _compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _trace(**event: Any) -> None:
    log.info(_compact(event))   # one JSON object per line: grep-able, and any log pipeline can parse it


def describe(e: ValidationError) -> str:
    """One line per problem, e.g. "expression: Field required" (module 06)."""
    return "\n".join(
        f"{'.'.join(map(str, err['loc'])) or '(root)'}: {err['msg']}" for err in e.errors(include_url=False)
    )


def strip_fences(text: str) -> str:
    """Tolerate ```json ... ``` wrapping, which models add even when told not to."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("```")[1].removeprefix("json").strip()
    return t


async def observe(tools: dict[str, Tool], name: str, raw_args: dict[str, Any], approve: Approver) -> str:
    """The choke point: known tool, valid arguments, approval, and only then run it."""
    tool = tools.get(name)
    if tool is None:
        return f"ERROR: unknown tool '{name}'"
    try:
        args = tool.args_model.model_validate(raw_args)
    except ValidationError as e:
        return f"ERROR: invalid arguments for {name}: {describe(e)}"
    # The human approves the validated arguments, not whatever the model sent.
    if tool.side_effecting and not approve(name, args.model_dump()):
        return f"DENIED: the operator did not approve '{name}'"
    try:
        return await tool.run(args)
    except Exception as exc:   # a failing tool is information for the agent, not a crash
        return f"ERROR from {name}: {exc}"


async def run_agent(
    client: LlmClient,
    goal: str,
    tools: dict[str, Tool],
    *,
    approve: Approver | None = None,
    max_steps: int = 6,
) -> AgentRun:
    """reason -> act -> observe, bounded by max_steps.

    `client` is module 04's LlmClient, so LLM_BACKEND picks the model and tests pass a
    scripted stub. `approve` is the human gate: AGENT_AUTO_APPROVE's choice unless a test passes one.
    """
    approve = approve or approver_from_env()   # an unknown AGENT_AUTO_APPROVE fails here, before any call
    messages = [Message("system", system_prompt(tools)), Message("user", goal)]
    steps: list[Step] = []

    for number in range(1, max_steps + 1):
        completion = await client.complete(messages, max_tokens=512)    # reason
        messages.append(Message("assistant", completion.text))
        try:
            decision = Decision.model_validate_json(strip_fences(completion.text))
        except ValidationError as e:
            # A malformed turn costs a step, and the model is told exactly what was wrong.
            _trace(step=number, event="invalid_reply", error=describe(e))
            messages.append(Message("user", f"That was not a valid reply: {describe(e)}\n{REPLY_FORMAT}"))
            continue

        if decision.answer is not None:
            _trace(step=number, event="answer", thought=decision.thought)
            return AgentRun(decision.answer, steps)

        assert decision.tool is not None                                  # the validator guarantees it
        observation = await observe(tools, decision.tool, decision.arguments, approve)   # act
        _trace(step=number, event="act", thought=decision.thought, tool=decision.tool,
               arguments=decision.arguments, observation=observation)
        steps.append(Step(number, decision.tool, decision.arguments, observation))
        # observe: a "user" message, not "tool". OpenAI-style APIs only accept a tool role
        # in answer to a native tool call, and this protocol doesn't make one (module 06).
        messages.append(Message("user", f"Result of {decision.tool}: {observation}"))

    _trace(event="step_limit", max_steps=max_steps)
    return AgentRun(STEP_LIMIT, steps)
```

Read it top to bottom: there's no magic. The step cap prevents runaway loops. Every decision is logged as one JSON line (grep-able, and any log pipeline can parse it). A bad reply costs a step and comes back to the model with the reason, as in 06. `observe` checks the tool exists, validates its arguments, asks the gate if it has side effects, and only then runs it. Tool exceptions become observations the agent can react to instead of crashes. That transparency is the reason to build it yourself once.

### The CLI

`main.py` builds the model client, the tools and the gate, runs the loop under a wall-clock budget, and prints the transcript.

```python
# app/main.py
"""Usage: python -m app.main "<goal>"
The transcript and answer go to stdout; the JSON step log goes to stderr."""
from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path

import httpx
from llm_client.factory import client_from_env
from llm_client.stub import StubClient
from llm_client.types import LlmClient

from app.agent import run_agent
from app.approvals import approver_from_env
from app.tools import build_registry

# Relative to python/, where you run from; the Dockerfile sets it.
FIXTURES_DIR = Path(os.environ.get("FIXTURES_DIR", "../fixtures"))
BUDGET_SECONDS = 120   # wall-clock cap for the whole run, on top of the step cap


def make_client() -> LlmClient:
    """Project 04 picks the backend, and fails loudly on an unknown one. On a bare stub,
    play the scripted model in fixtures/stub_replies.jsonl, so the whole run works offline."""
    if os.environ.get("LLM_BACKEND") == "stub" and not os.environ.get("LLM_STUB_REPLY"):
        lines = (FIXTURES_DIR / "stub_replies.jsonl").read_text(encoding="utf-8").splitlines()
        return StubClient([line for line in lines if line.strip()])
    return client_from_env()


async def run(goal: str, transport: httpx.AsyncBaseTransport | None = None) -> int:
    """`transport` lets a test stand in for the 07 service; normally it's the network."""
    client, approve = make_client(), approver_from_env()   # a bad LLM_BACKEND or AGENT_AUTO_APPROVE fails now
    rag_url = os.environ.get("RAG_URL", "http://localhost:8000")   # Python 07; C# 07 is on 8001
    async with httpx.AsyncClient(base_url=rag_url, timeout=30, transport=transport) as http:
        try:
            async with asyncio.timeout(BUDGET_SECONDS):
                result = await run_agent(client, goal, build_registry(http), approve=approve)
        except TimeoutError:
            print(f"Stopped: the {BUDGET_SECONDS}-second budget ran out.", file=sys.stderr)
            return 1
    print(result.transcript())
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    logging.basicConfig(level=logging.INFO, format="%(message)s")   # stderr
    logging.getLogger("httpx").setLevel(logging.WARNING)            # no line per HTTP request
    return asyncio.run(run(sys.argv[1]))


if __name__ == "__main__":
    raise SystemExit(main())
```

`asyncio.timeout` is the budget. It cancels the run at the next `await`, and `main` turns that into a one-line message and exit code 1 instead of a traceback. The `transport` parameter is there for the end-to-end test: it's how a test stands in for the 07 service without a server.

### Configuration

```bash
# projects/08-agent/python/.env.example
# Copy to .env (git-ignored). compose reads it; a bare `uv run` doesn't, so set variables in your shell there.
# The model variables are project 04's: docs/conventions.md#environment-variables
# The C# stack reads the same names: copy it to csharp/.env too.

# stub | ollama | hosted. A bare stub plays fixtures/stub_replies.jsonl.
LLM_BACKEND=ollama
OLLAMA_MODEL=llama3.2
# hosted: LLM_BASE_URL (with /v1), LLM_API_KEY, LLM_MODEL and the Rates__* pair, as in module 04

# URLs: leave these commented. compose also reads .env to fill the ${...} in compose.yaml,
# and a localhost URL there would point the container at itself. The defaults are right locally.
# OLLAMA_BASE_URL=http://localhost:11434
# RAG_URL=http://localhost:8000          # Python 07; C# 07 is on 8001

# never: deny side effects without asking (CI, containers). Leave it unset to be asked.
AGENT_AUTO_APPROVE=never

# Optional. The default works from python/ and csharp/; the Dockerfiles set it.
# FIXTURES_DIR=../fixtures
```

### Tests

The loop's guarantees are deterministic once the model is scripted, so they're ordinary unit tests: no network, no model, no 07. `conftest.py` makes every test unattended, so the gate never reads stdin.

```python
# tests/conftest.py
import pytest


@pytest.fixture(autouse=True)
def unattended(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every test runs unattended: the approval gate denies without reading stdin.
    (pytest's captured stdin raises OSError on read; the gate must never get there.)"""
    monkeypatch.setenv("AGENT_AUTO_APPROVE", "never")
```

```python
# tests/fakes.py
from collections.abc import AsyncIterator, Sequence

import httpx
from llm_client.stub import StubClient
from llm_client.types import Completion, Message


class RecordingClient:
    """Project 04's StubClient replaying `replies` in order (cycling), plus a record of what
    each call was sent. Only the model is fake: the loop under test is the real code."""

    def __init__(self, *replies: str):
        self._stub = StubClient(replies)
        self.calls: list[list[Message]] = []

    async def complete(self, messages: Sequence[Message], *, max_tokens: int = 512) -> Completion:
        self.calls.append(list(messages))   # a snapshot: the loop keeps appending to its list
        return await self._stub.complete(messages, max_tokens=max_tokens)

    def stream(self, messages: Sequence[Message], *, max_tokens: int = 512) -> AsyncIterator[str]:
        return self._stub.stream(messages, max_tokens=max_tokens)


# A canned module-07 /ask response, in the contract's exact shape.
ASK_RESPONSE = {
    "answer": "Run `deploy --revert <sha>` with the last good SHA [S1].",
    "citations": [{"tag": "S1", "source": "oncall.md", "chunk_id": "oncall.md#0"}],
}


def fake_rag(status: int = 200, requests: list[httpx.Request] | None = None) -> httpx.AsyncClient:
    """An HTTP client whose 'network' is a function: no 07 service needed."""

    def handle(request: httpx.Request) -> httpx.Response:
        if requests is not None:
            requests.append(request)
        return httpx.Response(status, json=ASK_RESPONSE if status == 200 else {"detail": "boom"})

    return httpx.AsyncClient(base_url="http://rag.test", transport=httpx.MockTransport(handle))
```

```python
# tests/test_tools.py
import json

import httpx
import pytest
from fakes import fake_rag

from app.tools import CalcArgs, RagArgs, SearchArgs, calculate, rag_search, web_search


# The same expressions are pinned in the C# CalculatorTests: both must print these exact strings.
@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("19 * 23", "437.0"),
        ("3 * (4 + 2)", "18.0"),
        ("1 / 4", "0.25"),
        ("-2 ** 2", "-4.0"),       # unary minus binds looser than **
        ("2 ** 3 ** 2", "512.0"),  # ** is right-associative
        ("2 ** -1", "0.5"),
        ("1 / 100000", "1e-05"),
        ("10 ** 15", "1000000000000000.0"),
        ("10 ** 17", "1e+17"),
    ],
)
def test_calculator_evaluates(expression: str, expected: str) -> None:
    assert calculate(expression) == expected


@pytest.mark.parametrize(
    "expression", ["__import__('os').system('ls')", "2 % 3", "1 +", "True + 1", "x * 2"]
)
def test_calculator_rejects_anything_else(expression: str) -> None:
    with pytest.raises(ValueError, match="unsupported expression"):
        calculate(expression)


def test_division_by_zero_is_an_error_not_infinity() -> None:
    with pytest.raises(ZeroDivisionError, match="float division by zero"):
        calculate("1 / 0")


@pytest.mark.parametrize("expression", ["10 ** 400", "(-8) ** 0.5"])
def test_out_of_range_results_are_errors(expression: str) -> None:
    with pytest.raises(OverflowError, match="result out of range"):
        calculate(expression)


def test_known_differences_from_csharp() -> None:
    assert calculate("1e3") == "1000.0"       # C# rejects 1e3: its parser reads digits and dots only
    assert calculate("10 ** 16") == "1e+16"   # C# prints 10000000000000000.0


@pytest.mark.asyncio
async def test_rag_search_posts_the_07_contract_and_formats_citations() -> None:
    requests: list[httpx.Request] = []
    async with fake_rag(requests=requests) as http:
        observation = await rag_search(http)(RagArgs(question="How do I roll back?"))

    assert requests[0].url == "http://rag.test/ask"
    assert json.loads(requests[0].content) == {"question": "How do I roll back?", "k": 4}
    assert observation == "Run `deploy --revert <sha>` with the last good SHA [S1].\nCitations: S1 (oncall.md)"


@pytest.mark.asyncio
async def test_rag_search_raises_on_an_error_status() -> None:
    async with fake_rag(status=500) as http:
        with pytest.raises(httpx.HTTPStatusError):
            await rag_search(http)(RagArgs(question="anything"))


@pytest.mark.asyncio
async def test_web_search_is_a_deterministic_mock() -> None:
    assert await web_search(SearchArgs(query="Latest PYTHON RELEASE?")) == "Python 3.14 was released in October 2025."
    assert await web_search(SearchArgs(query="weather")) == "No results found."


def test_calc_args_schema_names_the_argument() -> None:
    assert CalcArgs.model_json_schema()["required"] == ["expression"]
```

```python
# tests/test_approvals.py
import io

import pytest

from app.approvals import approver_from_env, ask_operator


def test_never_denies_without_reading_stdin(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO("y\n"))   # would approve, if it were read
    assert approver_from_env()("notify", {"message": "hi"}) is False


def test_unset_asks_the_operator(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("AGENT_AUTO_APPROVE")
    assert approver_from_env() is ask_operator


@pytest.mark.parametrize(("typed", "approved"), [("y\n", True), ("Y\n", True), ("yes\n", False), ("\n", False), ("", False)])
def test_only_y_approves(monkeypatch: pytest.MonkeyPatch, typed: str, approved: bool) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO(typed))   # "" is end of input: deny
    assert ask_operator("notify", {"message": "hi"}) is approved


def test_unreadable_stdin_denies() -> None:
    assert ask_operator("notify", {}) is False   # pytest's own stdin raises OSError on read


def test_unknown_mode_fails_loudly(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AGENT_AUTO_APPROVE", "always")
    with pytest.raises(ValueError, match="AGENT_AUTO_APPROVE"):
        approver_from_env()
```

```python
# tests/test_agent.py
from typing import Any

import pytest
from fakes import RecordingClient, fake_rag

from app.agent import STEP_LIMIT, run_agent, system_prompt
from app.tools import build_registry

CALC = '{"thought": "math", "tool": "calculator", "arguments": {"expression": "19 * 23"}}'
NOTIFY = '{"thought": "alert", "tool": "notify", "arguments": {"message": "deploy failed"}}'
DONE = '{"thought": "done", "answer": "437"}'


async def run(*replies: str, max_steps: int = 6, **kwargs: Any):
    client = RecordingClient(*replies)
    async with fake_rag() as http:
        result = await run_agent(client, "goal", build_registry(http), max_steps=max_steps, **kwargs)
    return result, client


def last_message(client: RecordingClient, call: int) -> str:
    """What the model was sent last on call number `call` (0-based)."""
    return client.calls[call][-1].content


@pytest.mark.asyncio
async def test_final_answer_ends_the_loop() -> None:
    result, client = await run(CALC, DONE)
    assert result.answer == "437"
    assert len(client.calls) == 2
    assert last_message(client, 1) == "Result of calculator: 437.0"
    assert client.calls[1][-1].role == "user"   # never "tool": this protocol makes no native calls


@pytest.mark.asyncio
async def test_step_cap_holds() -> None:
    result, client = await run(CALC, max_steps=3)   # the stub cycles: it never answers
    assert result.answer == STEP_LIMIT
    assert len(client.calls) == 3
    assert [s.number for s in result.steps] == [1, 2, 3]


@pytest.mark.asyncio
async def test_approval_gate_blocks_side_effects() -> None:
    # conftest sets AGENT_AUTO_APPROVE=never, so the real gate denies without touching stdin.
    result, client = await run(NOTIFY, DONE)
    assert result.steps[0].observation == "DENIED: the operator did not approve 'notify'"
    assert last_message(client, 1) == "Result of notify: DENIED: the operator did not approve 'notify'"


@pytest.mark.asyncio
async def test_approved_side_effect_runs_with_validated_arguments() -> None:
    asked: list[tuple[str, dict[str, Any]]] = []

    def approve(tool: str, args: dict[str, Any]) -> bool:
        asked.append((tool, args))
        return True

    result, _ = await run(NOTIFY, DONE, approve=approve)
    assert asked == [("notify", {"message": "deploy failed"})]
    assert result.steps[0].observation == "NOTIFIED: deploy failed"


@pytest.mark.asyncio
async def test_read_only_tools_never_ask() -> None:
    def approve(tool: str, args: dict[str, Any]) -> bool:
        raise AssertionError("the gate is only for side-effecting tools")

    result, _ = await run(CALC, DONE, approve=approve)
    assert result.answer == "437"


@pytest.mark.asyncio
async def test_unknown_tool_becomes_an_observation() -> None:
    result, client = await run('{"tool": "rm_rf", "arguments": {"path": "/"}}', DONE)
    assert result.steps[0].observation == "ERROR: unknown tool 'rm_rf'"
    assert last_message(client, 1) == "Result of rm_rf: ERROR: unknown tool 'rm_rf'"


@pytest.mark.asyncio
async def test_invalid_arguments_never_reach_the_tool() -> None:
    result, _ = await run('{"tool": "calculator", "arguments": {"expr": "1 + 1"}}', DONE)
    assert result.steps[0].observation.startswith("ERROR: invalid arguments for calculator: expression")


@pytest.mark.asyncio
async def test_tool_errors_become_observations() -> None:
    result, _ = await run('{"tool": "calculator", "arguments": {"expression": "1 / 0"}}', DONE)
    assert result.steps[0].observation == "ERROR from calculator: float division by zero"


@pytest.mark.asyncio
async def test_rag_search_goes_through_the_07_contract() -> None:
    result, _ = await run('{"tool": "rag_search", "arguments": {"question": "How do I roll back?"}}', DONE)
    assert result.steps[0].observation.endswith("\nCitations: S1 (oncall.md)")


@pytest.mark.asyncio
async def test_non_json_reply_is_fed_back_and_costs_a_step() -> None:
    result, client = await run("Sure! The answer is 437.", DONE)
    assert result.answer == "437"
    assert len(client.calls) == 2
    assert last_message(client, 1).startswith("That was not a valid reply: (root): Invalid JSON")


@pytest.mark.asyncio
async def test_tool_and_answer_together_is_invalid() -> None:
    result, client = await run('{"tool": "calculator", "answer": "both?"}', DONE)
    assert "exactly one of 'tool' or 'answer'" in last_message(client, 1)
    assert result.steps == []


@pytest.mark.asyncio
async def test_fenced_json_is_accepted() -> None:
    result, _ = await run("```json\n" + DONE + "\n```")
    assert result.answer == "437"


@pytest.mark.asyncio
async def test_system_prompt_lists_argument_schemas() -> None:
    async with fake_rag() as http:
        prompt = system_prompt(build_registry(http))
    for name in ("rag_search", "calculator", "web_search", "notify"):
        assert f"- {name}: " in prompt
    assert '"required": ["expression"]' in prompt   # the model sees the argument name, not just the tool


def test_transcript_format() -> None:
    from app.agent import AgentRun, Step

    run_ = AgentRun("437", [Step(1, "calculator", {"expression": "19 * 23"}, "437.0")])
    assert run_.transcript() == 'step 1: calculator {"expression":"19 * 23"}\n  -> 437.0\nanswer: 437'
```

`test_main.py` runs the CLI's `run` in-process on the scripted stub, with a fake 07, and pins the exact transcript. The C# suite pins the same text.

```python
# tests/test_main.py
import httpx
import pytest
from fakes import ASK_RESPONSE

from app.main import run

EXPECTED = """\
step 1: calculator {"expression":"19 * 23"}
  -> 437.0
step 2: rag_search {"question":"How do I roll back a deploy?"}
  -> Run `deploy --revert <sha>` with the last good SHA [S1].
Citations: S1 (oncall.md)
step 3: notify {"message":"Deploy failed; rolling back."}
  -> DENIED: the operator did not approve 'notify'
answer: 19 * 23 = 437. To roll back, run deploy --revert <sha> with the last good SHA. \
On-call was not notified: the operator denied it.
"""


@pytest.mark.asyncio
async def test_cli_runs_end_to_end_on_the_stub(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """ADR-002: the documented command works offline. A bare stub plays fixtures/stub_replies.jsonl,
    and a MockTransport stands in for the 07 service."""
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.delenv("LLM_STUB_REPLY", raising=False)
    fake_07 = httpx.MockTransport(lambda request: httpx.Response(200, json=ASK_RESPONSE))

    assert await run("What is 19 * 23, how do I roll back, and tell on-call?", transport=fake_07) == 0
    assert capsys.readouterr().out == EXPECTED


@pytest.mark.asyncio
async def test_unknown_backend_fails_loudly(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LLM_BACKEND", "bedrockk")
    with pytest.raises(ValueError, match="unknown LLM_BACKEND"):
        await run("anything")
```

Run them, then run the agent itself. On the stub it needs a 07 service for `rag_search`; the offline one from module 07 is enough.

```powershell
uv run pytest
uv run pytest tests/test_agent.py::test_step_cap_holds    # one test

# In another terminal, from projects/07-rag-service/python: 07 offline, then ingest.
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'
uv run --no-sync uvicorn app.main:app --port 8000
Invoke-RestMethod -Method Post http://localhost:8000/ingest

# Back here: the scripted run, then a real model.
$env:LLM_BACKEND = 'stub'; $env:AGENT_AUTO_APPROVE = 'never'
uv run python -m app.main "What is 19 * 23, how do I roll back a deploy, and tell on-call?"
Remove-Item Env:LLM_BACKEND, Env:AGENT_AUTO_APPROVE    # ollama, and the gate asks you
uv run python -m app.main "What is 19 * 23, and how do I roll back a deploy?"
```

For the real-model run, start 07 with a real model too (its own defaults), or `rag_search` answers with 07's stub text.

### Running the Python version in Docker

The image needs project 04 as well as `fixtures/`, so the build context is `projects/` and the image keeps the repo layout, as in [module 07](07-retrieval-augmented-generation.md). 07 isn't part of this stack: run it from its own folder, and the agent reaches it through `host.docker.internal`.

```dockerfile
# projects/08-agent/python/Dockerfile — build context: projects/
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
# Project 04 first: the path dependency must exist before uv can install anything.
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 08-agent/python/pyproject.toml 08-agent/python/uv.lock 08-agent/python/
WORKDIR /src/08-agent/python
# Service shape: install the locked dependencies (04 and the dev group included). The code is copied, never installed.
RUN uv sync --frozen --no-install-project
COPY 08-agent/python/ ./
COPY 08-agent/fixtures/ /src/08-agent/fixtures/
ENV PATH="/src/08-agent/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/08-agent/fixtures
# The goal is the container's argument: docker compose run --rm agent "<goal>"
ENTRYPOINT ["python", "-m", "app.main"]
```

```yaml
# projects/08-agent/python/compose.yaml
name: agent-py   # otherwise the project is named after the folder: "python"
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  agent:
    build: { context: ../.., dockerfile: 08-agent/python/Dockerfile }   # projects/: 04 and fixtures/ must be inside
    env_file:
      - path: .env   # hosted keys and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      RAG_URL: ${RAG_URL:-http://host.docker.internal:8000}   # 07 runs from its own folder; C# 07 is on 8001
      AGENT_AUTO_APPROVE: ${AGENT_AUTO_APPROVE:-never}         # unattended; run -e AGENT_AUTO_APPROVE= to be asked
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop
    stdin_open: true   # the approval prompt reads stdin when you're asked
    tty: true

volumes:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

With [native Ollama](conventions.md#ollama) running, the agent reaches it at `host.docker.internal:11434`. To run Ollama in the stack instead, add `--profile ollama`. Each `run` is one goal.

```powershell
# 1. Start 07 from projects/07-rag-service/python (docker compose up -d) and ingest its corpus.
# 2. Then:
cd projects/08-agent/python
docker compose run --rm --no-deps --entrypoint pytest agent -q             # no network
docker compose run --rm -e LLM_BACKEND=stub agent "What is 19 * 23?"         # the scripted model
docker compose run --rm agent "What is 19 * 23, and how do I roll back a deploy?"
docker compose run --rm agent "Notify on-call that the deploy failed."       # the gate denies it
docker compose run --rm -e AGENT_AUTO_APPROVE= agent "Notify on-call that the deploy failed."   # it asks you
# Ollama in the stack instead of native:
docker compose --profile ollama up -d ollama
docker compose exec ollama ollama pull llama3.2
$env:OLLAMA_BASE_URL = 'http://ollama:11434'; docker compose run --rm agent "What is 19 * 23?"
# Without compose, from the repo root:
# docker build -f projects/08-agent/python/Dockerfile -t agent-py projects
```

Watch the log: with a real model it should `calculator` the math, `rag_search` the deploy question, and combine both into a final answer — two tools, chosen by the model, in an order you didn't hard-code. Then **break it on purpose**: ask it to notify someone and confirm the gate blocks it. Give it a goal it can't satisfy and confirm it stops at the step cap instead of looping forever. Stop 07 and watch `rag_search` come back as an `ERROR from rag_search: ...` observation that the agent has to deal with.

> Small local models don't always follow the protocol. If replies flap between JSON and prose, that's the invalid-reply path doing its job, and a real finding for module 09. A stronger model behind the same `LLM_BACKEND` switch usually behaves better.

## C# implementation

Work in `projects/08-agent/csharp/`. Same tools, same protocol, same fixture, same transcript. What changes:

- **The model call is `IChatClient`.** Project 04's `AddLlmClient` registers it from `LLM_BACKEND`, exactly as `client_from_env()` does in Python. Tests pass project 04's `StubChatClient`, wrapped to record each call.
- **The loop still parses JSON by hand.** `IChatClient` can do native tool calling, and `UseFunctionInvocation()` will run the whole tool loop for you (see "Where frameworks fit" below). You don't use it here, for the same reason the Python version uses no framework: you write the loop once so you can see it, and the shared protocol keeps the two versions comparable step by step.
- **Records and `System.Text.Json` where Python has pydantic.** As in module 06, strictness is opt-in: required constructor parameters, nullable annotations, and no case-insensitive matching. `[JsonUnmappedMemberHandling(Disallow)]` is `extra="forbid"`. The schemas come from `AIJsonUtilities.CreateJsonSchema`.
- **Interfaces where Python has functions.** The approval gate is an `IApprovalGate`; the RAG tool is a typed `HttpClient` from `IHttpClientFactory`.
- **Logging is `ILogger` with scopes.** Each step opens a scope carrying `Step`, and the JSON console formatter writes one JSON object per event with the scope attached. Same idea as Python's `json.dumps` lines, but the fields are structured state, not a string inside the message.
- **The budget is a `CancellationToken`.** It flows into every call, the loop checks it each step, and it's the one exception the loop rethrows instead of turning into an observation.
- **The calculator is a parser you write.** Python gets a safe arithmetic evaluator by whitelisting `ast` nodes. .NET has no equivalent built in, so you write a small recursive-descent parser: about 60 lines, and the honest version of "never `eval` model output".

### Scaffold

From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 08-agent
cd projects/08-agent/csharp
Remove-Item tests/Agent.Tests/SmokeTests.cs, src/Agent/Program.cs
dotnet add src/Agent reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add src/Agent package Microsoft.Extensions.Hosting
```

The solution name defaults to `Agent`, so the loop class is `AgentLoop` to keep it distinct from the namespace. `Microsoft.Extensions.AI`, OllamaSharp and `AddHttpClient` all come through the reference to project 04. This doc was built against Microsoft.Extensions.AI 10.10.

### `src/Agent/Tools.cs`

```csharp
// src/Agent/Tools.cs
using System.ComponentModel;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Extensions.AI;

namespace Agent;

// Each tool's arguments are a record: the schema goes into the prompt, and the model's
// arguments are bound to it before anything runs (module 06).
public sealed record RagArgs([property: Description("A self-contained question for the knowledge base.")] string Question);
public sealed record CalcArgs([property: Description("Arithmetic only: numbers, + - * / ** and parentheses.")] string Expression);
public sealed record SearchArgs(string Query);
public sealed record NotifyArgs(string Message);

public static class ToolJson
{
    /// <summary>Strict, snake_case, and printed like Python's json.dumps(ensure_ascii=False).</summary>
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,          // "Expression" isn't "expression", as in pydantic
        RespectNullableAnnotations = true,            // "expression": null is an error
        RespectRequiredConstructorParameters = true,  // a missing "expression" is an error, not a null
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,   // write <sha> and ' as themselves
    };
}

/// <summary>A tool: what the model sees, how its arguments are bound, and how it runs.</summary>
public sealed class AgentTool
{
    public required string Name { get; init; }
    public required string Description { get; init; }
    public required JsonElement Schema { get; init; }
    public bool SideEffecting { get; init; }
    /// <summary>Untrusted JSON to typed arguments, or a JsonException.</summary>
    public required Func<JsonElement, object> Bind { get; init; }
    public required Func<object, CancellationToken, Task<string>> RunAsync { get; init; }

    public static AgentTool Create<TArgs>(
        string name, string description, Func<TArgs, CancellationToken, Task<string>> run, bool sideEffecting = false)
        where TArgs : class => new()
    {
        Name = name,
        Description = description,
        SideEffecting = sideEffecting,
        Schema = AIJsonUtilities.CreateJsonSchema(typeof(TArgs), serializerOptions: ToolJson.Options),
        Bind = raw => raw.Deserialize<TArgs>(ToolJson.Options) ?? throw new JsonException("expected a JSON object"),
        RunAsync = (args, ct) => run((TArgs)args, ct),
    };
}

public static class ToolRegistry
{
    public static IReadOnlyDictionary<string, AgentTool> Create(RagClient rag) => new[]
    {
        AgentTool.Create<RagArgs>("rag_search",
            "Answer a question from the internal knowledge base (runbooks, billing policy). " +
            "Returns an answer with citations.",
            (a, ct) => rag.SearchAsync(a.Question, ct)),
        AgentTool.Create<CalcArgs>("calculator", "Evaluate an arithmetic expression, e.g. '3 * (4 + 2)'.",
            (a, _) => Task.FromResult(Calculator.Evaluate(a.Expression))),
        AgentTool.Create<SearchArgs>("web_search", "Search the public web for current facts. Returns a short snippet.",
            (a, _) => Task.FromResult(MockWebSearch.Search(a.Query))),
        AgentTool.Create<NotifyArgs>("notify", "Send a message to the on-call channel. Has real side effects.",
            (a, _) => Task.FromResult($"NOTIFIED: {a.Message}"),   // the loop only gets here past the gate
            sideEffecting: true),
    }.ToDictionary(t => t.Name);
}

/// <summary>Mock search, so the project runs offline and deterministically.</summary>
public static class MockWebSearch
{
    private static readonly Dictionary<string, string> Canned = new()
    {
        ["python release"] = "Python 3.14 was released in October 2025.",
    };

    public static string Search(string query) =>
        Canned.FirstOrDefault(kv => query.Contains(kv.Key, StringComparison.OrdinalIgnoreCase)).Value
        ?? "No results found.";
}
```

The descriptions are copied word for word from the Python registry. They're prompts, so a different wording is a different experiment. The `Description` attributes become `description` in the schema, like pydantic's `Field(description=...)`.

### `src/Agent/Calculator.cs`

```csharp
// src/Agent/Calculator.cs
using System.Globalization;

namespace Agent;

/// <summary>
/// Safe arithmetic: numbers, + - * / ** unary minus and parentheses, nothing else.
/// The C# stand-in for Python's ast whitelist. NEVER hand model output to a script engine.
/// </summary>
public static class Calculator
{
    public static string Evaluate(string expression)
    {
        var parser = new Parser(expression);
        double value = parser.Expression();
        parser.ExpectEnd();
        if (!double.IsFinite(value))   // overflow is infinity, and (-8) ** 0.5 is NaN: refuse both, as Python does
            throw new OverflowException("result out of range");
        return Format(value);
    }

    // Python's str(float): 437.0, 0.25, 1e-05, 1e+17. .NET writes E for e and drops the ".0".
    // (One band still differs, 1e16 up to 1e17: see the cross-check.)
    private static string Format(double v)
    {
        string s = v.ToString(CultureInfo.InvariantCulture).Replace('E', 'e');
        return s.Contains('.') || s.Contains('e') ? s : s + ".0";
    }

    private sealed class Parser(string text)
    {
        private int _pos;

        // expression := term (('+' | '-') term)*
        public double Expression()
        {
            double value = Term();
            while (true)
            {
                if (Take("+")) value += Term();
                else if (Take("-")) value -= Term();
                else return value;
            }
        }

        // term := unary (('*' | '/') unary)*
        private double Term()
        {
            double value = Unary();
            while (true)
            {
                if (Peek("**")) return value;           // '**' belongs to Power, not '*'
                if (Take("*")) value *= Unary();
                else if (Take("/"))
                {
                    double divisor = Unary();
                    if (divisor == 0) throw new DivideByZeroException("float division by zero");
                    value /= divisor;
                }
                else return value;
            }
        }

        // unary := '-' unary | power      (so -2 ** 2 == -(2 ** 2), as in Python)
        private double Unary() => Take("-") ? -Unary() : Power();

        // power := primary ('**' unary)?   (right-associative: 2 ** 3 ** 2 == 2 ** 9)
        private double Power()
        {
            double b = Primary();
            return Take("**") ? Math.Pow(b, Unary()) : b;
        }

        private double Primary()
        {
            if (Take("("))
            {
                double inner = Expression();
                if (!Take(")")) throw Unsupported();
                return inner;
            }
            SkipSpaces();
            int start = _pos;
            while (_pos < text.Length && (char.IsAsciiDigit(text[_pos]) || text[_pos] == '.'))
                _pos++;
            if (start == _pos) throw Unsupported();
            return double.Parse(text.AsSpan(start, _pos - start), CultureInfo.InvariantCulture);
        }

        public void ExpectEnd()
        {
            SkipSpaces();
            if (_pos != text.Length) throw Unsupported();
        }

        private bool Peek(string token)
        {
            SkipSpaces();
            return text.AsSpan(_pos).StartsWith(token, StringComparison.Ordinal);
        }

        private bool Take(string token)
        {
            if (!Peek(token)) return false;
            _pos += token.Length;
            return true;
        }

        private void SkipSpaces()
        {
            while (_pos < text.Length && char.IsWhiteSpace(text[_pos])) _pos++;
        }

        private static FormatException Unsupported() => new("unsupported expression");
    }
}
```

### `src/Agent/RagClient.cs`

```csharp
// src/Agent/RagClient.cs
using System.Net.Http.Json;

namespace Agent;

/// <summary>The part of 07's /ask contract this tool reads. chunk_id and any new fields are ignored.</summary>
public sealed record Citation(string Tag, string Source);
public sealed record AskResponse(string Answer, IReadOnlyList<Citation> Citations);

/// <summary>Typed HttpClient for the module-07 /ask endpoint. Either 07 works: same contract, set RAG_URL.</summary>
public sealed class RagClient(HttpClient http)
{
    public async Task<string> SearchAsync(string question, CancellationToken ct)
    {
        using HttpResponseMessage resp = await http.PostAsJsonAsync("/ask", new { question, k = 4 }, ct);
        resp.EnsureSuccessStatusCode();   // a 4xx/5xx throws, and the loop turns it into an observation
        AskResponse data = await resp.Content.ReadFromJsonAsync<AskResponse>(ToolJson.Options, ct)
            ?? throw new InvalidOperationException("empty response from the RAG service");
        string cites = string.Join(", ", data.Citations.Select(c => $"{c.Tag} ({c.Source})"));
        return $"{data.Answer}\nCitations: {cites}";
    }
}
```

A non-2xx response throws, and the loop turns the exception into an `ERROR from rag_search: ...` observation, the same as Python's `raise_for_status()`.

### `src/Agent/Approvals.cs`

```csharp
// src/Agent/Approvals.cs
namespace Agent;

/// <summary>The human-in-the-loop gate for side-effecting tools.</summary>
public interface IApprovalGate
{
    Task<bool> ApproveAsync(string toolName, string argumentsJson, CancellationToken ct);
}

/// <summary>
/// Picked by AGENT_AUTO_APPROVE. "never" denies without asking: set it for every unattended run
/// (tests, CI, containers). Unset, it asks the operator, and only "y" approves. There is deliberately
/// no "always": nothing approves side effects on its own. Any other value fails at startup.
/// </summary>
public sealed class ConsoleApprovalGate : IApprovalGate
{
    private readonly bool _denyAll;
    private readonly TextReader _input;
    private readonly TextWriter _prompt;

    public ConsoleApprovalGate(string? mode, TextReader input, TextWriter prompt)
    {
        _denyAll = mode switch
        {
            "never" => true,
            null or "" => false,
            _ => throw new InvalidOperationException(
                $"unknown AGENT_AUTO_APPROVE '{mode}' (expected: never, or unset to ask)"),
        };
        (_input, _prompt) = (input, prompt);
    }

    public async Task<bool> ApproveAsync(string toolName, string argumentsJson, CancellationToken ct)
    {
        if (_denyAll)
            return false;

        await _prompt.WriteAsync($"[APPROVAL] Agent wants to call {toolName} with {argumentsJson}. Allow? [y/N] ");
        await _prompt.FlushAsync(ct);
        string? answer = await _input.ReadLineAsync(ct);   // null at end of input: deny
        return string.Equals(answer?.Trim(), "y", StringComparison.OrdinalIgnoreCase);
    }
}
```

The reader and writer are constructor parameters, so a test can type `y` with a `StringReader`. The app passes `Console.In` and `Console.Error`.

### `src/Agent/AgentLoop.cs`

```csharp
// src/Agent/AgentLoop.cs
using System.Diagnostics.CodeAnalysis;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

namespace Agent;

/// <summary>One model turn: call a tool, or answer. Untrusted input, validated like any other.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]   // pydantic's extra="forbid"
public sealed record Decision
{
    public string? Thought { get; init; }
    public string? Tool { get; init; }
    public Dictionary<string, JsonElement> Arguments { get; init; } = [];
    public string? Answer { get; init; }
}

public sealed record AgentStep(int Number, string Tool, string Arguments, string Observation);

public sealed record AgentRun(string Answer, IReadOnlyList<AgentStep> Steps)
{
    /// <summary>What the CLI prints: every action, what came back, then the answer.</summary>
    public string Transcript()
    {
        var sb = new StringBuilder();
        foreach (AgentStep s in Steps)
            sb.Append($"step {s.Number}: {s.Tool} {s.Arguments}\n  -> {s.Observation}\n");
        return sb.Append($"answer: {Answer}").ToString();
    }
}

/// <summary>reason → act → observe, bounded by maxSteps. The whole agent, visible end to end.</summary>
public sealed class AgentLoop(
    IChatClient chat,
    IReadOnlyDictionary<string, AgentTool> tools,
    IApprovalGate approvals,
    ILogger<AgentLoop> logger)
{
    // Module 06's protocol, plus an optional "thought": the reason step, logged with each action.
    public const string ReplyFormat =
        """Reply with ONE JSON object and nothing else: {"thought": "<why>", "tool": "<name>", "arguments": {...}} """ +
        """to call a tool, or {"thought": "<why>", "answer": "<text>"} when you can answer.""";

    public const string StepLimit = "Step limit reached without a final answer.";

    /// <summary>Names, descriptions and argument schemas: the model can't call what it can't see.</summary>
    public string SystemPrompt()
    {
        // Re-serialized with ToolJson's relaxed encoder: the raw schema text escapes "+" and "'".
        IEnumerable<string> listed = tools.Values.Select(t =>
            $"- {t.Name}: {t.Description} Arguments (JSON Schema): {JsonSerializer.Serialize(t.Schema, ToolJson.Options)}");
        return "You are a tool-using assistant. Work towards the user's goal one step at a time.\n" +
               $"Tools:\n{string.Join("\n", listed)}\n" +
               "Use rag_search for internal knowledge, calculator for arithmetic, web_search for public facts, " +
               "and notify only when the user explicitly asks you to alert someone.\n" +
               ReplyFormat;
    }

    public async Task<AgentRun> RunAsync(string goal, int maxSteps = 6, CancellationToken ct = default)
    {
        List<ChatMessage> messages = [new(ChatRole.System, SystemPrompt()), new(ChatRole.User, goal)];
        List<AgentStep> steps = [];
        var options = new ChatOptions { MaxOutputTokens = 512 };

        for (int number = 1; number <= maxSteps; number++)
        {
            ct.ThrowIfCancellationRequested();   // the budget bounds the loop even when no call notices it
            // Every event logged in this step carries Step; the JSON console formatter writes it out.
            using IDisposable? scope = logger.BeginScope("Step {Step}", number);

            ChatResponse response = await chat.GetResponseAsync(messages, options, ct);    // reason
            messages.Add(new(ChatRole.Assistant, response.Text));

            if (!TryParse(response.Text, out Decision? decision, out string? error))
            {
                // A malformed turn costs a step, and the model is told exactly what was wrong.
                logger.LogWarning("Invalid reply: {Error}", error);
                messages.Add(new(ChatRole.User, $"That was not a valid reply: {error}\n{ReplyFormat}"));
                continue;
            }

            if (decision.Answer is { } answer)
            {
                logger.LogInformation("Answer. Thought: {Thought}", decision.Thought);
                return new AgentRun(answer, steps);
            }

            string tool = decision.Tool!;                                                       // TryParse guarantees it
            string arguments = JsonSerializer.Serialize(decision.Arguments, ToolJson.Options);
            string observation = await ObserveAsync(tool, decision.Arguments, ct);              // act
            logger.LogInformation("Act {Tool} {Arguments} -> {Observation}. Thought: {Thought}",
                tool, arguments, observation, decision.Thought);
            steps.Add(new(number, tool, arguments, observation));
            // observe: a User message, not ChatRole.Tool. Providers only accept a tool role in answer
            // to a native tool call, and this protocol doesn't make one (module 06).
            messages.Add(new(ChatRole.User, $"Result of {tool}: {observation}"));
        }

        logger.LogWarning("Step limit {MaxSteps} reached", maxSteps);
        return new AgentRun(StepLimit, steps);
    }

    private static bool TryParse(string text, [NotNullWhen(true)] out Decision? decision, out string? error)
    {
        decision = null;
        try
        {
            decision = JsonSerializer.Deserialize<Decision>(StripFences(text), ToolJson.Options);
            error = decision is null ? "expected a JSON object, got null"
                : (decision.Tool is null) == (decision.Answer is null) ? "set exactly one of 'tool' or 'answer'"
                : null;
        }
        catch (JsonException e)
        {
            error = e.Message;   // includes the JSON path, e.g. $.tool
        }
        return error is null;
    }

    /// <summary>Tolerate ```json ... ``` wrapping, which models add even when told not to.</summary>
    public static string StripFences(string text)
    {
        string t = text.Trim();
        if (!t.StartsWith("```", StringComparison.Ordinal))
            return t;
        t = t.Split("```")[1];
        return (t.StartsWith("json", StringComparison.Ordinal) ? t["json".Length..] : t).Trim();
    }

    /// <summary>The choke point: known tool, valid arguments, approval, and only then run it.</summary>
    private async Task<string> ObserveAsync(string name, Dictionary<string, JsonElement> rawArgs, CancellationToken ct)
    {
        if (!tools.TryGetValue(name, out AgentTool? tool))
            return $"ERROR: unknown tool '{name}'";

        object args;
        try
        {
            args = tool.Bind(JsonSerializer.SerializeToElement(rawArgs, ToolJson.Options));
        }
        catch (JsonException e)
        {
            return $"ERROR: invalid arguments for {name}: {e.Message}";
        }

        // The human approves the validated arguments, not whatever the model sent.
        if (tool.SideEffecting
            && !await approvals.ApproveAsync(name, JsonSerializer.Serialize(args, args.GetType(), ToolJson.Options), ct))
            return $"DENIED: the operator did not approve '{name}'";

        try
        {
            return await tool.RunAsync(args, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;   // the budget ran out (or Ctrl+C): not a tool failure, so stop the run
        }
        catch (Exception ex)
        {
            return $"ERROR from {name}: {ex.Message}";   // a failing tool is information for the agent
        }
    }
}
```

Compare it with the Python loop line by line: same cap, same strings, same order of checks (unknown tool, arguments, approval, run). The one addition is the `CancellationToken`, and the `catch ... when (ct.IsCancellationRequested)` that lets it through. Without that filter, `catch (Exception)` would swallow the budget and the agent would carry on past it. An `HttpClient` timeout is also an `OperationCanceledException`, but the budget's token isn't cancelled, so it becomes an observation like any other tool failure.

### `src/Agent/Program.cs`

```csharp
// src/Agent/Program.cs
using Agent;
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;

// Usage: dotnet run --project src/Agent -- "<goal>"
// The transcript and answer go to stdout; the JSON step log goes to stderr.
if (args is not [var goal])
{
    Console.Error.WriteLine("usage: dotnet run --project src/Agent -- \"<goal>\"");
    return 2;
}

const int BudgetSeconds = 120;   // wall-clock cap for the whole run, on top of the step cap

// No args passed to the builder: the goal is input, not a config switch.
HostApplicationBuilder builder = Host.CreateApplicationBuilder();
IConfiguration config = builder.Configuration;   // env vars: LLM_BACKEND, RAG_URL, AGENT_AUTO_APPROVE, ...

// One JSON object per log event, with the Step scope attached, on stderr.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o => o.IncludeScopes = true);
builder.Logging.AddFilter("System.Net.Http", LogLevel.Warning);   // no lines per HTTP request
builder.Services.Configure<ConsoleLoggerOptions>(o => o.LogToStandardErrorThreshold = LogLevel.Trace);

// Relative to csharp/, where you run from; the Dockerfile sets it.
string fixturesDir = config["FIXTURES_DIR"] ?? "../fixtures";

if (config["LLM_BACKEND"] == "stub" && string.IsNullOrEmpty(config["LLM_STUB_REPLY"]))
{
    // On a bare stub, play the scripted model in fixtures/stub_replies.jsonl, as main.py does,
    // with project 04's cost logging around it like every other backend.
    string[] script = [.. File.ReadLines(Path.Combine(fixturesDir, "stub_replies.jsonl"))
        .Where(line => !string.IsNullOrWhiteSpace(line))];
    builder.Services.AddChatClient(new StubChatClient(script))
        .Use((inner, sp) => new CostLoggingChatClient(
            inner, Rates.Free, sp.GetRequiredService<ILogger<CostLoggingChatClient>>()));
}
else
{
    builder.Services.AddLlmClient(config);   // project 04: the LLM_BACKEND switch (fails loudly), retries, cost logging
}

builder.Services.AddHttpClient<RagClient>(c =>
{
    c.BaseAddress = new Uri(config["RAG_URL"] ?? "http://localhost:8000");   // Python 07; C# 07 is on 8001
    c.Timeout = TimeSpan.FromSeconds(30);
});
// Transient, not singleton: the registry captures a typed HttpClient, and a singleton would pin it forever.
builder.Services.AddTransient(sp => ToolRegistry.Create(sp.GetRequiredService<RagClient>()));
// Built now, so an unknown AGENT_AUTO_APPROVE fails before the first model call. Prompts on stderr.
builder.Services.AddSingleton<IApprovalGate>(
    new ConsoleApprovalGate(config["AGENT_AUTO_APPROVE"], Console.In, Console.Error));
builder.Services.AddTransient<AgentLoop>();

using IHost host = builder.Build();
using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(BudgetSeconds));
try
{
    AgentRun run = await host.Services.GetRequiredService<AgentLoop>().RunAsync(goal, maxSteps: 6, budget.Token);
    Console.WriteLine(run.Transcript());
    return 0;
}
catch (OperationCanceledException) when (budget.IsCancellationRequested)
{
    // The loop rethrows cancellation instead of turning it into an observation; this is where it lands.
    Console.Error.WriteLine($"Stopped: the {BudgetSeconds}-second budget ran out.");
    return 1;
}
```

When the budget runs out, the exception comes up through `RunAsync` and lands in the `catch` at the bottom: one line on stderr and exit code 1, not a stack trace.

### Tests

```csharp
// tests/Agent.Tests/Fakes.cs
using System.Net;
using System.Text;
using LlmClient;
using Microsoft.Extensions.AI;

namespace Agent.Tests;

/// <summary>Project 04's StubChatClient replaying replies in order (cycling), plus a record of what
/// each call was sent. Only the model is fake: the loop under test is the real code.</summary>
public sealed class RecordingChatClient(params string[] replies) : DelegatingChatClient(new StubChatClient(replies))
{
    public List<List<ChatMessage>> Calls { get; } = [];

    public override Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        List<ChatMessage> snapshot = [.. messages];   // the loop keeps appending to its list
        Calls.Add(snapshot);
        return base.GetResponseAsync(snapshot, options, cancellationToken);
    }

    /// <summary>The last message sent on call number <paramref name="call"/> (0-based).</summary>
    public string LastMessage(int call) => Calls[call][^1].Text;
}

/// <summary>An HttpMessageHandler whose "network" is a canned 07 response: no 07 service needed.</summary>
public sealed class Fake07(HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
{
    public const string AskResponse = """
        {"answer": "Run `deploy --revert <sha>` with the last good SHA [S1].",
         "citations": [{"tag": "S1", "source": "oncall.md", "chunk_id": "oncall.md#0"}]}
        """;

    public List<(Uri? Uri, string Body)> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Requests.Add((request.RequestUri, request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct)));
        string body = status == HttpStatusCode.OK ? AskResponse : """{"detail": "boom"}""";
        return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    }

    public RagClient Client() => new(new HttpClient(this) { BaseAddress = new Uri("http://rag.test") });
}

/// <summary>Records what it was asked, and answers with a fixed verdict.</summary>
public sealed class FixedGate(bool verdict) : IApprovalGate
{
    public List<(string Tool, string Arguments)> Asked { get; } = [];

    public Task<bool> ApproveAsync(string toolName, string argumentsJson, CancellationToken ct)
    {
        Asked.Add((toolName, argumentsJson));
        return Task.FromResult(verdict);
    }
}

public static class TestPaths
{
    /// <summary>The project's fixtures/ folder, found by walking up from the test binaries.</summary>
    public static string Fixtures { get; } = FindUp();

    private static string FindUp()
    {
        for (DirectoryInfo? d = new(AppContext.BaseDirectory); d is not null; d = d.Parent)
        {
            string candidate = Path.Combine(d.FullName, "fixtures");
            if (File.Exists(Path.Combine(candidate, "stub_replies.jsonl"))) return candidate;
        }
        throw new DirectoryNotFoundException($"no fixtures/stub_replies.jsonl above {AppContext.BaseDirectory}");
    }
}
```

```csharp
// tests/Agent.Tests/AgentLoopTests.cs
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;

namespace Agent.Tests;

public class AgentLoopTests
{
    private const string Calc = """{"thought": "math", "tool": "calculator", "arguments": {"expression": "19 * 23"}}""";
    private const string Notify = """{"thought": "alert", "tool": "notify", "arguments": {"message": "deploy failed"}}""";
    private const string Done = """{"thought": "done", "answer": "437"}""";

    // The real gate, unattended: AGENT_AUTO_APPROVE=never. It must never read its input.
    private static readonly IApprovalGate Never =
        new ConsoleApprovalGate("never", new StringReader("y\n"), TextWriter.Null);

    private static AgentLoop Loop(IChatClient chat, IApprovalGate? gate = null) =>
        new(chat, ToolRegistry.Create(new Fake07().Client()), gate ?? Never, NullLogger<AgentLoop>.Instance);

    [Test]
    public async Task Final_answer_ends_the_loop()
    {
        var chat = new RecordingChatClient(Calc, Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Answer, Is.EqualTo("437"));
        Assert.That(chat.Calls, Has.Count.EqualTo(2));
        Assert.That(chat.LastMessage(1), Is.EqualTo("Result of calculator: 437.0"));
        Assert.That(chat.Calls[1][^1].Role, Is.EqualTo(ChatRole.User));   // never Tool: no native calls here
    }

    [Test]
    public async Task Step_cap_holds()
    {
        var chat = new RecordingChatClient(Calc);   // the stub cycles: it never answers
        AgentRun run = await Loop(chat).RunAsync("goal", maxSteps: 3);

        Assert.That(run.Answer, Is.EqualTo(AgentLoop.StepLimit));
        Assert.That(chat.Calls, Has.Count.EqualTo(3));
        Assert.That(run.Steps.Select(s => s.Number), Is.EqualTo(new[] { 1, 2, 3 }));
    }

    [Test]
    public async Task Approval_gate_blocks_side_effects()
    {
        var chat = new RecordingChatClient(Notify, Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Steps[0].Observation, Is.EqualTo("DENIED: the operator did not approve 'notify'"));
        Assert.That(chat.LastMessage(1), Is.EqualTo("Result of notify: DENIED: the operator did not approve 'notify'"));
    }

    [Test]
    public async Task Approved_side_effect_runs_with_validated_arguments()
    {
        var gate = new FixedGate(true);
        AgentRun run = await Loop(new RecordingChatClient(Notify, Done), gate).RunAsync("goal");

        Assert.That(gate.Asked, Is.EqualTo(new[] { ("notify", """{"message":"deploy failed"}""") }));
        Assert.That(run.Steps[0].Observation, Is.EqualTo("NOTIFIED: deploy failed"));
    }

    [Test]
    public async Task Read_only_tools_never_ask()
    {
        var gate = new FixedGate(false);
        AgentRun run = await Loop(new RecordingChatClient(Calc, Done), gate).RunAsync("goal");

        Assert.That(run.Answer, Is.EqualTo("437"));
        Assert.That(gate.Asked, Is.Empty);
    }

    [Test]
    public async Task Unknown_tool_becomes_an_observation()
    {
        var chat = new RecordingChatClient("""{"tool": "rm_rf", "arguments": {"path": "/"}}""", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Steps[0].Observation, Is.EqualTo("ERROR: unknown tool 'rm_rf'"));
        Assert.That(chat.LastMessage(1), Is.EqualTo("Result of rm_rf: ERROR: unknown tool 'rm_rf'"));
    }

    [Test]
    public async Task Invalid_arguments_never_reach_the_tool()
    {
        var chat = new RecordingChatClient("""{"tool": "calculator", "arguments": {"expr": "1 + 1"}}""", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Steps[0].Observation, Does.StartWith("ERROR: invalid arguments for calculator:"));
        Assert.That(run.Steps[0].Observation, Does.Contain("expression"));
    }

    [Test]
    public async Task Tool_errors_become_observations()
    {
        var chat = new RecordingChatClient("""{"tool": "calculator", "arguments": {"expression": "1 / 0"}}""", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Steps[0].Observation, Is.EqualTo("ERROR from calculator: float division by zero"));
    }

    [Test]
    public async Task Rag_search_goes_through_the_07_contract()
    {
        var chat = new RecordingChatClient("""{"tool": "rag_search", "arguments": {"question": "How do I roll back?"}}""", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Steps[0].Observation, Does.EndWith("\nCitations: S1 (oncall.md)"));
    }

    [Test]
    public async Task Non_json_reply_is_fed_back_and_costs_a_step()
    {
        var chat = new RecordingChatClient("Sure! The answer is 437.", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(run.Answer, Is.EqualTo("437"));
        Assert.That(chat.Calls, Has.Count.EqualTo(2));
        Assert.That(chat.LastMessage(1), Does.StartWith("That was not a valid reply: "));
    }

    [Test]
    public async Task Tool_and_answer_together_is_invalid()
    {
        var chat = new RecordingChatClient("""{"tool": "calculator", "answer": "both?"}""", Done);
        AgentRun run = await Loop(chat).RunAsync("goal");

        Assert.That(chat.LastMessage(1), Does.Contain("exactly one of 'tool' or 'answer'"));
        Assert.That(run.Steps, Is.Empty);
    }

    [Test]
    public async Task Fenced_json_is_accepted()
    {
        AgentRun run = await Loop(new RecordingChatClient("```json\n" + Done + "\n```")).RunAsync("goal");
        Assert.That(run.Answer, Is.EqualTo("437"));
    }

    [Test]
    public void System_prompt_lists_argument_schemas()
    {
        string prompt = Loop(new RecordingChatClient(Done)).SystemPrompt();

        foreach (string name in new[] { "rag_search", "calculator", "web_search", "notify" })
            Assert.That(prompt, Does.Contain($"- {name}: "));
        Assert.That(prompt, Does.Contain("\"required\":[\"expression\"]"));   // the model sees the argument name
    }

    [Test]
    public void A_cancelled_budget_stops_the_run_instead_of_becoming_an_observation()
    {
        using var budget = new CancellationTokenSource();
        budget.Cancel();
        Assert.That(async () => await Loop(new RecordingChatClient(Calc, Done)).RunAsync("goal", ct: budget.Token),
            Throws.InstanceOf<OperationCanceledException>());
    }

    [Test]
    public async Task Scripted_run_matches_the_python_transcript()
    {
        // The same fixture, the same canned 07 response and the same expected text as test_main.py.
        string[] script = [.. File.ReadLines(Path.Combine(TestPaths.Fixtures, "stub_replies.jsonl"))
            .Where(line => !string.IsNullOrWhiteSpace(line))];
        AgentRun run = await Loop(new StubChatClient(script)).RunAsync("goal");

        Assert.That(run.Transcript(), Is.EqualTo("""
            step 1: calculator {"expression":"19 * 23"}
              -> 437.0
            step 2: rag_search {"question":"How do I roll back a deploy?"}
              -> Run `deploy --revert <sha>` with the last good SHA [S1].
            Citations: S1 (oncall.md)
            step 3: notify {"message":"Deploy failed; rolling back."}
              -> DENIED: the operator did not approve 'notify'
            answer: 19 * 23 = 437. To roll back, run deploy --revert <sha> with the last good SHA. On-call was not notified: the operator denied it.
            """.ReplaceLineEndings("\n")));
    }
}
```

```csharp
// tests/Agent.Tests/CalculatorTests.cs
namespace Agent.Tests;

public class CalculatorTests
{
    // The same expressions are pinned in test_tools.py: both must print these exact strings.
    [TestCase("19 * 23", "437.0")]
    [TestCase("3 * (4 + 2)", "18.0")]
    [TestCase("1 / 4", "0.25")]
    [TestCase("-2 ** 2", "-4.0")]      // unary minus binds looser than **
    [TestCase("2 ** 3 ** 2", "512.0")] // ** is right-associative
    [TestCase("2 ** -1", "0.5")]
    [TestCase("1 / 100000", "1e-05")]
    [TestCase("10 ** 15", "1000000000000000.0")]
    [TestCase("10 ** 17", "1e+17")]
    public void Evaluates_like_python(string expression, string expected) =>
        Assert.That(Calculator.Evaluate(expression), Is.EqualTo(expected));

    [TestCase("__import__('os').system('ls')")]
    [TestCase("2 % 3")]
    [TestCase("1 +")]
    [TestCase("True + 1")]
    [TestCase("x * 2")]
    public void Rejects_anything_else(string expression) =>
        Assert.That(() => Calculator.Evaluate(expression),
            Throws.TypeOf<FormatException>().With.Message.EqualTo("unsupported expression"));

    [Test]
    public void Division_by_zero_is_an_error_not_infinity() =>
        Assert.That(() => Calculator.Evaluate("1 / 0"),
            Throws.TypeOf<DivideByZeroException>().With.Message.EqualTo("float division by zero"));

    [TestCase("10 ** 400")]
    [TestCase("(-8) ** 0.5")]
    public void Out_of_range_results_are_errors(string expression) =>
        Assert.That(() => Calculator.Evaluate(expression),
            Throws.TypeOf<OverflowException>().With.Message.EqualTo("result out of range"));

    [Test]
    public void Known_differences_from_python()
    {
        Assert.That(() => Calculator.Evaluate("1e3"), Throws.TypeOf<FormatException>());   // Python: 1000.0
        Assert.That(Calculator.Evaluate("10 ** 16"), Is.EqualTo("10000000000000000.0"));     // Python: 1e+16
    }
}
```

```csharp
// tests/Agent.Tests/ToolTests.cs
using System.Net;
using System.Text.Json;

namespace Agent.Tests;

public class ToolTests
{
    [Test]
    public async Task Rag_search_posts_the_07_contract_and_formats_citations()
    {
        var fake = new Fake07();
        string observation = await fake.Client().SearchAsync("How do I roll back?", CancellationToken.None);

        Assert.That(fake.Requests[0].Uri, Is.EqualTo(new Uri("http://rag.test/ask")));
        using JsonDocument body = JsonDocument.Parse(fake.Requests[0].Body);
        Assert.That(body.RootElement.GetProperty("question").GetString(), Is.EqualTo("How do I roll back?"));
        Assert.That(body.RootElement.GetProperty("k").GetInt32(), Is.EqualTo(4));
        Assert.That(observation,
            Is.EqualTo("Run `deploy --revert <sha>` with the last good SHA [S1].\nCitations: S1 (oncall.md)"));
    }

    [Test]
    public void Rag_search_throws_on_an_error_status() =>
        Assert.That(async () => await new Fake07(HttpStatusCode.InternalServerError).Client()
                .SearchAsync("anything", CancellationToken.None),
            Throws.TypeOf<HttpRequestException>());

    [Test]
    public void Web_search_is_a_deterministic_mock()
    {
        Assert.That(MockWebSearch.Search("Latest PYTHON RELEASE?"), Is.EqualTo("Python 3.14 was released in October 2025."));
        Assert.That(MockWebSearch.Search("weather"), Is.EqualTo("No results found."));
    }

    [Test]
    public async Task Never_denies_without_reading_input()
    {
        var gate = new ConsoleApprovalGate("never", new StringReader("y\n"), TextWriter.Null);
        Assert.That(await gate.ApproveAsync("notify", "{}", CancellationToken.None), Is.False);
    }

    [TestCase("y\n", true)]
    [TestCase("Y\n", true)]
    [TestCase("yes\n", false)]
    [TestCase("\n", false)]
    [TestCase("", false)]   // end of input: deny
    public async Task Only_y_approves(string typed, bool approved)
    {
        var gate = new ConsoleApprovalGate(null, new StringReader(typed), TextWriter.Null);
        Assert.That(await gate.ApproveAsync("notify", "{}", CancellationToken.None), Is.EqualTo(approved));
    }

    [Test]
    public void Unknown_mode_fails_loudly() =>
        Assert.That(() => new ConsoleApprovalGate("always", TextReader.Null, TextWriter.Null),
            Throws.InvalidOperationException.With.Message.Contains("AGENT_AUTO_APPROVE"));
}
```

Run them, then the agent. As in Python, the scripted run needs a 07 service; `RAG_URL` defaults to the Python one on 8000.

```powershell
dotnet test
dotnet test --filter "FullyQualifiedName~AgentLoopTests"
$env:LLM_BACKEND = 'stub'; $env:AGENT_AUTO_APPROVE = 'never'
dotnet run --project src/Agent -- "What is 19 * 23, how do I roll back a deploy, and tell on-call?"
$env:RAG_URL = 'http://localhost:8001'                   # C# 07 instead
Remove-Item Env:LLM_BACKEND, Env:AGENT_AUTO_APPROVE      # ollama, and the gate asks you
dotnet run --project src/Agent -- "Notify on-call that the deploy failed."
```

### Running the C# version in Docker

The same multi-stage shape as module 06: the SDK image restores, builds and tests; the runtime image runs the agent. The context is `projects/` because of the reference to project 04, and the build stage gets `fixtures/` too, because one test reads the script.

```dockerfile
# projects/08-agent/csharp/Dockerfile — build context: projects/
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer: every .csproj, plus 04's Directory.Build.props (MSBuild applies the nearest one).
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 08-agent/csharp/Agent.slnx 08-agent/csharp/Directory.Build.props 08-agent/csharp/
COPY 08-agent/csharp/src/Agent/Agent.csproj 08-agent/csharp/src/Agent/
COPY 08-agent/csharp/tests/Agent.Tests/Agent.Tests.csproj 08-agent/csharp/tests/Agent.Tests/
WORKDIR /src/08-agent/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 08-agent/csharp/ 08-agent/csharp/
COPY 08-agent/fixtures/ 08-agent/fixtures/
WORKDIR /src/08-agent/csharp
RUN dotnet publish src/Agent -c Release -o /app --no-restore

FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 08-agent/fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
USER $APP_UID
# The goal is the container's argument: docker compose run --rm agent "<goal>"
ENTRYPOINT ["dotnet", "Agent.dll"]
```

```yaml
# projects/08-agent/csharp/compose.yaml
name: agent-cs
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  agent:
    build: { context: ../.., dockerfile: 08-agent/csharp/Dockerfile, target: final }   # projects/: 04 must be inside
    env_file:
      - path: .env   # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      RAG_URL: ${RAG_URL:-http://host.docker.internal:8000}   # 07 runs from its own folder; C# 07 is on 8001
      AGENT_AUTO_APPROVE: ${AGENT_AUTO_APPROVE:-never}         # unattended; run -e AGENT_AUTO_APPROVE= to be asked
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop
    stdin_open: true   # the approval prompt reads stdin when you're asked
    tty: true

  test:
    build: { context: ../.., dockerfile: 08-agent/csharp/Dockerfile, target: test }
    profiles: [test]   # only runs when asked for by name

volumes:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

```powershell
# 1. Start 07 from its own folder and ingest. For C# 07: $env:RAG_URL = 'http://host.docker.internal:8001'
cd projects/08-agent/csharp
docker compose run --rm test                                                # dotnet test in the SDK image
docker compose run --rm -e LLM_BACKEND=stub agent "What is 19 * 23?"         # the scripted model
docker compose run --rm agent "What is 19 * 23, and how do I roll back a deploy?"
docker compose run --rm agent "Notify on-call that the deploy failed."       # the gate denies it
# Without compose, from the repo root:
# docker build -f projects/08-agent/csharp/Dockerfile --target final -t agent-cs projects
```

With `--profile ollama`, this stack and the Python one both publish Ollama on 11434, so run one at a time, or use native Ollama for both. The shared `ai-learn-ollama` volume means a model pulled in one is there in the other.

### Where frameworks fit in .NET

Now that you've written the loop, here's what the .NET libraries offer on top of it.

**`UseFunctionInvocation()`** is middleware in `Microsoft.Extensions.AI`. It wraps an `IChatClient`, and when the model asks for a tool through native tool calling, it invokes your function, appends the result, and calls the model again until it gets a plain answer. That's this module's loop with native tool calls instead of JSON-in-text. Module 06 showed it in a test:

```csharp
IChatClient client = new ChatClientBuilder(new OllamaApiClient(new Uri("http://localhost:11434"), "llama3.2"))
    .UseFunctionInvocation(configure: f => f.MaximumIterationsPerRequest = 6)   // the step cap
    .Build();

var options = new ChatOptions
{
    Tools = [AIFunctionFactory.Create(Calculator.Evaluate, "calculator", "Evaluate an arithmetic expression, e.g. '3 * (4 + 2)'.")],
};
ChatResponse answer = await client.GetResponseAsync("What is 19 * 23?", options);
```

It's the right tool for a simple, read-only tool loop. Notice what it doesn't give you by default: an approval gate, a per-step log in your format, a wall-clock budget. Newer versions of `Microsoft.Extensions.AI` add an approval mechanism (an `ApprovalRequiredAIFunction` wrapper that surfaces approval requests to the caller). It was marked experimental when this was written, so check the current docs before you rely on it.

**Microsoft Agent Framework** is Microsoft's .NET (and Python) agent orchestration framework, the successor to Semantic Kernel's agent APIs and AutoGen. It builds agents on top of `IChatClient` and adds conversation threads, multi-agent orchestration, and graph-based workflows: the .NET counterpart of LangGraph. Its API was still moving at the time of writing, so treat this sketch as the shape to look for, not exact names (package `Microsoft.Agents.AI`, verify against current docs):

```csharp
// Shape only. Verify type and package names against the current Microsoft Agent Framework docs.
AIAgent agent = new ChatClientAgent(chatClient,
    instructions: "You are a tool-using assistant.",
    tools: [AIFunctionFactory.Create(Calculator.Evaluate, "calculator", "Evaluate an arithmetic expression.")]);
var result = await agent.RunAsync("What is 19 * 23?");
```

The same advice as the Python side applies: adopt it when you feel the problem it solves (durable threads, multi-agent hand-offs, checkpointed workflows), not to make a 100-line loop look more official.

## Cross-check the two

The model makes the two agents' runs differ, so cross-check in two layers.

**Exact, on the stub.** Run both CLIs on the scripted model against the same 07 service. stdout (every action, every observation, the answer) must match line for line. Start 07 offline as in the Python section (on 8000, then `/ingest`), and from `projects/08-agent`:

```powershell
$env:LLM_BACKEND = 'stub'; $env:AGENT_AUTO_APPROVE = 'never'; $env:RAG_URL = 'http://localhost:8000'
$goal = 'What is 19 * 23, how do I roll back a deploy, and tell on-call?'
Push-Location python; uv run python -m app.main $goal 2> ../py.err > ../py.out; Pop-Location
Push-Location csharp; dotnet run --project src/Agent -- $goal 2> ../cs.err > ../cs.out; Pop-Location
Compare-Object (Get-Content py.out) (Get-Content cs.out)    # no output = identical
```

That one comparison covers the protocol parsing, argument binding, the calculator's number formatting, the `/ask` request and the citation formatting (07's stub answer echoes its whole prompt, so it's a long observation), the gate, and the transcript. The same text is pinned in both test suites (`test_cli_runs_end_to_end_on_the_stub` and `Scripted_run_matches_the_python_transcript`), with a fake 07, so drift shows up on every build without servers. The calculator's expressions are pinned case for case as well, including `-2 ** 2` and `2 ** 3 ** 2`, where precedence mistakes show up.

**Known differences**, found by running the same input on both sides:

- **The `llm_call` lines** agree on `out=` but not on `in=`: the stub counts prompt words, and the schemas differ. pydantic adds `title` fields and `json.dumps` adds spaces; `AIJsonUtilities` writes neither. The system prompt is the one prompt that legitimately differs. (Printing the raw C# schema would also show `\u002B` for `+`, which is why `SystemPrompt` re-serializes it with the relaxed encoder.)
- **`1e3`** is a valid Python literal, so Python's calculator returns `1000.0`; the C# parser reads digits and dots only and rejects it. Teach the parser exponents if you need them.
- **Whole numbers from 1e16 up to 1e17** print as `1e+16` in Python and `10000000000000000.0` in .NET, which only switches to exponent form at 1e17. Below and above that band the formatter matches Python (`1e-05`, `1e+17`): .NET writes `E`, so `Format` lower-cases it.
- **Error messages** for bad arguments and HTTP failures differ (pydantic vs `JsonException`; httpx vs `HttpRequestException`). The prefixes match (`ERROR: invalid arguments for calculator:`, `ERROR from rag_search:`), and the tests check prefixes.
- **The log envelope.** Python writes the event itself as the line; .NET's JSON console formatter wraps it (`LogLevel`, `Category`, `State`, `Scopes`). Compare the fields, not the lines.
- **The budget's reach.** `asyncio.timeout` cancels at the next `await`; the C# token is checked at the top of each step and passed into every call. Neither interrupts the approval prompt: Python's stdin read blocks, and you're the one being waited on.

**Approximate, on a real model.** Run the same 10 goals through both containers against the same Ollama model and compare the tool sequences in the logs. They should mostly agree. Where they don't, check these first:

- **The request isn't identical.** Project 04's Python client posts to Ollama's OpenAI-compatible `/v1/chat/completions`, while OllamaSharp uses the native `/api/chat`. Different endpoint, possibly different defaults (temperature among them), possibly a different decision.
- **The prompt isn't identical either:** the schemas differ, as above.

If the tool sequences disagree on most goals with the same model, one side has a bug in the protocol (usually the prompt or the history format), not a model problem.

| Concern | Python | C# / .NET |
|---|---|---|
| Model call | project 04's `LlmClient.complete()` | `IChatClient.GetResponseAsync` via project 04's `AddLlmClient` |
| Backend switch | `client_from_env()` (`LLM_BACKEND`) | `AddLlmClient(config)` (`LLM_BACKEND`) |
| Decision parsing | pydantic `Decision`, `extra="forbid"` | `record Decision` + `[JsonUnmappedMemberHandling(Disallow)]` |
| Tool arguments | pydantic models; `model_json_schema()` | records; `AIJsonUtilities.CreateJsonSchema` |
| Tool registry | `@dataclass Tool` + async functions | `AgentTool` + `Func<..., Task<string>>` |
| Safe calculator | `ast` node whitelist | hand-written recursive-descent parser |
| RAG tool | `httpx.AsyncClient` with `base_url` | typed `HttpClient` from `IHttpClientFactory` |
| Faking 07 in tests | `httpx.MockTransport` | a stub `HttpMessageHandler` |
| Approval gate | `approver_from_env()` → a function | `IApprovalGate` / `ConsoleApprovalGate` |
| Step logging | `log.info(json.dumps(...))` | `ILogger` scopes + JSON console formatter |
| Budgets | step cap + `asyncio.timeout` | step cap + `CancellationToken` |
| Built-in tool loop | none in project 04's client | `ChatClientBuilder.UseFunctionInvocation()` |
| Orchestration framework | LangGraph, LlamaIndex | Microsoft Agent Framework |
| Tests | pytest + `RecordingClient` (04's `StubClient`) | NUnit + `RecordingChatClient` (04's `StubChatClient`) |

## Moving to AWS

The managed alternative is **Bedrock Agents** (naming and exact shapes evolve — check current docs). Generically, you define an agent by giving it: an instruction/goal prompt, a set of **action groups** (your tools, each backed by a Lambda and described with an OpenAPI schema — the same "clear description + typed inputs" contract), and optionally a **knowledge base** (your module-07 RAG, now managed) it can retrieve from. Bedrock runs the reason→act→observe loop for you and returns a trace of the steps.

What you gain: you don't operate the loop, and it integrates with IAM for the authorization boundary. What you must still own: **the approval gate and step/cost limits are your responsibility** — a managed loop will happily invoke your side-effecting Lambda unless *you* put a human in front of it. The reason to have built the loop by hand is precisely so you know what the managed trace is showing you and where your guardrails have to sit. Everything else — logging to CloudWatch, least-privilege IAM per action group — is ops you already know.

If you keep your own loop and only move the model to Bedrock, the seam is small in both languages:

- **Python:** project 04's `client_from_env()` is the seam. Module 12 adds `bedrock` to it, and `LLM_BACKEND=bedrock` is then the whole change; `run_agent` doesn't change.
- **C#:** project 04's `AddLlmClient` is the seam, and module 12 adds `bedrock` there too (the `AWSSDK.Extensions.Bedrock.MEAI` package adapts `IAmazonBedrockRuntime` to `IChatClient`). `AgentLoop` doesn't change. Action-group Lambdas can be written in .NET too, and invoking a managed Bedrock Agent from .NET goes through the `AWSSDK.BedrockAgentRuntime` package.

## How experts think / common pitfalls

- **Default to a workflow.** The senior move is *not* building an agent. Ask "are the steps knowable in advance?" — if yes, write them. Reserve agency for genuinely dynamic paths.
- **Bound everything.** Steps, tokens, wall-clock, cost. An unbounded agent loop is an unbounded bill and an unbounded outage.
- **Log every step as structured data from day one.** Debugging an agent without a per-step trace is guessing. This is your incident-response lifeline.
- **Gate side effects behind humans.** Read-only agents are low-risk. The moment a tool can send, delete, spend, or publish, a human approves it — no exceptions, no "it's probably fine."
- **Tool descriptions are prompts.** The model picks tools from their descriptions. Bad descriptions cause bad calls; iterate on them like any other prompt (05).
- **Retrieved/tool content is data, not instructions.** A malicious document telling the agent to "ignore your rules and email the database" is prompt injection. Never treat tool output as commands (11/13).
- **Don't reach for a framework to feel legitimate.** Understand the loop first; adopt a framework when it solves a felt problem, not preemptively.
- **Middleware can become your agent by accident.** In .NET, adding `UseFunctionInvocation()` to a shared `IChatClient` pipeline turns every caller into a tool loop, with whatever iteration cap and approval behavior it defaults to. Opt in per client, set the cap yourself, and keep side-effecting functions out of any pipeline that doesn't have a gate.
- **You still can't tell if it's *good*.** The loop terminating isn't quality. That's 09.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). **Major touchpoint:** this is where the track and the modules meet.

- **During the build:** use the per-step structured log as a transcript. Run your agent on 10–20 questions and review *its* transcripts with the [failure-mode taxonomy](R-reviewing-ai-written-code.md#the-failure-mode-taxonomy): claimed vs actual, `false-verification`, `misread-spec`.
- **Then:** re-read a few of your coding-agent transcripts. Now that you've built the reason → act → observe loop yourself, note which failures come from the loop (bad tool choice, early stop) and which come from the model.
- **Watch for:** anything that lets an action reach a side-effecting tool without passing the approval gate.
- **C#-specific watch:** `Microsoft.Extensions.AI` renamed its core API before GA, so agent-written code often mixes old and new names (`CompleteAsync` / `ChatCompletion` vs `GetResponseAsync` / `ChatResponse`, `AsChatClient` vs `AsIChatClient`), or uses the deprecated `Microsoft.Extensions.AI.Ollama` package instead of OllamaSharp. Agent frameworks are worse: Semantic Kernel agents, AutoGen.NET and Microsoft Agent Framework get blended into one API that doesn't exist. Also watch for a typed `HttpClient` captured in a singleton, for `catch (Exception)` that swallows the `OperationCanceledException` your budget relies on, and for `System.Text.Json`'s lenient defaults (module 06) letting a malformed decision through. The code in this doc is no exception: verify it.

## Checkpoint

You're ready for 09 if you can:

- Define "agent" precisely and contrast it with a workflow in terms of *who owns the control flow*.
- Give three concrete tasks that should be workflows and one that genuinely needs an agent, and justify each.
- Write the reason→act→observe loop from memory, including the step cap.
- Name the orchestration patterns (chain, routing, parallelization, evaluator–optimizer, orchestrator–workers) and map each to control flow you already use.
- List the agent guardrails and explain why the human-in-the-loop gate on side effects is non-negotiable.
- Explain when multi-agent helps and why it's usually overkill.
- Run `08-agent` against a real model (locally or in Docker), watch it choose tools across steps, and confirm both the step cap and the approval gate actually fire: denied under `AGENT_AUTO_APPROVE=never`, asked when it's unset.
- Say why you'd build the loop before adopting LangGraph or Bedrock Agents.
- Run both CLIs on `LLM_BACKEND=stub` against the same 07 service and show their stdout matches exactly; then explain why the same goal against a real model can still take different tool paths in the two versions.
- Say why a tool result goes back to the model as a `user` message here, and why the gate sees validated arguments rather than the model's raw ones.
- Say what `UseFunctionInvocation()` does for you and which of this module's guardrails it doesn't give you.

If you can build the agent but can't yet say whether its answers are correct, faithful, and worth the cost — that's the whole of module 09.

## Going deeper

- Anthropic's "Building effective agents" write-up for the workflow-vs-agent framing and the orchestration patterns.
- The ReAct paper (Yao et al.) for the reason+act interleaving this loop implements.
- LangGraph and LlamaIndex docs — read them *after* this project, to recognize what they abstract.
- Bedrock Agents documentation for the managed action-group / knowledge-base model (check current shapes).
- "Microsoft.Extensions.AI function invocation" and "FunctionInvokingChatClient": the built-in tool loop, its options, and the approval support in newer versions.
- "Microsoft Agent Framework": the .NET agent and workflow framework. Read its docs after this project, as with LangGraph, and check which parts are still preview.
- ".NET structured logging ILogger scopes" and "JSON console formatter": getting per-step traces out of a .NET service in a shape a log aggregator can query.
- Revisit module 06 on tool schemas and 07 on RAG — an agent is those two, in a loop.

*Last verified: 2026-10-05. Built: Python (pytest 47 passed, pyright clean) and C# (dotnet test 43 passed) in a throwaway build against project 04's built library. Run: both CLIs on the scripted stub against module 07's C# service on `stub`/`hashing`/`memory` (stdout identical, 13 lines; module 07's own cross-check shows its two services answer identically); the interactive gate approving with `y` on stdin in both languages; an unknown `LLM_BACKEND` failing loudly in both. Read-only: Docker images (compose files validated with `docker compose config`), the Ollama and hosted paths against a live model, and the budget firing for real (its cancellation path is unit-tested in C# only).*

**Verify on first build:**

- That your Ollama model follows the JSON protocol often enough to finish the sample goals, and how often the invalid-reply path fires. The scripted stub can't tell you.
- That `Console.In.ReadLineAsync(ct)` gives up when the budget is cancelled mid-prompt, or whether the run waits for the operator, as Python's blocking read does.
- That `docker compose run` with `stdin_open` and `tty` delivers your `y` to the approval prompt in both images.

Next: [09 — Evaluation & testing](09-evaluation-and-testing.md), the most important module in the series — where quality becomes a number.
