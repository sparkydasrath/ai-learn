# 06 — Structured outputs & tool calling

> **Background.** You're a senior/staff .NET engineer becoming an AI engineer. A model that returns free-form prose is a UI feature; a model that returns a **validated object** is a component you can build a system on. This module is about two tightly related moves: getting reliable, schema-conforming JSON *out* of a model (so downstream code can consume it like any DTO), and letting the model call *your* code (tool/function calling) so it can look things up and act. Both hinge on an instinct you already have hard-wired: **never trust input at a boundary.** A model's output is untrusted input. A model's request to call your function with some arguments is untrusted input. Validate and authorize accordingly. Provider APIs for structured output and tool calling differ in shape and are still evolving, so treat the specific mechanics here as illustrative patterns and confirm against current provider docs.

## Where this fits

**Prerequisites:** [01](01-python-for-dotnet-engineers.md), [03](03-llm-fundamentals-for-engineers.md), [04 — Calling models](04-calling-models-apis-sdks.md) (you'll use the `LlmClient`; tool calling shows up as a `finish_reason`), [05 — Prompts as engineering](05-prompt-engineering-as-engineering.md) (output format is part of the prompt contract).

**Outcomes:** after this you can specify a JSON schema for a model's output, validate it with pydantic, and repair/retry when it's wrong; and you can run a minimal tool-calling loop where the model asks to call typed functions, you validate the arguments, execute safe read-only tools, and feed results back. This is the direct on-ramp to agents in module 08.

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

**`projects/06-structured-output/`** — two parts. First, extract structured data: parse a messy invoice/email into a pydantic model with schema-guided output + validation + repair-retry. Second, a minimal tool-calling loop with two safe, read-only tools (a calculator and a lookup), pydantic-validated arguments, and a step cap. Dockerized, with tests. Reuses the `LlmClient` from project 04.

### Layout

```
projects/06-structured-output/
├── pyproject.toml
├── Dockerfile
├── compose.yaml
├── src/structured/
│   ├── __init__.py
│   ├── extract.py       # invoice extraction + validate/repair loop
│   ├── tools.py         # tool registry, schemas, safe execution
│   └── loop.py          # the tool-calling loop with a step cap
├── tests/
│   ├── test_extract.py
│   └── test_tools.py
├── data/
│   └── sample_invoice.txt
└── run.py
```

### Part 1 — schema-guided extraction with validate + repair

```python
# src/structured/extract.py
from __future__ import annotations
import json
from datetime import date
from pydantic import BaseModel, Field, ValidationError
# from llmclient import Message   # reuse project 04's client


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
    line_items: list[LineItem] = []


EXTRACT_SYSTEM = (
    "You extract invoice fields and return ONLY JSON matching the schema. "
    "No prose, no markdown fences. If a field is unknown, use null (or omit "
    "optional fields). Do not invent values."
)


def _prompt(raw_text: str) -> str:
    schema = json.dumps(Invoice.model_json_schema(), indent=2)
    return f"JSON Schema:\n{schema}\n\nInvoice text:\n{raw_text}\n\nJSON:"


async def extract_invoice(client, raw_text: str, *, max_attempts: int = 3) -> Invoice:
    messages = [
        Message("system", EXTRACT_SYSTEM),
        Message("user", _prompt(raw_text)),
    ]
    last_error = ""
    for attempt in range(max_attempts):
        completion = await client.complete(messages, max_tokens=512)
        text = _strip_fences(completion.text)
        try:
            return Invoice.model_validate_json(text)
        except ValidationError as e:
            last_error = str(e)
            # Repair: hand the model its bad output + the exact error.
            messages += [
                Message("assistant", completion.text),
                Message(
                    "user",
                    f"That did not validate. Errors:\n{last_error}\n"
                    "Return corrected JSON only.",
                ),
            ]
    raise ValueError(f"could not extract valid invoice after "
                     f"{max_attempts} attempts: {last_error}")


def _strip_fences(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        t = t.split("```")[1]          # tolerate ```json ... ``` wrapping
        t = t.removeprefix("json").strip()
    return t
```

> **Pythonism flag.** pydantic `BaseModel` is the idiomatic validated-DTO in modern Python (it powers FastAPI). `Field(ge=1)` attaches constraints (`>= 1`); `model_validate_json` parses-and-validates in one step and raises `ValidationError` with a precise, field-level message — which is exactly what we feed back for repair. `due_date: date | None = None` models "optional/unknown" without a sentinel. `model_json_schema()` emits the JSON Schema you hand to the provider.

### Part 2 — a minimal, safe tool-calling loop

```python
# src/structured/tools.py
from __future__ import annotations
from typing import Callable
from pydantic import BaseModel, Field, ValidationError


class CalcArgs(BaseModel):
    # Deliberately NOT "expression: str" that we eval — that would be an
    # injection hole. Structured, bounded operations only.
    op: str = Field(pattern="^(add|sub|mul|div)$")
    a: float
    b: float


class LookupArgs(BaseModel):
    order_id: str = Field(pattern="^C-[0-9]{1,6}$")   # tight, validated shape


# Fake read-only datastore. Real tools would hit a DB/service behind auth.
_ORDERS = {"C-42": {"status": "shipped", "eta": "2 days"}}


def calculator(args: CalcArgs) -> dict:
    result = {"add": args.a + args.b, "sub": args.a - args.b,
              "mul": args.a * args.b,
              "div": args.a / args.b if args.b else None}[args.op]
    return {"result": result}


def lookup_order(args: LookupArgs) -> dict:
    return _ORDERS.get(args.order_id, {"status": "not_found"})


class Tool(BaseModel):
    name: str
    description: str
    args_model: type[BaseModel]
    fn: Callable[[BaseModel], dict]

    class Config:
        arbitrary_types_allowed = True


REGISTRY: dict[str, Tool] = {
    "calculator": Tool(
        name="calculator",
        description="Do one arithmetic operation. op is add|sub|mul|div.",
        args_model=CalcArgs, fn=calculator,   # type: ignore[arg-type]
    ),
    "lookup_order": Tool(
        name="lookup_order",
        description="Look up a customer order's status by id like 'C-42'.",
        args_model=LookupArgs, fn=lookup_order,  # type: ignore[arg-type]
    ),
}


def execute(name: str, raw_args: dict) -> dict:
    """The safety choke point. Validate name and args BEFORE running."""
    tool = REGISTRY.get(name)
    if tool is None:
        return {"error": f"unknown tool '{name}'"}     # never dispatch by faith
    try:
        args = tool.args_model.model_validate(raw_args)  # untrusted -> typed
    except ValidationError as e:
        return {"error": f"invalid arguments: {e}"}
    # Both tools here are read-only; a WRITE tool would require an
    # authorization check and/or human confirmation right here before fn().
    return tool.fn(args)
```

```python
# src/structured/loop.py
from __future__ import annotations
from .tools import REGISTRY, execute
# from llmclient import Message


def tool_specs() -> list[dict]:
    """What we advertise to the model — names, descriptions, arg schemas."""
    return [
        {"name": t.name, "description": t.description,
         "parameters": t.args_model.model_json_schema()}
        for t in REGISTRY.values()
    ]


async def run_with_tools(client, user_msg: str, *, max_steps: int = 5) -> str:
    """Loop: model may ask for tools; we validate+run and feed results back.
    ALWAYS bounded by max_steps so a confused model can't loop forever."""
    messages = [Message("user", user_msg)]
    for _ in range(max_steps):
        completion = await client.complete_with_tools(  # provider-specific
            messages, tools=tool_specs()
        )
        if completion.finish_reason != "tool_calls":
            return completion.text          # model is done
        for call in completion.tool_calls:  # name + raw JSON args
            result = execute(call.name, call.arguments)
            messages.append(Message("assistant", f"[called {call.name}]"))
            messages.append(Message("tool", str(result)))
    return "stopped: hit max tool steps"
```

`complete_with_tools`, `finish_reason`, and the `tool_calls` shape are provider-specific — this is the illustrative *pattern*. The load-bearing parts that are provider-independent and that you must not skip: `execute` validates the tool name and arguments before running anything, both tools are read-only, and the loop has a hard step cap.

### Tests

```python
# tests/test_tools.py
from structured.tools import execute


def test_valid_calculator_call():
    assert execute("calculator", {"op": "add", "a": 2, "b": 3}) == {"result": 5}


def test_rejects_unknown_tool():
    out = execute("rm_rf", {"path": "/"})
    assert "unknown tool" in out["error"]        # never dispatched


def test_rejects_bad_args():
    out = execute("lookup_order", {"order_id": "'; DROP TABLE orders; --"})
    assert "invalid arguments" in out["error"]   # tight pattern blocks it


def test_lookup_hit_and_miss():
    assert execute("lookup_order", {"order_id": "C-42"})["status"] == "shipped"
    assert execute("lookup_order", {"order_id": "C-99"})["status"] == "not_found"
```

```python
# tests/test_extract.py
import pytest
from structured.extract import Invoice


def test_invoice_validates_and_rejects():
    ok = Invoice.model_validate_json(
        '{"invoice_number":"INV-1","vendor":"Acme","total":10.0}'
    )
    assert ok.due_date is None and ok.total == 10.0

    with pytest.raises(Exception):
        Invoice.model_validate_json('{"invoice_number":"INV-1","total":-5}')
        # negative total (ge=0) and missing vendor both fail validation
```

Note the extraction tests don't call a model — they test the *validation contract*, which is the deterministic part. To test the full extract-with-repair loop, inject a `FakeClient` (project 04) that returns bad JSON first and good JSON on retry, and assert the loop recovers.

### Run it locally in Docker

```dockerfile
# projects/06-structured-output/Dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir uv
WORKDIR /app
COPY pyproject.toml ./
RUN uv pip install --system -e ".[dev]"
COPY . .
CMD ["python", "run.py"]
```

```yaml
# projects/06-structured-output/compose.yaml
services:
  ollama:
    image: ollama/ollama:latest
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]
  app:
    build: .
    environment:
      OLLAMA_BASE_URL: http://ollama:11434
      OLLAMA_MODEL: llama3.2
    depends_on: [ollama]
