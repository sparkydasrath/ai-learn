# 06 — Structured outputs & tool calling

> **Background.** You're a senior/staff .NET engineer becoming an AI engineer. A model that returns free-form prose is a UI feature; a model that returns a **validated object** is a component you can build a system on. This module is about two tightly related moves: getting reliable, schema-conforming JSON *out* of a model (so downstream code can consume it like any DTO), and letting the model call *your* code (tool/function calling) so it can look things up and act. Both hinge on an instinct you already have hard-wired: **never trust input at a boundary.** A model's output is untrusted input. A model's request to call your function with some arguments is untrusted input. Validate and authorize accordingly. Provider APIs for structured output and tool calling differ in shape and are still evolving, so treat the specific mechanics here as illustrative patterns and confirm against current provider docs.

## Where this fits

**Prerequisites:** [01](01-python-for-dotnet-engineers.md), [03](03-llm-fundamentals-for-engineers.md), [04 — Calling models](04-calling-models-apis-sdks.md) (you'll use the `LlmClient`; tool calling shows up as a `finish_reason`), [05 — Prompts as engineering](05-prompt-engineering-as-engineering.md) (output format is part of the prompt contract).

**Outcomes:** after this you can specify a JSON schema for a model's output, validate it with pydantic, and repair/retry when it's wrong; and you can run a minimal tool-calling loop where the model asks to call typed functions, you validate the arguments, execute safe read-only tools, and feed results back. Both run offline on project 04's stub backend, so the whole pipeline is testable without a model. This is the direct on-ramp to agents in module 08. You'll also build both in C# on `Microsoft.Extensions.AI`, write the same two loops by hand, and then see which parts its built-in helpers (`GetResponseAsync<T>`, `UseFunctionInvocation`) take over and which parts stay your job.

## Why free text is hard to consume

Ask a model "extract the invoice total and due date" and it might reply "The total is $1,240.50, due on the 15th of next month." Now write the code that turns that into `decimal Total; DateOnly DueDate;`. You're parsing natural language — brittle regex, ambiguous dates, occasional prose like "no due date was specified." Every phrasing variation is a bug.

You already solved this problem class in .NET: you don't hand-parse a response body, you deserialize it into a typed model and let validation reject malformed data. We want the same here: the model emits **JSON that conforms to a schema**, and we deserialize it into a pydantic model. The prose problem disappears; the new problem is *making the model actually conform*, and *handling the times it doesn't*.

## Structured output: three levels of guarantee

Providers offer escalating guarantees that the output is valid JSON matching your schema. Know the ladder because support and names differ per provider and change over time:

1. **"Please emit JSON" in the prompt.** Weakest. You describe the shape (ideally with an example), and hope. Works surprisingly often, fails on edge cases (extra prose, trailing commas, markdown code fences around the JSON). Always pair with validation + retry.
2. **A JSON / "response format" mode.** Many providers have a flag that forces the output to be *syntactically* valid JSON (`response_format` / "JSON mode" or similar). It guarantees parseable JSON, not that it matches *your* schema — you still validate the fields.
3. **Schema-constrained decoding.** The strongest: you supply a JSON Schema and the provider constrains generation so the output *must* match it (sometimes called "structured outputs" or "guided decoding"; open-source servers do this with token-level grammars). When available and reliable, this largely eliminates shape errors — but availability, exact API, and which schema features are supported vary, so you still validate defensively.

**The durable pattern regardless of level:** define the schema once as a pydantic model, ask for JSON matching it, and validate the result. If validation fails, repair or retry. Don't bet your pipeline on any one provider's strongest mode being present — degrade gracefully down the ladder.

### .NET analogy

pydantic is your `System.ComponentModel.DataAnnotations` + `System.Text.Json` deserialization combined, but validation-first: a pydantic model is a class whose fields have types and constraints, and constructing it from untrusted data either yields a valid typed object or raises a `ValidationError` you can catch. It's the DTO-with-validation you'd put at an API boundary — which is exactly what a model boundary is.

## Validating with pydantic, and repairing/retrying

pydantic models generate a JSON Schema for you (so you can hand the schema to the provider) *and* validate incoming JSON against it. The loop:

1. Render a prompt asking for JSON matching the schema (include the schema or an example).
2. Call the model.
3. `Model.model_validate_json(text)` — success gives you a typed object; failure raises `ValidationError`.
4. On failure, **retry with the error fed back**: send the model its own bad output and the validation error, and ask it to fix it. Models are good at repairing their own JSON when told exactly what was wrong. Cap the attempts (2–3) so a persistently-broken case fails loudly instead of looping and burning tokens.

This "validate, and on failure retry with the error message" loop is the workhorse of reliable structured output. It's the same shape as your backoff loop from module 04, but the retry payload is a corrective message rather than a plain re-send.

## Tool / function calling mechanics

Structured output lets the model give you data in a known shape. **Tool calling** lets the model ask you to *run code* — the model, mid-generation, emits a structured request "call `lookup_customer` with `{"id": "C-42"}`" instead of finishing with text. The flow:

1. **You declare tools.** For each, a name, a description (the model reads this to decide when to use it), and a **parameters schema** (again JSON Schema, again generated from a pydantic model). This is the tool's "signature."
2. **You send the tools with the request.** The model may respond normally, or with `finish_reason == "tool_calls"` and one or more requested calls (name + JSON arguments).
3. **You execute.** Parse and **validate the arguments** into the pydantic model, decide whether the call is *allowed*, run the real function, capture the result.
4. **You feed the result back** as a `tool` role message and call the model again. It incorporates the result and either finishes with text or asks for another tool.
5. **Loop** until it finishes (or you hit a step cap — always have one).

That's **native** tool calling: the provider's API carries the tools and the calls as structured fields. There's a second way to get the same loop, the **prompt protocol**: you list the tools and their argument schemas in the system prompt, and tell the model to reply with one JSON object, either `{"tool": "<name>", "arguments": {...}}` or `{"answer": "..."}`. You parse that reply like any other structured output, and send results back as an ordinary message.

- **Native** is more reliable with models trained for it, supports parallel calls, and is what production code should prefer when the provider has it.
- **The protocol** works with any chat model and any backend, including an offline stub, and makes every step visible. It's also how agent loops were built before native support was common, and module 08's agent uses it.

Both have the same safety boundary: whatever the transport, the model's request gets validated and authorized before anything runs. The build project uses the protocol in both languages and shows the native version in C#; it explains why below.

### .NET analogy

This is **reflection + RPC**. You expose a set of methods with typed signatures (the tool schemas ≈ reflection metadata / a service contract). A remote caller (the model) picks a method by name and sends serialized arguments (≈ an RPC request). You deserialize, validate, dispatch, and return a serialized result. The critical difference from your normal RPC: **the caller is untrusted and occasionally wrong or adversarial** — it can request a method with garbage arguments, or (via prompt injection) be tricked into requesting something harmful. So this is RPC where you treat every incoming call like a request from the public internet.

## Designing good tool schemas

The model chooses tools based entirely on their **names, descriptions, and parameter schemas** — that text is prompt, and the same engineering from module 05 applies:

- **Name and describe tools for the model, not for you.** `get_order_status(order_id)` with "Returns shipping status for a customer order given its ID" beats `svc_qry(x)`. The description is how the model knows *when* to call it.
- **Make parameters typed and tight.** Enums over free strings, required vs optional made explicit, ranges where they apply. A tight schema means fewer invalid calls and less validation fallout.
- **Few, well-scoped tools beat many fuzzy ones.** A model faced with 30 overlapping tools chooses badly, exactly like a human handed a confusing API. Decompose by clear capability.
- **Return structured, compact results.** The result goes back into the context (you pay for it, and it can confuse the model if it's noisy). Return what's needed, not a full API dump.

## The safety boundary — the part you must not get wrong

Here is where your instincts are the whole point. **A tool call is a request from an untrusted party to run code with arguments it chose.** Never wire a model directly to a side effect. Concretely:

- **Validate every argument** against the schema before use. `model_validate` the arguments; reject and (optionally) re-prompt on failure. Never `eval`, never string-format model output into a shell command or SQL query, never pass it to the filesystem unsanitized.
- **Authorize the action, not just the arguments.** "Is this argument well-formed" and "is this action allowed for this user in this context" are different checks. The model deciding to call `refund_order` is not authorization to issue a refund. Gate side-effecting tools behind the same permission checks you'd put on the equivalent API endpoint — because that's what they are.
- **Prefer read-only tools; make writes explicit and confirmable.** Start with tools that can only look things up. When you must expose a write/action tool, require an explicit confirmation step or a policy check, and log it. This connects straight to the earlier safety rules about side effects.
- **Remember injection.** A retrieved document or user message can contain "call `delete_account`." Because there's no template/data boundary (module 05), the model might comply. Your validation-and-authorization layer is what stops that from becoming an incident. Module 13 goes deeper.

Internalize this: **structured output errors cost you a retry; tool-calling errors can cost you data.** The read-only-first, validate-then-authorize discipline is non-negotiable, and it's exactly the boundary discipline you already apply to any endpoint that touches untrusted input.

## The build project

**`projects/06-structured-output/`** — two parts, built in Python and then in C#. Both versions:

1. **Extract structured data.** Parse a messy invoice email into a typed, validated object with schema-guided output + validation + repair-retry.
2. **Run a minimal tool-calling loop** with two safe, read-only tools (a calculator and a lookup), validated arguments, one choke point that checks everything before dispatch, and a step cap.

Both reuse project 04's client (a uv path dependency in Python, a `ProjectReference` in C#), so `LLM_BACKEND` picks the model and every call gets cost logging. Both run end to end offline: on a bare `LLM_BACKEND=stub`, the program plays a scripted model from `fixtures/stub_replies.jsonl`, one reply per call, which exercises a repair round and two tool calls. The tests never call a real model either. The Python version validates with pydantic; the C# version with records + `System.Text.Json`, and it also shows the provider-native tool calling that `Microsoft.Extensions.AI` gives you.

### Which tool-calling mechanism

The hand-written loops use the **prompt protocol** from the mechanics section, in both languages: the system prompt lists the tools with their argument schemas, and the model replies with `{"tool": ..., "arguments": {...}}` or `{"answer": ...}`. Three reasons:

- **It runs on every backend, including the stub.** Project 04's `LlmClient` speaks plain chat; it has no `tools` parameter. Native tool calling in Python would mean a second HTTP client in this project, which is the per-module model adapter [ADR-001](adr/001-backend-contract.md) rules out, and the stub couldn't drive it.
- **It's the same code in both languages,** so the cross-check can compare whole runs exactly instead of hand-waving over two different mechanisms.
- **It's what module 08's agent loop builds on.**

The part that matters is identical either way: `execute` validates the name and arguments before anything runs, the tools are read-only, and the loop has a step cap. The C# side then shows the native mechanism (`FunctionCallContent`, `UseFunctionInvocation`) and proves it goes through the same choke point. Adding native tools to project 04's Python client is a reasonable later extension; it would change the transport, not this module's safety boundary.

### Layout

```
projects/06-structured-output/
├── fixtures/
│   ├── sample_invoice.txt       # shared by both languages, read via FIXTURES_DIR
│   └── stub_replies.jsonl       # the scripted "model" for LLM_BACKEND=stub, one reply per line
├── python/
│   ├── pyproject.toml           # from the scaffold + uv add: path dependency on 04
│   ├── uv.lock                  # committed: pins exact dependency versions
│   ├── Dockerfile               # build context is projects/, to reach project 04
│   ├── Dockerfile.dockerignore  # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example             # committed; copy to .env (git-ignored)
│   ├── README.md
│   ├── run.py                   # extract the sample invoice, then a tool query
│   ├── src/structured_output/
│   │   ├── __init__.py
│   │   ├── extract.py           # invoice extraction + validate/repair loop
│   │   ├── tools.py             # tool registry, schemas, the execute choke point
│   │   └── loop.py              # the tool-calling loop with a step cap
│   └── tests/
│       ├── fakes.py             # project 04's stub, plus a record of each call
│       ├── test_extract.py
│       ├── test_tools.py
│       ├── test_loop.py
│       └── test_run.py          # run.py end to end on the stub
└── csharp/
    ├── StructuredOutput.slnx
    ├── Directory.Build.props        # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                   # build context is projects/, to reach project 04
    ├── Dockerfile.dockerignore      # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   └── StructuredOutput/
    │       ├── StructuredOutput.csproj  # ProjectReference to project 04's LlmClient library
    │       ├── Contracts.cs         # shared JSON rules, IValidatable, Parse/Bind
    │       ├── Invoice.cs           # the invoice contract: records, schema
    │       ├── InvoiceExtractor.cs  # validate/repair loop
    │       ├── Tools.cs             # tool registry, arg records, the Execute choke point
    │       ├── ToolLoop.cs          # the tool-calling loop with a step cap
    │       └── Program.cs
    └── tests/
        └── StructuredOutput.Tests/
            ├── StructuredOutput.Tests.csproj    # NUnit
            ├── FakeChatClient.cs
            ├── InvoiceTests.cs
            ├── InvoiceExtractorTests.cs
            ├── ToolsTests.cs
            └── ToolLoopTests.cs
```

### The fixtures

`fixtures/sample_invoice.txt`, the messy input:

```text
From: Acme Supplies Ltd <billing@acme.example>
Subject: Invoice INV-2026-0042

Hi team,

Please find attached invoice INV-2026-0042 for last month's order:

  3 x USB-C dock          @ 19.99
  1 x Monitor arm         @ 45.50

Total due: 105.47 USD. Payment is due by 15 November 2026.

Thanks,
Dana (Accounts, Acme)
```

`fixtures/stub_replies.jsonl`, what the stub "model" says, in order: an invoice missing its vendor (so the repair loop runs once), the corrected invoice, two tool calls, and the final answer.

```jsonl
{"invoice_number": "INV-2026-0042", "total": 105.47}
{"invoice_number": "INV-2026-0042", "vendor": "Acme Supplies Ltd", "total": 105.47, "due_date": "2026-11-15", "line_items": [{"description": "USB-C dock", "quantity": 3, "unit_price": 19.99}, {"description": "Monitor arm", "quantity": 1, "unit_price": 45.5}]}
{"tool": "lookup_order", "arguments": {"order_id": "C-42"}}
{"tool": "calculator", "arguments": {"op": "mul", "a": 19.99, "b": 3}}
{"answer": "Order C-42 has shipped and should arrive in 2 days. 19.99 * 3 = 59.97."}
```

## Python implementation

Work in `projects/06-structured-output/python/`. Like module 05, it's a [library](conventions.md#python-project-shapes) that reuses project 04's client as a path dependency. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 06-structured-output
cd projects/06-structured-output/python
uv add pydantic
uv add --editable ../../04-llm-client/python
uv add --dev pytest-asyncio
```

The script names the package `structured-output`, so the import name is `structured_output`. As in module 04, empty the generated `__init__.py`, remove the `[project.scripts]` table, and delete `tests/test_smoke.py` once the real tests exist. This doc was built against pydantic 2.13.

### Part 1 — schema-guided extraction with validate + repair

```python
# src/structured_output/extract.py
from __future__ import annotations

import json
import logging
from datetime import date

from llm_client.types import LlmClient, Message   # project 04's client, a path dependency
from pydantic import BaseModel, Field, ValidationError

log = logging.getLogger(__name__)


class LineItem(BaseModel):
    description: str
    quantity: int = Field(ge=1)
    unit_price: float = Field(ge=0)


class Invoice(BaseModel):
    """The typed contract we want out of messy text. pydantic gives us
    both the JSON Schema to send AND validation of what comes back."""
    invoice_number: str
    vendor: str
    total: float = Field(ge=0)
    due_date: date | None = None          # allow "unknown"
    line_items: list[LineItem] = []       # pydantic copies mutable defaults; no shared-list bug


EXTRACT_SYSTEM = (
    "You extract invoice fields and return ONLY JSON matching the schema. "
    "No prose, no markdown fences. If a field is unknown, use null (or omit "
    "optional fields). Do not invent values."
)


def _prompt(raw_text: str) -> str:
    schema = json.dumps(Invoice.model_json_schema(), indent=2)
    return f"JSON Schema:\n{schema}\n\nInvoice text:\n{raw_text}\n\nJSON:"


async def extract_invoice(client: LlmClient, raw_text: str, *, max_attempts: int = 3) -> Invoice:
    messages = [
        Message("system", EXTRACT_SYSTEM),
        Message("user", _prompt(raw_text)),
    ]
    last_error = ""
    for attempt in range(1, max_attempts + 1):
        completion = await client.complete(messages, max_tokens=512)
        try:
            return Invoice.model_validate_json(strip_fences(completion.text))
        except ValidationError as e:   # bad JSON and bad fields both land here
            last_error = describe(e)
            log.warning("extraction attempt %d/%d failed validation: %s", attempt, max_attempts, last_error)
            # Repair: hand the model its bad output + the exact error.
            messages += [
                Message("assistant", completion.text),
                Message("user", f"That did not validate. Errors:\n{last_error}\nReturn corrected JSON only."),
            ]
    raise ValueError(f"could not extract valid invoice after {max_attempts} attempts: {last_error}")


def describe(e: ValidationError) -> str:
    """One line per problem, e.g. "vendor: Field required". str(e) also echoes the input
    and a docs URL per error: tokens the model doesn't need in a repair prompt."""
    return "\n".join(
        f"{'.'.join(map(str, err['loc'])) or '(root)'}: {err['msg']}" for err in e.errors(include_url=False)
    )


def strip_fences(text: str) -> str:
    """Tolerate ```json ... ``` wrapping, which models add even when told not to."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("```")[1]
        t = t.removeprefix("json").strip()
    return t
```

> **Pythonism flag.** pydantic `BaseModel` is the idiomatic validated-DTO in modern Python (it powers FastAPI). `Field(ge=1)` attaches constraints (`>= 1`); `model_validate_json` parses-and-validates in one step and raises `ValidationError` with a precise, field-level message — which is exactly what we feed back for repair. `due_date: date | None = None` models "optional/unknown" without a sentinel. `model_json_schema()` emits the JSON Schema you hand to the provider.

`describe` matters more than it looks. `str(ValidationError)` echoes the bad input and adds a documentation URL per error. The model needs neither, and you pay for every token of the repair prompt.

### Part 2 — a minimal, safe tool-calling loop

```python
# src/structured_output/tools.py
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Literal

from pydantic import BaseModel, Field, ValidationError


class CalcArgs(BaseModel):
    # Deliberately NOT "expression: str" that we eval — that would be an
    # injection hole. Structured, bounded operations only.
    op: Literal["add", "sub", "mul", "div"]   # the schema lists the four values, like C#'s enum
    a: float
    b: float


class LookupArgs(BaseModel):
    order_id: str = Field(pattern=r"^C-[0-9]{1,6}$", description="Order id like 'C-42'.")


# Fake read-only datastore. Real tools would hit a DB/service behind auth.
_ORDERS = {"C-42": {"status": "shipped", "eta": "2 days"}}


def calculator(args: CalcArgs) -> dict[str, Any]:
    result = {
        "add": args.a + args.b,
        "sub": args.a - args.b,
        "mul": args.a * args.b,
        "div": args.a / args.b if args.b else None,
    }[args.op]
    return {"result": result}


def lookup_order(args: LookupArgs) -> dict[str, Any]:
    return _ORDERS.get(args.order_id, {"status": "not_found"})


@dataclass(frozen=True)
class Tool:
    """A plain dataclass: the tool's metadata needs no validating, only its arguments do."""
    name: str
    description: str
    args_model: type[BaseModel]
    fn: Callable[[Any], dict[str, Any]]   # takes an instance of args_model


REGISTRY: dict[str, Tool] = {
    t.name: t
    for t in [
        Tool("calculator", "Do one arithmetic operation. op is add|sub|mul|div.", CalcArgs, calculator),
        Tool("lookup_order", "Look up a customer order's status by id like 'C-42'.", LookupArgs, lookup_order),
    ]
}


def execute(name: str, raw_args: dict[str, Any]) -> dict[str, Any]:
    """The safety choke point. Validate name and args BEFORE running."""
    tool = REGISTRY.get(name)
    if tool is None:
        return {"error": f"unknown tool '{name}'"}       # never dispatch by faith
    try:
        args = tool.args_model.model_validate(raw_args)  # untrusted -> typed
    except ValidationError as e:
        return {"error": f"invalid arguments: {e}"}
    # Both tools here are read-only; a WRITE tool would require an
    # authorization check and/or human confirmation right here before fn().
    return tool.fn(args)
```

`Tool` is a plain dataclass rather than a pydantic model: nothing about the tool's own metadata needs validating, only the arguments the model sends. (A pydantic model holding a class and a function would need `model_config = ConfigDict(arbitrary_types_allowed=True)`; the pydantic v1 spelling, an inner `class Config`, is a deprecation warning in v2.) `op` is a `Literal`, so the schema the model sees lists the four allowed values.

```python
# src/structured_output/loop.py
from __future__ import annotations

import json
import logging
from typing import Any

from llm_client.types import LlmClient, Message
from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from .extract import describe, strip_fences
from .tools import REGISTRY, execute

log = logging.getLogger(__name__)

REPLY_FORMAT = (
    'Reply with ONE JSON object and nothing else: {"tool": "<name>", "arguments": {...}} '
    'to call a tool, or {"answer": "<text>"} when you can answer.'
)


def system_prompt() -> str:
    """What we advertise to the model: names, descriptions, argument schemas, and the reply format."""
    tools = "\n".join(
        f"- {t.name}: {t.description} Arguments (JSON Schema): {json.dumps(t.args_model.model_json_schema())}"
        for t in REGISTRY.values()
    )
    return f"You can call these tools:\n{tools}\n{REPLY_FORMAT}"


class Decision(BaseModel):
    """One model turn: call a tool, or answer. Untrusted input, so it's validated like any other."""
    model_config = ConfigDict(extra="forbid")   # an unexpected key is an error, not ignored

    tool: str | None = None
    arguments: dict[str, Any] = {}
    answer: str | None = None

    @model_validator(mode="after")
    def _exactly_one(self) -> Decision:
        if (self.tool is None) == (self.answer is None):
            raise ValueError("set exactly one of 'tool' or 'answer'")
        return self


async def run_with_tools(client: LlmClient, user_msg: str, *, max_steps: int = 5) -> str:
    """Loop: model may ask for tools; we validate+run and feed results back.
    ALWAYS bounded by max_steps so a confused model can't loop forever."""
    messages = [Message("system", system_prompt()), Message("user", user_msg)]
    for _ in range(max_steps):
        completion = await client.complete(messages, max_tokens=512)
        messages.append(Message("assistant", completion.text))
        try:
            decision = Decision.model_validate_json(strip_fences(completion.text))
        except ValidationError as e:
            # A malformed turn costs a step; the model gets told exactly what was wrong.
            messages.append(Message("user", f"That was not a valid reply: {describe(e)}\n{REPLY_FORMAT}"))
            continue
        if decision.answer is not None:
            return decision.answer                      # model is done
        assert decision.tool is not None                # the validator guarantees it
        result = json.dumps(execute(decision.tool, decision.arguments), separators=(",", ":"))  # compact, like C#
        log.info("tool %s -> %s", decision.tool, result)
        # A "user" message, not "tool": OpenAI-style APIs only accept a tool role in answer to a native call.
        messages.append(Message("user", f"Result of {decision.tool}: {result}"))
    return "stopped: hit max tool steps"
```

Three details carry the weight:

- **The model's reply is validated like any other untrusted input.** `Decision` forbids unknown keys and requires exactly one of `tool` or `answer`. A malformed turn goes back to the model with the error and costs a step, so a model that never gets it right still hits the cap.
- **Results go back as JSON, not a Python repr.** `str({"result": None})` is `{'result': None}`, which isn't JSON, and the model then has to guess. `json.dumps` with compact separators produces the same text `System.Text.Json` does.
- **The result is a `user` message.** OpenAI-style APIs only accept the `tool` role in answer to a native tool call, with its `tool_call_id`. In the prompt protocol there's no call id, so a `tool` message would be rejected by a real provider.

### `run.py`

```python
# run.py
"""Extract the sample invoice, then answer a question with tools.
Usage: python run.py [path/to/invoice.txt]"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path

from llm_client.factory import client_from_env
from llm_client.stub import StubClient
from llm_client.types import LlmClient
from structured_output.extract import extract_invoice
from structured_output.loop import run_with_tools

# Shared with the C# side. Relative to python/, where you run from; the Dockerfile sets it.
FIXTURES_DIR = Path(os.environ.get("FIXTURES_DIR", "../fixtures"))
QUESTION = "What's the status of order C-42, and what is 19.99 * 3?"


def make_client() -> LlmClient:
    """Project 04 picks the backend. On a bare stub, play the scripted model in
    fixtures/stub_replies.jsonl (one reply per line), so the whole run works offline."""
    if os.environ.get("LLM_BACKEND") == "stub" and not os.environ.get("LLM_STUB_REPLY"):
        lines = (FIXTURES_DIR / "stub_replies.jsonl").read_text(encoding="utf-8").splitlines()
        return StubClient([line for line in lines if line.strip()])
    return client_from_env()


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")  # stderr
    client = make_client()

    # Part 1: schema-guided extraction with validate + repair.
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURES_DIR / "sample_invoice.txt"
    invoice = await extract_invoice(client, path.read_text(encoding="utf-8"))
    print(invoice.model_dump_json(indent=2))

    # Part 2: the tool-calling loop.
    print(await run_with_tools(client, QUESTION))


if __name__ == "__main__":
    asyncio.run(main())
```

`make_client` only special-cases one thing: a bare stub. With `LLM_STUB_REPLY` set, or any other backend, project 04's factory decides as usual.

### Configuration

```bash
# projects/06-structured-output/python/.env.example
# Copy to .env (git-ignored). compose reads it; a bare `uv run` doesn't, so set variables in your shell there.
# The model variables are project 04's: docs/conventions.md#environment-variables

# stub | ollama | hosted. A bare stub plays fixtures/stub_replies.jsonl.
LLM_BACKEND=ollama
OLLAMA_MODEL=llama3.2

# hosted: any OpenAI-compatible API. LLM_BASE_URL includes /v1.
LLM_BASE_URL=https://api.openai.com/v1
LLM_API_KEY=
LLM_MODEL=
Rates__InputPerMTok=0
Rates__OutputPerMTok=0

# Optional. The default works from python/, and the Dockerfile sets it.
# FIXTURES_DIR=../fixtures
```

### Tests

Tests fake the *model* only: `RecordingClient` is project 04's `StubClient` replaying scripted replies, plus a record of what each call was sent. The registry, the validation and both loops are the real code, so the tests don't fall into `mock-the-subject`. They mirror the C# tests case for case.

```python
# tests/fakes.py
from collections.abc import AsyncIterator, Sequence

from llm_client.stub import StubClient
from llm_client.types import Completion, Message


class RecordingClient:
    """Project 04's StubClient replaying `replies` in order, plus a record of what each
    call was sent. Only the model is fake: the loops under test are the real code."""

    def __init__(self, *replies: str):
        self._stub = StubClient(replies)
        self.calls: list[list[Message]] = []

    async def complete(self, messages: Sequence[Message], *, max_tokens: int = 512) -> Completion:
        self.calls.append(list(messages))   # a snapshot: the loops keep appending to their list
        return await self._stub.complete(messages, max_tokens=max_tokens)

    def stream(self, messages: Sequence[Message], *, max_tokens: int = 512) -> AsyncIterator[str]:
        return self._stub.stream(messages, max_tokens=max_tokens)
```

```python
# tests/test_extract.py
import pytest
from fakes import RecordingClient
from pydantic import ValidationError

from structured_output.extract import Invoice, extract_invoice


def test_valid_invoice_parses_with_defaults():
    ok = Invoice.model_validate_json('{"invoice_number":"INV-1","vendor":"Acme","total":10.0}')
    assert ok.due_date is None and ok.total == 10.0 and ok.line_items == []


# The verdict table. InvoiceTests.cs runs the same JSON, and every verdict must agree.
@pytest.mark.parametrize(
    ("json_text", "valid"),
    [
        ('{"invoice_number":"INV-1","vendor":"Acme","total":5}', True),
        ('{"invoice_number":"INV-1","vendor":"Acme","total":"5"}', True),      # lax: numeric string -> number
        ('{"invoice_number":"INV-1","total":5}', False),                        # missing vendor
        ('{"invoice_number":"INV-1","vendor":null,"total":5}', False),          # null for a required string
        ('{"invoice_number":"INV-1","Vendor":"Acme","total":5}', False),        # names are case-sensitive
        ('{"invoice_number":"INV-1","vendor":"Acme","total":-5}', False),       # total < 0
        ('{"invoice_number":"INV-1","vendor":"Acme","total":5,"line_items":null}', False),
        ('{"invoice_number":"INV-1","vendor":"Acme","total":5,'
         '"line_items":[{"description":"x","quantity":0,"unit_price":1}]}', False),   # quantity < 1
        ('{"invoice_number":"INV-1","vendor":"Acme","total":5,"due_date":"15/11/2026"}', False),
        ("not json", False),
    ],
)
def test_invoice_verdicts(json_text, valid):
    if valid:
        Invoice.model_validate_json(json_text)
    else:
        with pytest.raises(ValidationError):
            Invoice.model_validate_json(json_text)


GOOD = '{"invoice_number":"INV-1","vendor":"Acme","total":12.5}'


@pytest.mark.asyncio
async def test_repairs_after_one_bad_reply():
    client = RecordingClient(
        '{"invoice_number":"INV-1","total":12.5}',          # missing vendor
        f"```json\n{GOOD}\n```",                            # fenced, but valid
    )
    invoice = await extract_invoice(client, "raw invoice text")

    assert invoice.vendor == "Acme"
    assert len(client.calls) == 2
    # The retry carried the validation error back to the model.
    assert "did not validate" in client.calls[1][-1].content
    assert "vendor" in client.calls[1][-1].content


@pytest.mark.asyncio
async def test_gives_up_after_max_attempts():
    client = RecordingClient("not json")
    with pytest.raises(ValueError, match="after 3 attempts"):
        await extract_invoice(client, "raw", max_attempts=3)
    assert len(client.calls) == 3
```

```python
# tests/test_tools.py
import pytest

from structured_output.tools import execute


def test_valid_calculator_call():
    assert execute("calculator", {"op": "add", "a": 2, "b": 3}) == {"result": 5}


def test_divide_by_zero_is_null_not_a_crash():
    assert execute("calculator", {"op": "div", "a": 1, "b": 0}) == {"result": None}


def test_rejects_unknown_tool():
    out = execute("rm_rf", {"path": "/"})
    assert "unknown tool" in out["error"]        # never dispatched


# The same bad arguments ToolsTests.cs rejects.
@pytest.mark.parametrize(
    ("tool", "args"),
    [
        ("lookup_order", {"order_id": "'; DROP TABLE orders; --"}),
        ("lookup_order", {"order_id": "C-42\n"}),   # a trailing newline must not sneak past the anchor
        ("calculator", {"op": "pow", "a": 1, "b": 1}),
        ("calculator", {"op": 2, "a": 1, "b": 1}),   # an int is not one of the names
        ("calculator", {"op": "add", "a": 1}),       # missing b must not become 0
    ],
)
def test_rejects_bad_args(tool, args):
    assert execute(tool, args)["error"].startswith("invalid arguments")


@pytest.mark.parametrize(("order_id", "status"), [("C-42", "shipped"), ("C-99", "not_found")])
def test_lookup_hit_and_miss(order_id, status):
    assert execute("lookup_order", {"order_id": order_id})["status"] == status
```

```python
# tests/test_loop.py
import pytest
from fakes import RecordingClient

from structured_output.loop import run_with_tools


@pytest.mark.asyncio
async def test_runs_tool_then_returns_final_text():
    client = RecordingClient(
        '{"tool": "lookup_order", "arguments": {"order_id": "C-42"}}',
        '{"answer": "Order C-42 has shipped."}',
    )
    answer = await run_with_tools(client, "Where is C-42?")

    assert answer == "Order C-42 has shipped."
    # The second call carried the real tool result back to the model.
    assert client.calls[1][-1].content == 'Result of lookup_order: {"status":"shipped","eta":"2 days"}'


@pytest.mark.asyncio
async def test_bad_arguments_go_back_to_the_model_not_into_the_tool():
    client = RecordingClient(
        '{"tool": "lookup_order", "arguments": {"order_id": "C-42; DROP TABLE orders"}}',
        '{"answer": "Sorry, that is not a valid order id."}',
    )
    await run_with_tools(client, "Where is C-42; DROP TABLE orders?")
    assert client.calls[1][-1].content.startswith('Result of lookup_order: {"error":"invalid arguments')


@pytest.mark.asyncio
async def test_invalid_reply_is_fed_back():
    client = RecordingClient('{"tool": "calculator", "answer": "both?"}', '{"answer": "ok"}')
    assert await run_with_tools(client, "hi") == "ok"
    assert "not a valid reply" in client.calls[1][-1].content


@pytest.mark.asyncio
async def test_stops_at_step_cap():
    client = RecordingClient('{"tool": "calculator", "arguments": {"op": "add", "a": 1, "b": 1}}')  # forever
    assert await run_with_tools(client, "loop forever", max_steps=5) == "stopped: hit max tool steps"
    assert len(client.calls) == 5
```

`test_run.py` is ADR-002 as a test: the documented command, run as a subprocess on the stub, must work end to end.

```python
# tests/test_run.py
import os
import subprocess
import sys
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1]


def test_run_py_works_end_to_end_on_the_stub():
    """ADR-002: the documented command runs offline. On a bare stub, run.py plays fixtures/stub_replies.jsonl."""
    env = {**os.environ, "LLM_BACKEND": "stub"}
    env.pop("LLM_STUB_REPLY", None)
    out = subprocess.run(
        [sys.executable, "run.py"], cwd=PYTHON_DIR, env=env, capture_output=True, text=True, check=True
    ).stdout

    assert '"vendor": "Acme Supplies Ltd"' in out    # extracted, after one repair round
    assert out.rstrip().endswith("19.99 * 3 = 59.97.")   # the tool loop's final answer
```

`from fakes import RecordingClient` works because pytest puts each test file's folder on `sys.path` (its default `prepend` import mode), so a helper module next to the tests needs no package.

Run locally:

```powershell
uv run pytest
$env:LLM_BACKEND = 'stub'; uv run python run.py     # offline: the scripted model
$env:LLM_BACKEND = 'ollama'; uv run python run.py   # needs Ollama on localhost:11434
uv run python run.py path/to/other_invoice.txt
```

### Running the Python version in Docker

The image needs project 04 as well as `fixtures/`, so, as in module 05, the build context is `projects/` and the image keeps the repo layout. The `../../04-llm-client/python` path dependency resolves unchanged, and the Dockerfile sets `FIXTURES_DIR` explicitly. The scaffold's `Dockerfile.dockerignore` keeps every venv and `bin/` folder in the repo out of that wide context.

```dockerfile
# projects/06-structured-output/python/Dockerfile — build context: projects/
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
# Project 04 first: the path dependency must exist before uv can install anything.
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 06-structured-output/python/pyproject.toml 06-structured-output/python/uv.lock 06-structured-output/python/README.md 06-structured-output/python/
WORKDIR /src/06-structured-output/python
# Library pattern: dependencies (04 included, via [tool.uv.sources]), then code, then the project.
RUN uv sync --frozen --no-install-project
COPY 06-structured-output/python/ ./
COPY 06-structured-output/fixtures/ /src/06-structured-output/fixtures/
RUN uv sync --frozen          # installs structured_output plus the dev group (pytest) by default
ENV PATH="/src/06-structured-output/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/06-structured-output/fixtures
CMD ["python", "run.py"]
```

```yaml
# projects/06-structured-output/python/compose.yaml
name: structured-output-py   # otherwise the project is named after the folder: "python"
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: { context: ../.., dockerfile: 06-structured-output/python/Dockerfile }   # projects/: 04 and fixtures/ must be inside
    env_file:
      - path: .env             # hosted keys, rates and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

```powershell
cd projects/06-structured-output/python
docker compose run --rm --no-deps app pytest -q                 # no network
docker compose run --rm --no-deps -e LLM_BACKEND=stub app       # offline: the scripted model
docker compose --profile ollama up -d ollama   # skip if Ollama runs natively
docker compose exec ollama ollama pull llama3.2   # native: ollama pull llama3.2
docker compose run --rm app                                     # extract the sample invoice, then a tool query
# Without compose, from the repo root:
# docker build -f projects/06-structured-output/python/Dockerfile -t structured-output-py projects
```

> Note: not every small local model reliably follows JSON schemas or the tool protocol. If extraction flaps locally, that's a real lesson — it's why the repair-retry loop exists, and why you'll *evaluate* structured-output reliability (module 09) rather than assume it. A stronger hosted model behind the same `LlmClient` interface (module 04) usually behaves better.

## C# implementation

Work in `projects/06-structured-output/csharp/`. Same two parts, same fixtures, same tools, same protocol, same output. What's different:

- **No pydantic.** .NET splits pydantic's job across pieces you already know. A **record** is the shape. **`System.Text.Json`** parses it and enforces the type-level rules: required members, nullability, enums. A hand-written **`Validate()`** enforces the value rules pydantic writes as `Field(ge=0)`. The schema comes from **`AIJsonUtilities.CreateJsonSchema`** in `Microsoft.Extensions.AI`. It's more moving parts, and you get to see every one.
- **`System.Text.Json` is lenient by default.** A missing `vendor` silently becomes `null`, a missing number becomes `0`, an enum accepts `2` as well as `"mul"`, and the Web defaults match `"Vendor"` to `vendor`. pydantic rejects all four. You have to opt in to strictness: C# `required` members, `RespectNullableAnnotations`, `RespectRequiredConstructorParameters`, `allowIntegerValues: false` on the enum converter, and `PropertyNameCaseInsensitive = false`. Get one wrong and a bad model output passes validation quietly.
- **Native tool calls are typed content.** `Microsoft.Extensions.AI` normalizes provider tool calling: tools go in `ChatOptions.Tools`, a requested call arrives as `FunctionCallContent` (call id, name, arguments), and you reply with `FunctionResultContent` carrying the same call id. The hand-written loop uses the prompt protocol, as in Python; the native version runs as middleware, and a test shows it still goes through `Execute`.
- **The library can run both loops for you.** `GetResponseAsync<T>` does structured output, and `UseFunctionInvocation()` runs the native tool loop. You write both loops by hand first, so you know exactly what those helpers do and don't do.

### Scaffold

From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 06-structured-output
cd projects/06-structured-output/csharp
Remove-Item tests/StructuredOutput.Tests/SmokeTests.cs
dotnet add src/StructuredOutput reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add src/StructuredOutput package Microsoft.Extensions.Hosting
```

`Microsoft.Extensions.AI` (the abstractions, `AIFunction`, the content types, the middleware and `AIJsonUtilities`) comes through the reference to project 04, as do the backends behind `AddLlmClient`. This doc was built against Microsoft.Extensions.AI 10.10.

### `src/StructuredOutput/Contracts.cs`

One set of JSON rules for every model boundary in the project: snake_case names to match the Python side and the prompts, strict about missing, null and differently-cased values, and one `Parse` that turns any failure into a `ContractValidationException`, the twin of pydantic's `ValidationError`.

```csharp
// src/StructuredOutput/Contracts.cs
using System.Text.Json;
using System.Text.Json.Serialization;

namespace StructuredOutput;

/// <summary>Value rules the type system can't express (pydantic's Field(ge=...)). Empty list = valid.</summary>
public interface IValidatable
{
    IReadOnlyList<string> Validate();
}

/// <summary>Untrusted JSON didn't fit the contract: the twin of pydantic's ValidationError.</summary>
public sealed class ContractValidationException(IReadOnlyList<string> errors)
    : Exception(string.Join("\n", errors))
{
    public IReadOnlyList<string> Errors { get; } = errors;
}

public static class ContractJson
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        // Web defaults match names case-insensitively; pydantic doesn't, so "Vendor" mustn't count as "vendor".
        PropertyNameCaseInsensitive = false,
        // "vendor": null for a non-nullable string is an error, not a null you trip over later.
        RespectNullableAnnotations = true,
        // A missing positional-record argument is an error, not a silent default(0).
        RespectRequiredConstructorParameters = true,
        // Enums as "add"/"mul" only. By default the converter also accepts integers.
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower, allowIntegerValues: false) },
        // Already the Web default; spelled out because it's a choice: pydantic's lax mode reads "5" as 5 too.
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    /// <summary>The model_validate_json twin: untrusted JSON in, a valid T or ContractValidationException out.</summary>
    public static T Parse<T>(string json) where T : class, IValidatable
    {
        T? value;
        try
        {
            value = JsonSerializer.Deserialize<T>(json, Options);
        }
        catch (JsonException e)
        {
            throw new ContractValidationException([e.Message]);   // includes the JSON path, e.g. $.vendor
        }
        return Check(value);
    }

    /// <summary>The model_validate twin, for JSON that's already parsed (tool arguments).</summary>
    public static T Bind<T>(JsonElement json) where T : class, IValidatable
    {
        T? value;
        try
        {
            value = json.Deserialize<T>(Options);
        }
        catch (JsonException e)
        {
            throw new ContractValidationException([e.Message]);
        }
        return Check(value);
    }

    private static T Check<T>(T? value) where T : class, IValidatable
    {
        if (value is null)
            throw new ContractValidationException(["expected a JSON object, got null"]);
        IReadOnlyList<string> errors = value.Validate();
        return errors.Count == 0 ? value : throw new ContractValidationException(errors);
    }
}
```

`RespectNullableAnnotations` and `RespectRequiredConstructorParameters` arrived in .NET 9. Agents trained on older code won't use them, and that's exactly the leniency gap above.

### `src/StructuredOutput/Invoice.cs`

```csharp
// src/StructuredOutput/Invoice.cs
using System.ComponentModel;
using System.Text.Json;
using Microsoft.Extensions.AI;

namespace StructuredOutput;

public sealed record LineItem
{
    public required string Description { get; init; }
    [Description("Must be >= 1.")] public required int Quantity { get; init; }
    [Description("Must be >= 0.")] public required decimal UnitPrice { get; init; }
}

/// <summary>The typed contract we want out of messy text: the schema we send AND the validator for what comes back.</summary>
public sealed record Invoice : IValidatable
{
    public required string InvoiceNumber { get; init; }
    public required string Vendor { get; init; }
    [Description("Must be >= 0.")] public required decimal Total { get; init; }
    [Description("ISO date (yyyy-MM-dd), or null if unknown.")] public DateOnly? DueDate { get; init; }
    public IReadOnlyList<LineItem> LineItems { get; init; } = [];

    public IReadOnlyList<string> Validate()
    {
        List<string> errors = [];
        if (Total < 0) errors.Add("total: must be >= 0");
        for (int i = 0; i < LineItems.Count; i++)
        {
            if (LineItems[i].Quantity < 1) errors.Add($"line_items[{i}].quantity: must be >= 1");
            if (LineItems[i].UnitPrice < 0) errors.Add($"line_items[{i}].unit_price: must be >= 0");
        }
        return errors;
    }
}

public static class InvoiceContract
{
    /// <summary>The model_json_schema() equivalent. [Description] text ends up in the schema the model reads.</summary>
    public static JsonElement Schema { get; } =
        AIJsonUtilities.CreateJsonSchema(typeof(Invoice), serializerOptions: ContractJson.Options);

    /// <summary>The Invoice.model_validate_json equivalent.</summary>
    public static Invoice Parse(string json) => ContractJson.Parse<Invoice>(json);
}
```

Money is `decimal`, as in module 03. Two differences from pydantic are worth knowing. First, `System.Text.Json` stops at the *first* type error, while pydantic reports every field at once. So a C# repair round may fix one problem at a time. Second, the `Validate()` rules aren't in the schema. Only the `[Description]` text tells the model about them. pydantic puts `minimum: 0` in the schema for you. You could add it in .NET with `AIJsonSchemaCreateOptions` or `JsonSchemaExporter` (`System.Text.Json.Schema`), but the validator is what actually enforces the rule, so keep that as the source of truth.

You might expect `System.ComponentModel.DataAnnotations` (`[Range]`, `[Required]`) plus `Validator.TryValidateObject` here. That works too, with two traps: on positional records you need the `[property: Range(...)]` target, and `Validator` doesn't recurse into collections, so `LineItems` would go unchecked. A short explicit `Validate()` is easier to read and harder to get wrong.

### `src/StructuredOutput/InvoiceExtractor.cs`

```csharp
// src/StructuredOutput/InvoiceExtractor.cs
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

namespace StructuredOutput;

public sealed class InvoiceExtractor(IChatClient client, ILogger<InvoiceExtractor> logger)
{
    private const string SystemPrompt =
        "You extract invoice fields and return ONLY JSON matching the schema. " +
        "No prose, no markdown fences. If a field is unknown, use null (or omit " +
        "optional fields). Do not invent values.";

    public async Task<Invoice> ExtractAsync(string rawText, int maxAttempts = 3, CancellationToken ct = default)
    {
        List<ChatMessage> messages =
        [
            new(ChatRole.System, SystemPrompt),
            new(ChatRole.User, $"JSON Schema:\n{InvoiceContract.Schema}\n\nInvoice text:\n{rawText}\n\nJSON:"),
        ];
        var options = new ChatOptions { MaxOutputTokens = 512 };
        string lastError = "";

        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            ChatResponse response = await client.GetResponseAsync(messages, options, ct);
            try
            {
                return InvoiceContract.Parse(StripFences(response.Text));
            }
            catch (ContractValidationException e)
            {
                lastError = e.Message;
                logger.LogWarning("extraction attempt {Attempt}/{Max} failed validation: {Errors}",
                    attempt, maxAttempts, lastError);
                // Repair: hand the model its bad output + the exact error.
                messages.Add(new(ChatRole.Assistant, response.Text));
                messages.Add(new(ChatRole.User,
                    $"That did not validate. Errors:\n{lastError}\nReturn corrected JSON only."));
            }
        }
        throw new InvalidOperationException(
            $"could not extract valid invoice after {maxAttempts} attempts: {lastError}");
    }

    /// <summary>Tolerate ```json ... ``` wrapping, which models add even when told not to.</summary>
    public static string StripFences(string text)
    {
        string t = text.Trim();
        if (t.StartsWith("```", StringComparison.Ordinal))
        {
            t = t.Split("```")[1];
            if (t.StartsWith("json", StringComparison.Ordinal)) t = t["json".Length..];
            t = t.Trim();
        }
        return t;
    }
}
```

**The built-in helper.** `Microsoft.Extensions.AI` has a typed extension that does schema + request + deserialize in one call. When the provider supports it, it asks for schema-constrained output (level 3 of the ladder):

```csharp
ChatResponse<Invoice> typed = await client.GetResponseAsync<Invoice>(messages, ContractJson.Options, options, cancellationToken: ct);
if (typed.TryGetResult(out Invoice? invoice) && invoice.Validate().Count == 0)
    return invoice;
```

It's a good shortcut for a single attempt. It doesn't run your `Validate()` rules (`Typed_helper_deserializes_but_does_not_run_Validate` below proves it), and it doesn't retry with the error fed back. So in production you'd put it *inside* the loop above, in place of `GetResponseAsync` + `Parse`, and keep the loop.

### `src/StructuredOutput/Tools.cs`

The registry, the argument records, and `Execute`: the single choke point. `op` is an **enum**, so the schema the model sees lists the four allowed values, as `Literal` does in Python.

```csharp
// src/StructuredOutput/Tools.cs
using System.Collections.Frozen;
using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;

namespace StructuredOutput;

public enum CalcOp { Add, Sub, Mul, Div }

// Deliberately NOT "string Expression" that we evaluate: that would be an injection hole.
public sealed record CalcArgs([property: Description("add, sub, mul or div")] CalcOp Op, double A, double B)
    : IValidatable
{
    public IReadOnlyList<string> Validate() => [];   // the enum and the required doubles did the work
}

public sealed partial record LookupArgs([property: Description("Order id like 'C-42'.")] string OrderId)
    : IValidatable
{
    public IReadOnlyList<string> Validate() =>
        OrderIdPattern().IsMatch(OrderId) ? [] : ["order_id: must look like C-123"];

    // \z, not $: in .NET, $ also matches before a trailing newline, so "C-42\n" would pass.
    [GeneratedRegex(@"^C-[0-9]{1,6}\z")]
    private static partial Regex OrderIdPattern();
}

public sealed record CalcResult(double? Result);

public sealed record OrderStatus(
    string Status,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Eta = null);

public sealed class ToolRegistry
{
    private sealed record Tool(
        string Name, string Description, JsonElement Schema,
        Func<JsonElement, object> Bind,   // untrusted JSON -> validated, typed args (or throw)
        Func<object, object> Run);

    private readonly Dictionary<string, Tool> _tools = new(StringComparer.Ordinal);

    public ToolRegistry Add<TArgs>(string name, string description, Func<TArgs, object> fn)
        where TArgs : class, IValidatable
    {
        _tools[name] = new Tool(
            name,
            description,
            AIJsonUtilities.CreateJsonSchema(typeof(TArgs), serializerOptions: ContractJson.Options),
            Bind: raw => ContractJson.Bind<TArgs>(raw),
            Run: args => fn((TArgs)args));
        return this;
    }

    /// <summary>What we advertise to the model: names, descriptions, argument schemas.</summary>
    public IList<AITool> AsAITools() =>
        [.. _tools.Values.Select(t => new RegistryFunction(this, t.Name, t.Description, t.Schema))];

    /// <summary>The safety choke point. Validate name and args BEFORE running.</summary>
    public JsonObject Execute(string name, IDictionary<string, object?>? rawArgs)
    {
        if (!_tools.TryGetValue(name, out Tool? tool))
            return Error($"unknown tool '{name}'");               // never dispatch by faith

        object args;
        try
        {
            JsonElement raw = JsonSerializer.SerializeToElement(
                rawArgs ?? new Dictionary<string, object?>(), ContractJson.Options);
            args = tool.Bind(raw);                                // untrusted -> typed
        }
        catch (ContractValidationException e)
        {
            return Error($"invalid arguments: {e.Message}");
        }

        // Both tools here are read-only; a WRITE tool would require an
        // authorization check and/or human confirmation right here before Run.
        return JsonSerializer.SerializeToNode(tool.Run(args), ContractJson.Options)!.AsObject();
    }

    private static JsonObject Error(string message) => new() { ["error"] = message };
}

/// <summary>
/// Advertises a registry tool to the model. If something invokes it (e.g. the function-invocation
/// middleware), the call still goes through the registry's choke point.
/// </summary>
internal sealed class RegistryFunction(ToolRegistry registry, string name, string description, JsonElement schema)
    : AIFunction
{
    public override string Name => name;
    public override string Description => description;
    public override JsonElement JsonSchema => schema;

    protected override ValueTask<object?> InvokeCoreAsync(AIFunctionArguments arguments, CancellationToken cancellationToken) =>
        ValueTask.FromResult<object?>(registry.Execute(Name, arguments));
}

public static class DemoTools
{
    // Fake read-only datastore. Real tools would hit a DB/service behind auth.
    private static readonly FrozenDictionary<string, OrderStatus> Orders =
        new Dictionary<string, OrderStatus> { ["C-42"] = new("shipped", "2 days") }.ToFrozenDictionary();

    public static CalcResult Calculator(CalcArgs a) => new(a.Op switch
    {
        CalcOp.Add => a.A + a.B,
        CalcOp.Sub => a.A - a.B,
        CalcOp.Mul => a.A * a.B,
        CalcOp.Div => a.B == 0 ? (double?)null : a.A / a.B,
        _ => throw new UnreachableException(),
    });

    public static OrderStatus LookupOrder(LookupArgs a) =>
        Orders.GetValueOrDefault(a.OrderId) ?? new OrderStatus("not_found");

    public static ToolRegistry CreateRegistry() => new ToolRegistry()
        .Add<CalcArgs>("calculator", "Do one arithmetic operation. op is add|sub|mul|div.", Calculator)
        .Add<LookupArgs>("lookup_order", "Look up a customer order's status by id like 'C-42'.", LookupOrder);
}
```

Why the `RegistryFunction` subclass rather than `AIFunctionFactory.Create(...)`? `AIFunctionFactory.Create` turns any delegate into a tool and generates the schema from its parameters. It's the quickest way to expose a method. But it also *binds* the arguments itself, and all that binding does is convert types: no patterns, no ranges, no authorization. Subclassing `AIFunction` keeps `Execute` as the only way in, whichever loop ends up calling the tool.

### `src/StructuredOutput/ToolLoop.cs`

The explicit loop, the same shape and protocol as `run_with_tools`:

```csharp
// src/StructuredOutput/ToolLoop.cs
using System.Text.Json.Serialization;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

namespace StructuredOutput;

/// <summary>One model turn: call a tool, or answer. Untrusted input, so it's validated like any other.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]   // pydantic's extra="forbid"
public sealed record Decision : IValidatable
{
    public string? Tool { get; init; }
    public Dictionary<string, object?> Arguments { get; init; } = [];
    public string? Answer { get; init; }

    public IReadOnlyList<string> Validate() =>
        (Tool is null) == (Answer is null) ? ["set exactly one of 'tool' or 'answer'"] : [];
}

public sealed class ToolLoop(IChatClient client, ToolRegistry registry, ILogger<ToolLoop> logger)
{
    public const string ReplyFormat =
        """Reply with ONE JSON object and nothing else: {"tool": "<name>", "arguments": {...}} """ +
        """to call a tool, or {"answer": "<text>"} when you can answer.""";

    /// <summary>What we advertise to the model: names, descriptions, argument schemas, and the reply format.</summary>
    public string SystemPrompt()
    {
        IEnumerable<string> tools = registry.AsAITools().OfType<AIFunction>().Select(f =>
            $"- {f.Name}: {f.Description} Arguments (JSON Schema): {f.JsonSchema.GetRawText()}");
        return $"You can call these tools:\n{string.Join("\n", tools)}\n{ReplyFormat}";
    }

    /// <summary>Model may ask for tools; we validate+run and feed results back.
    /// ALWAYS bounded by maxSteps so a confused model can't loop forever.</summary>
    public async Task<string> RunAsync(string userMessage, int maxSteps = 5, CancellationToken ct = default)
    {
        List<ChatMessage> messages = [new(ChatRole.System, SystemPrompt()), new(ChatRole.User, userMessage)];
        var options = new ChatOptions { MaxOutputTokens = 512 };

        for (int step = 0; step < maxSteps; step++)
        {
            ChatResponse response = await client.GetResponseAsync(messages, options, ct);
            messages.Add(new(ChatRole.Assistant, response.Text));

            Decision decision;
            try
            {
                decision = ContractJson.Parse<Decision>(InvoiceExtractor.StripFences(response.Text));
            }
            catch (ContractValidationException e)
            {
                // A malformed turn costs a step; the model gets told exactly what was wrong.
                messages.Add(new(ChatRole.User, $"That was not a valid reply: {e.Message}\n{ReplyFormat}"));
                continue;
            }

            if (decision.Answer is { } answer)
                return answer;                                    // model is done

            var result = registry.Execute(decision.Tool!, decision.Arguments);
            logger.LogInformation("tool {Tool} -> {Result}", decision.Tool, result.ToJsonString());
            // A User message, not ChatRole.Tool: providers only accept a tool role in answer to a native call.
            messages.Add(new(ChatRole.User, $"Result of {decision.Tool}: {result.ToJsonString()}"));
        }
        return "stopped: hit max tool steps";
    }
}
```

`[JsonUnmappedMemberHandling(Disallow)]` is pydantic's `extra="forbid"`: a reply with a key the protocol doesn't define is an error, not something silently ignored.

**The native version, as middleware.** With a provider that supports tool calling natively, `Microsoft.Extensions.AI` runs this loop for you as a decorator, `FunctionInvokingChatClient`, the same way ASP.NET Core ships retries and auth as middleware. The model returns `FunctionCallContent`, the middleware invokes the matching `AITool`, and it sends back `FunctionResultContent` with the same `CallId`:

```csharp
IChatClient auto = new ChatClientBuilder(client)
    .UseFunctionInvocation(configure: f => f.MaximumIterationsPerRequest = 5)   // the step cap
    .Build();
ChatResponse reply = await auto.GetResponseAsync(
    "What's the status of order C-42?", new ChatOptions { Tools = registry.AsAITools() }, ct);
```

The trade-off: you get less code, parallel calls and provider-native reliability, and the step cap becomes configuration. In exchange the loop is hidden. You don't see each call unless you add logging middleware, and the cap's default is a library choice you might not know. It only stays safe because every tool routes through `Execute`, which `Native_calls_through_the_middleware_still_hit_the_choke_point` below checks. It needs a backend that does native tool calls (Ollama with a tool-capable model, or a hosted one); the stub doesn't.

### `src/StructuredOutput/Program.cs`

Same behavior as `run.py`: extract the sample invoice, then answer a question with tools.

```csharp
// src/StructuredOutput/Program.cs
using System.Text.Encodings.Web;
using System.Text.Json;
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using StructuredOutput;

// Same behavior as run.py: extract the sample invoice, then answer a question with tools.
HostApplicationBuilder builder = Host.CreateApplicationBuilder();
IConfiguration config = builder.Configuration;
// Logs go to stderr, as in run.py, so stdout is only the invoice and the answer.
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
// Shared with the Python side. Relative to csharp/, where you run from; the Dockerfile sets it.
string fixturesDir = config["FIXTURES_DIR"] ?? "../fixtures";

if (config["LLM_BACKEND"] == "stub" && string.IsNullOrEmpty(config["LLM_STUB_REPLY"]))
{
    // On a bare stub, play the scripted model in fixtures/stub_replies.jsonl, as run.py does,
    // with project 04's cost logging around it like every other backend.
    string[] script = [.. File.ReadLines(Path.Combine(fixturesDir, "stub_replies.jsonl"))
        .Where(line => !string.IsNullOrWhiteSpace(line))];
    builder.Services.AddChatClient(new StubChatClient(script))
        .Use((inner, sp) => new CostLoggingChatClient(
            inner, Rates.Free, sp.GetRequiredService<ILogger<CostLoggingChatClient>>()));
}
else
{
    builder.Services.AddLlmClient(config);   // project 04: backend switch, retries, cost logging
}
builder.Services.AddSingleton(DemoTools.CreateRegistry());
builder.Services.AddSingleton<InvoiceExtractor>();
builder.Services.AddSingleton<ToolLoop>();
using IHost host = builder.Build();

// Part 1: schema-guided extraction with validate + repair.
string path = args.ElementAtOrDefault(0) ?? Path.Combine(fixturesDir, "sample_invoice.txt");
Invoice invoice = await host.Services.GetRequiredService<InvoiceExtractor>().ExtractAsync(await File.ReadAllTextAsync(path));
Console.WriteLine(JsonSerializer.Serialize(invoice, new JsonSerializerOptions(ContractJson.Options)
{
    WriteIndented = true,                                   // model_dump_json(indent=2)
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,  // print "€" as €, as pydantic does, not €
}));

// Part 2: the tool-calling loop.
Console.WriteLine(await host.Services.GetRequiredService<ToolLoop>()
    .RunAsync("What's the status of order C-42, and what is 19.99 * 3?"));
return 0;
```

### Tests

Same rule as the Python side: unit tests never call a model. `FakeChatClient` replays scripted responses and records what it was sent. (Project 04's `FakeChatClient` returns one fixed reply, and its `StubChatClient` doesn't record calls or produce `FunctionCallContent`. This one does all three.)

```csharp
// tests/StructuredOutput.Tests/FakeChatClient.cs
using Microsoft.Extensions.AI;

namespace StructuredOutput.Tests;

/// <summary>Replays scripted responses and records what it was sent. No network.</summary>
public sealed class FakeChatClient(params ChatResponse[] replies) : IChatClient
{
    private readonly Queue<ChatResponse> _replies = new(replies);

    /// <summary>A snapshot of the messages sent on each call.</summary>
    public List<List<ChatMessage>> Calls { get; } = [];

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        Calls.Add([.. messages]);
        return Task.FromResult(_replies.Dequeue());
    }

    public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException();

    public object? GetService(Type serviceType, object? serviceKey = null) => null;

    public void Dispose() { }

    public static ChatResponse Text(string text) => new(new ChatMessage(ChatRole.Assistant, text));

    /// <summary>A native tool call (FunctionCallContent), for the middleware test.</summary>
    public static ChatResponse Call(string callId, string name, Dictionary<string, object?> args) =>
        new(new ChatMessage(ChatRole.Assistant, [new FunctionCallContent(callId, name, args)]));

    public static FakeChatClient Texts(params string[] texts) => new([.. texts.Select(Text)]);
}
```

```csharp
// tests/StructuredOutput.Tests/InvoiceTests.cs
using NUnit.Framework;

namespace StructuredOutput.Tests;

public class InvoiceTests
{
    [Test]
    public void Valid_invoice_parses_with_defaults()
    {
        Invoice ok = InvoiceContract.Parse("""{"invoice_number":"INV-1","vendor":"Acme","total":10.0}""");
        Assert.That(ok.DueDate, Is.Null);
        Assert.That(ok.Total, Is.EqualTo(10.0m));
        Assert.That(ok.LineItems, Is.Empty);
    }

    // The verdict table. test_extract.py runs the same JSON, and every verdict must agree.
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":5}""", true)]
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":"5"}""", true)]     // lax: numeric string -> number
    [TestCase("""{"invoice_number":"INV-1","total":5}""", false)]                       // missing vendor
    [TestCase("""{"invoice_number":"INV-1","vendor":null,"total":5}""", false)]         // null for a required string
    [TestCase("""{"invoice_number":"INV-1","Vendor":"Acme","total":5}""", false)]       // names are case-sensitive
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":-5}""", false)]      // total < 0
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":5,"line_items":null}""", false)]
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":5,"line_items":[{"description":"x","quantity":0,"unit_price":1}]}""", false)]
    [TestCase("""{"invoice_number":"INV-1","vendor":"Acme","total":5,"due_date":"15/11/2026"}""", false)]
    [TestCase("not json", false)]
    public void Invoice_verdicts(string json, bool valid)
    {
        if (valid)
            Assert.That(() => InvoiceContract.Parse(json), Throws.Nothing);
        else
            Assert.That(() => InvoiceContract.Parse(json), Throws.InstanceOf<ContractValidationException>());
    }
}
```

```csharp
// tests/StructuredOutput.Tests/InvoiceExtractorTests.cs
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using NUnit.Framework;

namespace StructuredOutput.Tests;

public class InvoiceExtractorTests
{
    private const string Good = """{"invoice_number":"INV-1","vendor":"Acme","total":12.5}""";

    [Test]
    public async Task Repairs_after_one_bad_reply()
    {
        var fake = FakeChatClient.Texts(
            """{"invoice_number":"INV-1","total":12.5}""",   // missing vendor
            $"```json\n{Good}\n```");                        // fenced, but valid
        var extractor = new InvoiceExtractor(fake, NullLogger<InvoiceExtractor>.Instance);

        Invoice invoice = await extractor.ExtractAsync("raw invoice text");

        Assert.That(invoice.Vendor, Is.EqualTo("Acme"));
        Assert.That(fake.Calls, Has.Count.EqualTo(2));
        // The retry carried the validation error back to the model.
        Assert.That(fake.Calls[1][^1].Text, Does.Contain("did not validate"));
        Assert.That(fake.Calls[1][^1].Text, Does.Contain("vendor"));
    }

    [Test]
    public void Gives_up_after_max_attempts()
    {
        var fake = FakeChatClient.Texts("not json", "not json", "not json");
        var extractor = new InvoiceExtractor(fake, NullLogger<InvoiceExtractor>.Instance);

        Assert.That(() => extractor.ExtractAsync("raw", maxAttempts: 3),
            Throws.InvalidOperationException.With.Message.Contains("after 3 attempts"));
        Assert.That(fake.Calls, Has.Count.EqualTo(3));
    }