volumes:
  ollama:
```

```bash
cd projects/06-structured-output
docker compose up -d ollama
docker compose exec ollama ollama pull llama3.2
docker compose run --rm app pytest -q          # validation + tool tests, no network
docker compose run --rm app python run.py      # extract the sample invoice, then a tool query
```

> Note: not every small local model reliably follows JSON schemas or emits tool calls in the expected shape. If extraction flaps locally, that's a real lesson — it's why the repair-retry loop exists, and why you'll *evaluate* structured-output reliability (module 09) rather than assume it. A stronger hosted model behind the same `LlmClient` interface (module 04) usually behaves better.

### Moving to AWS

- **Bedrock's `Converse` API has a tool-use pattern** built in: you pass a `toolConfig` describing your tools (name, description, input JSON Schema), the model returns a `toolUse` block when it wants to call one, and you return a `toolResult` block — the same declare → call → execute → feed-back loop as above, just Bedrock's field names. Your `execute` choke point (validate name, validate args, authorize, run) is unchanged; only the transport differs, which is the payoff of having wrapped it behind your own interface.
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

## Checkpoint

You're ready for module 07 if you can:

- [ ] Explain why validated structured output makes a model a *component*, and name the three levels of output guarantee.
- [ ] Define a pydantic model, generate its JSON Schema, and validate untrusted JSON against it.
- [ ] Implement a validate-and-repair loop that feeds the validation error back, with a capped number of attempts.
- [ ] Describe the tool-calling loop (declare → call → validate → execute → feed back → repeat) and where the step cap goes.
- [ ] Explain the reflection/RPC analogy *and* why the caller must be treated as untrusted.
- [ ] State the difference between validating arguments and authorizing an action, and why read-only tools come first.
- [ ] Point to the single choke point in your code where tool name + arguments are validated before execution.

## Going deeper

- pydantic docs: models, `Field` constraints, `model_validate` / `model_validate_json`, and JSON Schema generation.
- Your provider's docs for the *current* structured-output modes (JSON mode vs schema-constrained decoding) and the exact tool-calling / function-calling request and response shapes — these differ and evolve, so don't hardcode from memory.
- Amazon Bedrock `Converse` API tool-use documentation for when you deploy in module 12.
- The concept of "constrained decoding" / grammar-based generation (how open-source servers force schema conformance at the token level) — module 10 territory.
- Forward reference: [08 — Agents & orchestration](08-agents-and-orchestration.md), which is this tool-calling loop grown up — multi-step planning, memory, and knowing when *not* to build an agent.

Next: [07 — Retrieval-augmented generation (RAG)](07-retrieval-augmented-generation.md).