    [Test]
    public async Task Typed_helper_deserializes_but_does_not_run_Validate()
    {
        IChatClient fake = FakeChatClient.Texts("""{"invoice_number":"INV-1","vendor":"Acme","total":-5}""");

        ChatResponse<Invoice> typed = await fake.GetResponseAsync<Invoice>(
            [new ChatMessage(ChatRole.User, "extract")], ContractJson.Options);

        Assert.That(typed.TryGetResult(out Invoice? invoice), Is.True);   // it parsed...
        Assert.That(invoice!.Validate(), Is.Not.Empty);                     // ...but total < 0 got through
    }
}
```

```csharp
// tests/StructuredOutput.Tests/ToolsTests.cs
using System.Text.Json;
using NUnit.Framework;

namespace StructuredOutput.Tests;

public class ToolsTests
{
    private readonly ToolRegistry _registry = DemoTools.CreateRegistry();

    private static Dictionary<string, object?> Args(string json) =>
        JsonSerializer.Deserialize<Dictionary<string, object?>>(json)!;

    [Test]
    public void Valid_calculator_call() =>
        Assert.That(_registry.Execute("calculator", Args("""{"op":"add","a":2,"b":3}"""))["result"]!.GetValue<double>(),
            Is.EqualTo(5.0));

    [Test]
    public void Divide_by_zero_is_null_not_a_crash() =>
        Assert.That(_registry.Execute("calculator", Args("""{"op":"div","a":1,"b":0}""")).ToJsonString(),
            Is.EqualTo("""{"result":null}"""));

    [Test]
    public void Rejects_unknown_tool() =>
        Assert.That(_registry.Execute("rm_rf", Args("""{"path":"/"}"""))["error"]!.GetValue<string>(),
            Does.Contain("unknown tool"));   // never dispatched

    // The same bad arguments test_tools.py rejects.
    [TestCase("lookup_order", """{"order_id":"'; DROP TABLE orders; --"}""")]
    [TestCase("lookup_order", """{"order_id":"C-42\n"}""")]          // passes with $, fails with \z
    [TestCase("calculator", """{"op":"pow","a":1,"b":1}""")]
    [TestCase("calculator", """{"op":2,"a":1,"b":1}""")]             // enum as an integer
    [TestCase("calculator", """{"op":"add","a":1}""")]               // missing b must not become 0
    public void Rejects_bad_args(string tool, string json) =>
        Assert.That(_registry.Execute(tool, Args(json))["error"]!.GetValue<string>(),
            Does.StartWith("invalid arguments"));

    [TestCase("C-42", "shipped")]
    [TestCase("C-99", "not_found")]
    public void Lookup_hit_and_miss(string id, string status) =>
        Assert.That(_registry.Execute("lookup_order", Args($$"""{"order_id":"{{id}}"}"""))["status"]!.GetValue<string>(),
            Is.EqualTo(status));
}
```

```csharp
// tests/StructuredOutput.Tests/ToolLoopTests.cs
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using NUnit.Framework;

namespace StructuredOutput.Tests;

public class ToolLoopTests
{
    private static ToolLoop Loop(IChatClient client) =>
        new(client, DemoTools.CreateRegistry(), NullLogger<ToolLoop>.Instance);

    [Test]
    public async Task Runs_tool_then_returns_final_text()
    {
        var fake = FakeChatClient.Texts(
            """{"tool": "lookup_order", "arguments": {"order_id": "C-42"}}""",
            """{"answer": "Order C-42 has shipped."}""");

        string answer = await Loop(fake).RunAsync("Where is C-42?");

        Assert.That(answer, Is.EqualTo("Order C-42 has shipped."));
        // The second call carried the real tool result back to the model: the same text as Python's.
        Assert.That(fake.Calls[1][^1].Text, Is.EqualTo("""Result of lookup_order: {"status":"shipped","eta":"2 days"}"""));
    }

    [Test]
    public async Task Bad_arguments_go_back_to_the_model_not_into_the_tool()
    {
        var fake = FakeChatClient.Texts(
            """{"tool": "lookup_order", "arguments": {"order_id": "C-42; DROP TABLE orders"}}""",
            """{"answer": "Sorry, that is not a valid order id."}""");
        await Loop(fake).RunAsync("Where is C-42; DROP TABLE orders?");
        Assert.That(fake.Calls[1][^1].Text, Does.StartWith("""Result of lookup_order: {"error":"invalid arguments"""));
    }

    [Test]
    public async Task Invalid_reply_is_fed_back()
    {
        var fake = FakeChatClient.Texts("""{"tool": "calculator", "answer": "both?"}""", """{"answer": "ok"}""");
        Assert.That(await Loop(fake).RunAsync("hi"), Is.EqualTo("ok"));
        Assert.That(fake.Calls[1][^1].Text, Does.Contain("not a valid reply"));
    }

    [Test]
    public async Task Stops_at_step_cap()
    {
        const string forever = """{"tool": "calculator", "arguments": {"op": "add", "a": 1, "b": 1}}""";
        var fake = FakeChatClient.Texts([.. Enumerable.Repeat(forever, 5)]);

        Assert.That(await Loop(fake).RunAsync("loop forever", maxSteps: 5), Is.EqualTo("stopped: hit max tool steps"));
        Assert.That(fake.Calls, Has.Count.EqualTo(5));
    }

    [Test]
    public async Task Native_calls_through_the_middleware_still_hit_the_choke_point()
    {
        // The provider-native version: a FunctionCallContent, run by MEAI's function-invocation middleware.
        var fake = new FakeChatClient(
            FakeChatClient.Call("call-1", "lookup_order", new() { ["order_id"] = "C-42\n" }),
            FakeChatClient.Text("That id isn't valid."));
        IChatClient auto = new ChatClientBuilder(fake)
            .UseFunctionInvocation(configure: f => f.MaximumIterationsPerRequest = 5)   // the step cap
            .Build();

        ChatResponse reply = await auto.GetResponseAsync(
            "Where is C-42?", new ChatOptions { Tools = DemoTools.CreateRegistry().AsAITools() });

        Assert.That(reply.Text, Is.EqualTo("That id isn't valid."));
        FunctionResultContent result = fake.Calls[1].SelectMany(m => m.Contents).OfType<FunctionResultContent>().Single();
        Assert.That(result.CallId, Is.EqualTo("call-1"));                        // answers the call the model made
        Assert.That(result.Result?.ToString(), Does.Contain("invalid arguments"));   // Execute ran, and refused
    }
}
```

Run locally:

```powershell
dotnet test
dotnet test --filter "FullyQualifiedName~ToolsTests"
$env:LLM_BACKEND = 'stub'; dotnet run --project src/StructuredOutput     # offline: the scripted model
$env:LLM_BACKEND = 'ollama'; dotnet run --project src/StructuredOutput   # Ollama on localhost:11434
dotnet run --project src/StructuredOutput -- path/to/other_invoice.txt
```

For `LLM_BACKEND=hosted`, keep the key in user-secrets as in [module 04](04-calling-models-apis-sdks.md): `dotnet user-secrets init --project src/StructuredOutput` adds the `UserSecretsId`, and `DOTNET_ENVIRONMENT=Development` makes the host load them.

### Running the C# version in Docker

The `ProjectReference` to project 04 widens the build context to `projects/`, as in module 05. The restore layer copies 04's `Directory.Build.props` with its `.csproj`, and the scaffold's `Dockerfile.dockerignore` filters the context.

```dockerfile
# projects/06-structured-output/csharp/Dockerfile — build context: projects/
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer: every .csproj, plus 04's Directory.Build.props (MSBuild applies the nearest one).
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 06-structured-output/csharp/StructuredOutput.slnx 06-structured-output/csharp/Directory.Build.props 06-structured-output/csharp/
COPY 06-structured-output/csharp/src/StructuredOutput/StructuredOutput.csproj 06-structured-output/csharp/src/StructuredOutput/
COPY 06-structured-output/csharp/tests/StructuredOutput.Tests/StructuredOutput.Tests.csproj 06-structured-output/csharp/tests/StructuredOutput.Tests/
WORKDIR /src/06-structured-output/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 06-structured-output/csharp/ 06-structured-output/csharp/
WORKDIR /src/06-structured-output/csharp
RUN dotnet publish src/StructuredOutput -c Release -o /app --no-restore

FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 06-structured-output/fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
USER $APP_UID
ENTRYPOINT ["dotnet", "StructuredOutput.dll"]
```

```yaml
# projects/06-structured-output/csharp/compose.yaml
name: structured-output-cs
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build:
      context: ../..                         # projects/: project 04 must be inside the context
      dockerfile: 06-structured-output/csharp/Dockerfile
      target: final
    env_file:
      - path: .env             # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

  test:
    build: { context: ../.., dockerfile: 06-structured-output/csharp/Dockerfile, target: test }
    profiles: [test]           # only runs when asked for by name

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

```powershell
cd projects/06-structured-output/csharp
docker compose run --rm test                                    # dotnet test, no network
docker compose run --rm --no-deps -e LLM_BACKEND=stub app       # offline: the scripted model
docker compose --profile ollama up -d ollama   # skip if Ollama runs natively
docker compose exec ollama ollama pull llama3.2   # native: ollama pull llama3.2
docker compose run --rm app                                     # extract the sample invoice, then a tool query
# Without compose, from the repo root:
# docker build -f projects/06-structured-output/csharp/Dockerfile --target final -t structured-output-cs projects
```

Both compose files publish Ollama on port 11434, so stop one stack before you start the other (or drop the `ports:` line, since the app reaches Ollama over the compose network anyway). The C# compose reads the same `.env` variables: copy `python/.env.example` to `csharp/.env`.

## Cross-check the two

**Exact, on the stub.** Run both programs on the scripted model. stdout (the invoice JSON and the final answer) must be byte-identical. From `projects/06-structured-output`:

```powershell
$env:LLM_BACKEND = 'stub'
Push-Location python; uv run python run.py 2> ../py.err > ../py.out; Pop-Location
Push-Location csharp; dotnet run --project src/StructuredOutput 2> ../cs.err > ../cs.out; Pop-Location
Compare-Object (Get-Content py.out) (Get-Content cs.out)    # no output = identical
```

That one comparison covers a lot: the repair round, the protocol parsing, both tool calls, and the JSON printing (pydantic's `model_dump_json(indent=2)` and the indented `System.Text.Json` output agree field for field). The `llm_call` lines agree on `out=` but not on `in=`: the stub counts prompt words, and the two schema generators write different schemas. That's the one prompt that legitimately differs between the languages.

**Exact, in the tests.** The deterministic contracts are pinned case for case:

- **Validation verdicts.** `test_invoice_verdicts` and `Invoice_verdicts` run the same JSON strings: valid, numeric string, missing vendor, `null` vendor, `"Vendor"`, negative total, `"line_items": null`, `quantity: 0`, a non-ISO date, not JSON. Every verdict agrees. Error *messages* differ, and that's fine.
- **Tool results and refusals.** The same calls in `test_tools.py` and `ToolsTests`: add, divide by zero → `null`, hit and miss, unknown tool, and five bad-argument cases. The loop tests check the exact text fed back to the model, `Result of lookup_order: {"status":"shipped","eta":"2 days"}`, in both languages.

**Known differences**, found by running the same input on both sides:

- **`"C-42\n"`** is rejected by both, for different reasons. pydantic's `pattern` runs on a Rust regex engine, where `$` matches only at the very end. .NET's `$` also matches before a trailing newline, hence `\z`. Python's own `re` behaves like .NET, so a hand-rolled `re.match` check would have let it through.
- **`"op": "ADD"`** passes in C# and fails in Python: `JsonStringEnumConverter` reads enum names case-insensitively, `Literal` doesn't. Harmless here (it's the same operation), but it's a verdict difference, and it's the kind the cross-check exists to find.
- **`"quantity": 1.0`** passes pydantic's lax mode and fails `System.Text.Json`'s `int` reader.
- **Numbers print differently:** Python serializes the float `5.0` where `System.Text.Json` writes `5`. Compare parsed values, not JSON text, when results are whole numbers.

**Approximate, on a real model.** Run the sample invoice through both containers at the same model. The fields should agree. The number of repair rounds may not: the prompts differ (the schema text) and so do the error messages. Large differences in *which* fields come out are worth a look; small ones are normal model variance.

| Concern | Python | C# / .NET |
|---|---|---|
| Typed contract | pydantic `BaseModel` | `record` + `required` members |
| Parse + type rules | `model_validate_json` | `ContractJson.Parse<T>`: `JsonSerializer` + strict `JsonSerializerOptions` |
| Value rules (`ge`, `pattern`) | `Field(ge=..., pattern=...)` | hand-written `Validate()` (or DataAnnotations, which doesn't recurse) |
| Unknown keys | `extra="forbid"` | `[JsonUnmappedMemberHandling(Disallow)]` |
| Errors | all fields at once (`ValidationError`) | first type error (`JsonException`), then your rule list |
| JSON Schema | `model_json_schema()` | `AIJsonUtilities.CreateJsonSchema` (or `JsonSchemaExporter`) |
| Built-in structured output | provider SDK modes | `GetResponseAsync<T>` → `ChatResponse<T>` |
| Hand-written tool loop | prompt protocol over `complete()` | the same protocol over `GetResponseAsync` |
| Native tool calls | not in project 04's client | `FunctionCallContent` / `FunctionResultContent`, `UseFunctionInvocation()` |
| Tests | pytest + `RecordingClient` (04's `StubClient`) | NUnit + `FakeChatClient : IChatClient` |

## Moving to AWS

- **Bedrock's `Converse` API has a tool-use pattern** built in: you pass a `toolConfig` describing your tools (name, description, input JSON Schema), the model returns a `toolUse` block when it wants to call one, and you return a `toolResult` block — the same declare → call → execute → feed-back loop as above, just Bedrock's field names. Your `execute` choke point (validate name, validate args, authorize, run) is unchanged; only the transport differs, which is the payoff of having wrapped it behind your own interface.
- **The prompt-protocol loops move with no change.** They only need plain chat, so module 12's `LLM_BACKEND=bedrock` in project 04's library is all it takes, in both languages.
- **Native tool use is a library change, not a module change.** In C#, the Bedrock `IChatClient` from `AWSSDK.Extensions.Bedrock.MEAI` maps `toolUse` / `toolResult` to `FunctionCallContent` / `FunctionResultContent`, so the `UseFunctionInvocation` version and `RegistryFunction` work as they are. In Python, native tools would mean adding a tools-aware method to project 04's client for every backend, Bedrock included; `execute` stays the choke point either way.
- Bedrock (and others) also support structured/JSON output modes; the same validate-and-repair discipline carries over — never skip validation just because a "strict" mode is on.
- Keep the authorization boundary server-side and IAM-aware: a tool that touches AWS resources runs with the task's IAM role, so scope that role to exactly what the tools need — least privilege, the same as any service.

## How experts think / pitfalls

- **A model's output is untrusted input.** Validate structured output; validate *and authorize* tool calls. This is the whole module in one line.
- **Validate before you use, never after.** The `execute` function checks the tool name and argument schema *before* dispatching — dispatching first and hoping is how you get an incident.
- **Read-only first.** Expose look-up tools before action tools. When you must expose a write, gate it behind explicit authorization or human confirmation, and log it.
- **Repair-retry beats one-shot hope,** but cap attempts. A loop with no bound burns tokens and hides a genuinely broken case.
- **Tighten schemas.** Enums, patterns, ranges, required fields — every constraint you add is an invalid call the model can't make and you don't have to handle downstream.
- **Descriptions are prompts.** Bad tool names/descriptions cause bad tool choices. Write them for the model.
- **Structured mode is not validation.** "JSON mode" guarantees parseable JSON, not *your* schema. Always validate the fields.
- **Injection reaches tools.** Untrusted text in the context can steer tool calls. Your validate-and-authorize layer is the defense, not the model's good judgment.
- **Know your deserializer's defaults.** `System.Text.Json` out of the box fills missing fields with `null`/`0` and accepts enums as integers. pydantic rejects both. A validator is only as strict as its options, so put the strict options in one shared place (`ContractJson`) and test the lenient cases explicitly.
- **Tool results are messages, not reprs.** Send JSON (`json.dumps`, `ToJsonString`) back to the model, and use the `tool` role only for a native call with its id. `str(dict)` and an orphan `tool` message both look fine in a stub test and fail against a real provider.
- **Middleware loops still need the choke point.** `UseFunctionInvocation()` will happily invoke whatever `AIFunction` you hand it. Convenience moves the loop into the library. It doesn't move validation and authorization there. Route every tool through the same `Execute`, whichever loop runs it.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Watch for:** validation loosened until it passes (fields made `Optional`, `extra="allow"`, catch-all defaults). That's `test-tampering` aimed at the schema instead of the test. Also watch for repair-retry loops that hide real failures (`swallowed-error`), and tool tests that mock the model *and* the tool (`mock-the-subject`).
- **C#-specific watch:** `Microsoft.Extensions.AI` was renamed heavily on its way to GA, so agent-written code mixes generations: `CompleteAsync` / `ChatCompletion` (old) vs `GetResponseAsync` / `ChatResponse` (current), `CompleteAsync<T>` vs `GetResponseAsync<T>`, `FunctionResultContent` constructors with and without a name argument, and `AIFunction.InvokeAsync` overloads that take a plain dictionary vs `AIFunctionArguments`. Also watch for `System.Text.Json` code that "validates" without the strict options (no `required`, no `RespectNullableAnnotations`), regexes anchored with `$` where `\z` was meant, and `JsonSerializerDefaults.Web` used without turning `PropertyNameCaseInsensitive` back off. Check against the current package docs. The code in this doc included.
- **Before moving on:** draft your [personal benchmark](R-reviewing-ai-written-code.md#tracking-model-releases), about five fixed tasks taken from projects 03–06.

## Checkpoint

You're ready for module 07 if you can:

- [ ] Explain why validated structured output makes a model a *component*, and name the three levels of output guarantee.
- [ ] Define a pydantic model, generate its JSON Schema, and validate untrusted JSON against it.
- [ ] Implement a validate-and-repair loop that feeds the validation error back, with a capped number of attempts.
- [ ] Describe the tool-calling loop (declare → call → validate → execute → feed back → repeat) and where the step cap goes.
- [ ] Say how native tool calling and the prompt protocol differ, and why the hand-written loops here use the protocol.
- [ ] Run both programs on `LLM_BACKEND=stub` and show their stdout matches exactly, repair round and tool calls included.
- [ ] Explain the reflection/RPC analogy *and* why the caller must be treated as untrusted.
- [ ] State the difference between validating arguments and authorizing an action, and why read-only tools come first.
- [ ] Point to the single choke point in your code where tool name + arguments are validated before execution.
- [ ] Run the same list of good and bad invoice JSON through pydantic and through your C# `InvoiceContract.Parse` (`test_invoice_verdicts` / `Invoice_verdicts`), and get the same accept/reject verdict for every case. Name the `JsonSerializerOptions` settings that make that possible, and two inputs where the languages still disagree.
- [ ] Explain what `UseFunctionInvocation()` and `GetResponseAsync<T>` do for you, what they don't (your validation, your authorization, your repair prompt), and where the step cap lives in each version.

## Going deeper

- pydantic docs: models, `Field` constraints, `model_validate` / `model_validate_json`, and JSON Schema generation.
- Your provider's docs for the *current* structured-output modes (JSON mode vs schema-constrained decoding) and the exact tool-calling / function-calling request and response shapes — these differ and evolve, so don't hardcode from memory.
- Amazon Bedrock `Converse` API tool-use documentation for when you deploy in module 12.
- "Microsoft.Extensions.AI structured output" and "Microsoft.Extensions.AI function calling": `GetResponseAsync<T>`, `AIFunctionFactory`, `FunctionInvokingChatClient`. Read the current docs, since the API surface is still moving.
- "System.Text.Json RespectNullableAnnotations RespectRequiredConstructorParameters" and "JsonSchemaExporter": strict deserialization and schema generation in the BCL.
- The concept of "constrained decoding" / grammar-based generation (how open-source servers force schema conformance at the token level) — module 10 territory.
- Forward reference: [08 — Agents & orchestration](08-agents-and-orchestration.md), which is this tool-calling loop grown up — multi-step planning, memory, and knowing when *not* to build an agent.

*Last verified: 2026-10-05. Built: Python (pytest 28 passed, pyright clean) and C# (dotnet test 29 passed) in a throwaway build against project 04's build; both programs run on the stub, and the stub cross-check (stdout) is exact. Read-only: Docker images (compose files validated with `docker compose config`) and the Ollama and hosted paths against a live model, including native tool calls through `UseFunctionInvocation` against a real provider.*

**Verify on first build:** that your Ollama model and OllamaSharp version return native tool calls as `FunctionCallContent` (the middleware test uses a fake), and that `GetResponseAsync<T>` asks your provider for schema-constrained output rather than only describing the schema in the prompt.

Next: [07 — Retrieval-augmented generation (RAG)](07-retrieval-augmented-generation.md).
