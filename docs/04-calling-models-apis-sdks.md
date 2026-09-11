# 04 — Calling models: APIs & SDKs

> **Background.** You're a senior/staff .NET engineer becoming an AI engineer. You already know how to call a flaky HTTP dependency well — `HttpClient` with sane timeouts, Polly for retries and circuit breakers, `IAsyncEnumerable` for streaming, an interface so you can swap the backend. A hosted LLM is exactly that kind of dependency: a slow, expensive, occasionally-rate-limited network call that streams. This module is about calling it *correctly*, which turns out to be 90% engineering you already know and 10% LLM-specific accounting (tokens and cost). Specific model names, prices, and exact request shapes age fast — treat the ones here as illustrative and check current provider docs before you pin anything.

## Where this fits

**Prerequisites:** [01 — Python for .NET engineers](01-python-for-dotnet-engineers.md) (uv, typing, pytest), [02 — The AI engineering landscape](02-ai-engineering-landscape.md) (where "calling a model" sits in a system), [03 — LLM fundamentals](03-llm-fundamentals-for-engineers.md) (tokens, context window, sampling — you need these to reason about cost and truncation here).

**Outcomes:** after this you can call a hosted model and a local model behind one interface, stream tokens, survive rate limits and timeouts with backoff, run many requests concurrently, and log tokens and dollars per call. You'll have a small, tested `LlmClient` package you reuse in every later module.

## The chat completions request/response shape

Almost every hosted chat model today speaks a variant of the same shape. You send a list of **messages**, each with a **role** and **content**:

- `system` — standing instructions ("You are a terse assistant that answers in JSON"). Think of it as configuration/policy, separate from the request payload.
- `user` — what the human said this turn.
- `assistant` — what the model said on previous turns (you replay history back to it; the API is stateless — see below).
- sometimes `tool` — results you fed back after the model asked to call a function (module 06).

```python
messages = [
    {"role": "system", "content": "You are a terse assistant."},
    {"role": "user", "content": "Name three primary colors."},
]
```

The response comes back with the assistant's message plus **usage** (token counts) and a **finish reason** ("stop" = it finished, "length" = it hit the max-tokens cap and was cut off, "tool_calls" = it wants to call a function). Watch finish reason like you'd watch an HTTP status code: "length" means your output was truncated and you probably need a bigger cap or a shorter prompt.

**The API is stateless.** This is the single biggest surprise for people used to session objects. There is no server-side conversation. Every turn, *you* resend the entire message history. "Memory" is a client-side concern — you own the transcript, you decide what to keep, and every token you resend you pay for again. This is why context management (module 03) and later summarization matter for cost.

### .NET analogy

A message list is like building an HTTP request body by hand; the roles are metadata channels, not magic. The statelessness is like calling a REST endpoint that takes the full state each time — closer to a pure function `f(history) -> next_message` than to a stateful `HttpClient` with cookies.

## Streaming vs non-streaming

Non-streaming: you `await` and get the whole response. Simple, and correct for batch jobs, extraction, anything where a human isn't watching characters appear.

Streaming: the server sends tokens as they're generated (typically Server-Sent Events under the hood). You consume an async iterator of chunks and assemble them. This is **`IAsyncEnumerable<string>`**, essentially exactly — same reasons (perceived latency, showing progress), same gotchas (you must handle the stream ending early, and errors can arrive mid-stream after you've already shown partial output).

```python
# Illustrative — check your provider SDK's exact streaming API.
async def stream_reply(client, messages) -> AsyncIterator[str]:
    async with client.chat_stream(messages=messages) as stream:
        async for chunk in stream:
            delta = chunk.delta_text  # provider-specific field
            if delta:
                yield delta
```

Two rules that save you pain:
1. **Accumulate as you go.** Keep the full assembled string, because you'll want to log it, validate it, and store it in history after the stream ends.
2. **Streaming does not reduce cost or total latency** — it reduces *time to first token*. The model does the same work. Don't stream a background batch job just because you can; it complicates error handling for no user-facing benefit.

## Timeouts, retries, idempotency, rate limits

This is where your Polly instincts pay off directly. LLM endpoints fail in familiar ways plus a couple of new ones.

- **Timeouts.** Set them explicitly and generously — a long generation can legitimately take 30–90s, far longer than a typical REST call. But do set them; the default in some SDKs is effectively "wait forever," which will hang your batch. Separate the *connect* timeout from the *read/total* timeout if the SDK allows.
- **429 Too Many Requests / rate limits.** Providers cap you on requests-per-minute *and* tokens-per-minute. When you exceed either you get a 429, often with a `Retry-After` header. Honor it. This is the LLM-specific twist: you can be under the request limit but over the token limit because your prompts are huge.
- **Retries with backoff.** Retry on 429 and 5xx and connection errors, with **exponential backoff and jitter** — identical to a Polly retry policy. Do *not* retry on 4xx like 400 (malformed request) or 401 (bad key); those won't get better.
- **Idempotency.** LLM calls are non-deterministic by default (sampling), so a naive retry can bill you twice for two different answers. Some providers support an idempotency key so a retried request returns the same result rather than re-running. Where available, use it — same reasoning as an idempotency key on a payments API.

```python
# Illustrative backoff loop. In real code prefer a library like `tenacity`
# (the Polly of Python) rather than hand-rolling this.
import asyncio, random

RETRYABLE = {429, 500, 502, 503, 504}

async def with_backoff(call, *, max_attempts=5, base=0.5, cap=30.0):
    for attempt in range(max_attempts):
        try:
            return await call()
        except TransientError as e:  # your wrapper's classified error
            if e.status not in RETRYABLE or attempt == max_attempts - 1:
                raise
            # honor Retry-After if present, else exponential backoff + jitter
            delay = e.retry_after or min(cap, base * 2**attempt)
            delay += random.uniform(0, delay * 0.25)  # jitter
            await asyncio.sleep(delay)
```

> **Pythonism flag.** `tenacity` gives you Polly-style declarative retries (`@retry(wait=wait_exponential_jitter(), stop=stop_after_attempt(5))`). For real HTTP, `httpx` is the `HttpClient` equivalent and does async natively. Prefer these over hand-rolling — the sample above is to show the mechanism.

## Handling partial / streamed output

When you stream, a failure can happen *after* the user has seen half an answer. Decide the policy up front, the way you'd decide how a partially-written response stream behaves in ASP.NET:

- For a chat UI, show what arrived and append an error note; don't silently drop it.
- For anything you validate (JSON, module 06), only parse/validate the **fully assembled** string, never a chunk.
- If a stream dies mid-way, a retry restarts generation from scratch — the model has no idea what it already emitted. You cannot "resume" a generation.

## Token accounting & cost logging per call

This is the genuinely new discipline. Every call has a cost you can and must compute:

- The response's `usage` reports **prompt tokens** (input) and **completion tokens** (output), usually billed at *different* per-token rates (output is typically pricier).
- Cost = `prompt_tokens * input_rate + completion_tokens * output_rate`. Rates are per-token (often quoted per million tokens); they change, so keep them in config, not hardcoded.
- Log, per call: model name, prompt tokens, completion tokens, computed cost, latency, and finish reason. This is your `ILogger` structured-logging discipline applied to money. Without it you cannot answer "why did last night's batch cost $40," which *will* be asked.

Treat cost like latency: a first-class metric you emit on every call and can aggregate. Module 13 builds real cost control on top of exactly this logging.

## Async concurrency for batching

If you have 500 documents to classify, calling them one at a time wastes the fact that the bottleneck is a remote server, not your CPU. Fire many concurrent requests — but **bounded**, or you'll trip the rate limit instantly.

The idiom is a semaphore around your calls — a `SemaphoreSlim` by another name:

```python
import asyncio

async def classify_all(client, docs: list[str], *, concurrency: int = 8):
    sem = asyncio.Semaphore(concurrency)

    async def one(doc: str):
        async with sem:
            return await client.complete(
                messages=[{"role": "user", "content": doc}]
            )

    return await asyncio.gather(*(one(d) for d in docs))
```

> **Pythonism flag.** `asyncio.gather` runs coroutines concurrently on *one* thread via the event loop — it's I/O concurrency, not parallelism (recall the GIL from module 01). That's exactly right here: you're waiting on the network, not burning CPU. Tune `concurrency` to stay under the provider's requests-per-minute and tokens-per-minute limits; start low (4–8) and raise it while watching for 429s.

## Provider abstraction: wrap the SDK behind your own interface

You would never scatter `new SqlConnection(...)` across a codebase; you'd hide it behind a repository interface. Do the same here. **Define your own `LlmClient` and depend on that**, not on a vendor SDK, everywhere in your app.

Why this matters more for LLMs than for most dependencies:
- **The market moves weekly.** New providers, new models, price cuts. If your app depends on one SDK's exact types, switching is a rewrite.
- **You'll want a fake for tests.** Real calls are slow, costly, and non-deterministic — poison for unit tests. An interface lets you inject a fake that returns canned responses (see the tests below).
- **Local vs hosted is just a different implementation.** Same interface, different backend — you can develop offline against a local model and flip to hosted in prod.

In Python the lightweight equivalent of a C# interface is `typing.Protocol` — structural typing, so an implementation doesn't have to explicitly inherit it (duck typing that the type checker enforces).

## Local models via an OpenAI-compatible endpoint (Ollama)

You don't need a GPU cluster to develop. **Ollama** runs open models locally and exposes an **OpenAI-compatible HTTP endpoint**, so the *same* request/response shape works against `http://localhost:11434`. That means "hosted" and "local" can be two implementations of your one interface, differing only in base URL, auth, and model name.

This is a big deal for the learn-by-building method: you can iterate offline, for free, with no rate limits, then swap to a hosted model for quality. Module 10 goes deep on serving open models; here we just use Ollama as a swappable backend.

## The build project

**`projects/04-llm-client/`** — a small typed Python package exposing an `LlmClient` protocol with two implementations (a hosted provider and a local Ollama endpoint), with retry/backoff, streaming, timeouts, and per-call token/cost logging, plus pytest tests using a fake client. Dockerized.

### Layout

```
projects/04-llm-client/
├── pyproject.toml
├── Dockerfile
├── compose.yaml
├── .env.example
├── src/llmclient/
│   ├── __init__.py
│   ├── types.py         # Message, Completion, Usage, protocol
│   ├── costs.py         # token → dollars, rates from config
│   ├── hosted.py        # hosted-provider implementation
│   ├── ollama.py        # local OpenAI-compatible implementation
│   └── retry.py         # backoff wrapper
├── tests/
│   ├── test_costs.py
│   └── test_client.py   # uses a FakeClient — no network
└── demo.py
```

### The interface and core types

```python
# src/llmclient/types.py
from __future__ import annotations
from dataclasses import dataclass
from typing import AsyncIterator, Protocol, Literal, Sequence

Role = Literal["system", "user", "assistant", "tool"]


@dataclass(frozen=True)
class Message:
    role: Role
    content: str


@dataclass(frozen=True)
class Usage:
    prompt_tokens: int
    completion_tokens: int


@dataclass(frozen=True)
class Completion:
    text: str
    usage: Usage
    model: str
    finish_reason: str
    cost_usd: float


class LlmClient(Protocol):
    """Your own boundary. App code depends on THIS, never on a vendor SDK."""

    async def complete(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> Completion: ...

    def stream(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> AsyncIterator[str]: ...
```

> **Pythonism flag.** `@dataclass(frozen=True)` is Python's immutable value type — the rough equivalent of a C# `record`. `Protocol` is a structural interface: `FakeClient`, `HostedClient`, and `OllamaClient` satisfy `LlmClient` just by having the right methods; no `: LlmClient` inheritance needed, and mypy/pyright still check it.

### Cost accounting

```python
# src/llmclient/costs.py
from dataclasses import dataclass
from .types import Usage


@dataclass(frozen=True)
class Rates:
    """Per-MILLION-token prices. These change constantly — load from config,
    never trust a value hardcoded here. Numbers below are placeholders."""
    input_per_mtok: float
    output_per_mtok: float


def cost_usd(usage: Usage, rates: Rates) -> float:
    return (
        usage.prompt_tokens / 1_000_000 * rates.input_per_mtok
        + usage.completion_tokens / 1_000_000 * rates.output_per_mtok
    )
```

### A backoff wrapper

```python
# src/llmclient/retry.py
import asyncio, random
from typing import Awaitable, Callable, TypeVar

T = TypeVar("T")


class TransientError(Exception):
    def __init__(self, status: int, retry_after: float | None = None):
        super().__init__(f"transient {status}")
        self.status = status
        self.retry_after = retry_after


RETRYABLE = {429, 500, 502, 503, 504}


async def with_backoff(
    call: Callable[[], Awaitable[T]],
    *, max_attempts: int = 5, base: float = 0.5, cap: float = 30.0,
) -> T:
    for attempt in range(max_attempts):
        try:
            return await call()
        except TransientError as e:
            if e.status not in RETRYABLE or attempt == max_attempts - 1:
                raise
            delay = e.retry_after or min(cap, base * 2**attempt)
            delay += random.uniform(0, delay * 0.25)
            await asyncio.sleep(delay)
    raise AssertionError("unreachable")
```

### The local (Ollama) implementation — illustrative

```python
# src/llmclient/ollama.py
import time
import httpx
from typing import AsyncIterator, Sequence
from .types import Completion, LlmClient, Message, Usage
from .costs import Rates, cost_usd
from .retry import TransientError, with_backoff

# Local models are free to run, so rates are zero — but we still log usage.
LOCAL_RATES = Rates(input_per_mtok=0.0, output_per_mtok=0.0)


class OllamaClient:
    """Talks to Ollama's OpenAI-compatible endpoint. Same shape as hosted."""

    def __init__(self, base_url: str, model: str, timeout: float = 90.0):
        self._client = httpx.AsyncClient(base_url=base_url, timeout=timeout)
        self._model = model

    async def complete(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> Completion:
        payload = {
            "model": self._model,
            "messages": [{"role": m.role, "content": m.content} for m in messages],
            "max_tokens": max_tokens,
            "stream": False,
        }

        async def call() -> Completion:
            t0 = time.perf_counter()
            resp = await self._client.post("/v1/chat/completions", json=payload)
            if resp.status_code in {429, 500, 502, 503, 504}:
                ra = resp.headers.get("retry-after")
                raise TransientError(resp.status_code, float(ra) if ra else None)
            resp.raise_for_status()
            data = resp.json()
            # Field names below follow the OpenAI-compatible schema.
            usage = Usage(
                prompt_tokens=data["usage"]["prompt_tokens"],
                completion_tokens=data["usage"]["completion_tokens"],
            )
            choice = data["choices"][0]
            latency_ms = (time.perf_counter() - t0) * 1000
            print(  # replace with structured logging in real code
                f"model={self._model} in={usage.prompt_tokens} "
                f"out={usage.completion_tokens} latency_ms={latency_ms:.0f}"
            )
            return Completion(
                text=choice["message"]["content"],
                usage=usage,
                model=self._model,
                finish_reason=choice.get("finish_reason", "stop"),
                cost_usd=cost_usd(usage, LOCAL_RATES),
            )

        return await with_backoff(call)

    async def stream(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> AsyncIterator[str]:
        payload = {
            "model": self._model,
            "messages": [{"role": m.role, "content": m.content} for m in messages],
            "max_tokens": max_tokens,
            "stream": True,
        }
        async with self._client.stream(
            "POST", "/v1/chat/completions", json=payload
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                # SSE lines look like: "data: {json}" / "data: [DONE]"
                if not line.startswith("data: "):
                    continue
                body = line.removeprefix("data: ").strip()
                if body == "[DONE]":
                    break
                import json
                delta = json.loads(body)["choices"][0]["delta"].get("content")
                if delta:
                    yield delta


_: LlmClient = OllamaClient(base_url="http://x", model="y")  # type: ignore[assignment]
# ^ a quick structural-typing sanity check that OllamaClient satisfies LlmClient
```

The hosted implementation (`hosted.py`) is the same shape with a different base URL, an `Authorization` header from an env var / SSM (never hardcoded), a real model name, and real rates from config. The point of the interface is that *nothing else in your code notices which one it's using.*

### Tests with a fake — no network

```python
# tests/test_client.py
import pytest
from llmclient.types import Completion, Message, Usage


class FakeClient:
    """Canned responses. Fast, deterministic, free — the whole reason
    we hid the SDK behind a protocol."""

    def __init__(self, reply: str = "ok"):
        self.reply = reply
        self.calls: list[list[Message]] = []

    async def complete(self, messages, *, max_tokens=512) -> Completion:
        self.calls.append(list(messages))
        return Completion(
            text=self.reply,
            usage=Usage(prompt_tokens=10, completion_tokens=3),
            model="fake",
            finish_reason="stop",
            cost_usd=0.0,
        )


@pytest.mark.asyncio
async def test_complete_records_history():
    client = FakeClient(reply="blue, red, yellow")
    result = await client.complete([Message("user", "colors?")])
    assert result.text == "blue, red, yellow"
    assert client.calls[0][0].content == "colors?"
```

> **Pythonism flag.** `pytest` is xUnit-flavored but leaner: plain functions named `test_*`, bare `assert` (the plugin rewrites it to show a rich diff), fixtures instead of constructor setup. `pytest-asyncio` + `@pytest.mark.asyncio` lets you `await` inside a test.

### Run it locally in Docker

```dockerfile
# projects/04-llm-client/Dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 UV_SYSTEM_PYTHON=1
RUN pip install --no-cache-dir uv
WORKDIR /app
COPY pyproject.toml ./
RUN uv pip install --system -e ".[dev]"
COPY . .
CMD ["python", "demo.py"]
```

```yaml
# projects/04-llm-client/compose.yaml
services:
  ollama:
    image: ollama/ollama:latest
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: .
    environment:
      LLM_BACKEND: ollama
      OLLAMA_BASE_URL: http://ollama:11434
      OLLAMA_MODEL: llama3.2   # example; pull whatever you have
    depends_on: [ollama]

volumes:
  ollama:
```

Steps:

```bash
cd projects/04-llm-client
cp .env.example .env                       # fill in a hosted key if you have one
docker compose up -d ollama
docker compose exec ollama ollama pull llama3.2   # one-time model download
docker compose run --rm app                # runs demo.py against local Ollama
docker compose run --rm app pytest -q      # tests need no network
```

Flip `LLM_BACKEND=hosted` in `.env` and the *same* `demo.py` runs against the hosted provider — the payoff of the interface.

### Moving to AWS

- **Bedrock is just another backend.** Amazon Bedrock exposes many models through one API (its `Converse` API normalizes the request shape across model families — convenient, since it's already provider-agnostic). Write a `BedrockClient` that satisfies your `LlmClient` protocol and you can point prod at Bedrock without touching app code. The `boto3` SDK handles AWS auth via the standard credential chain.
- **Secrets.** Locally, keys live in `.env` (git-ignored). On AWS, don't ship keys in env vars in plaintext — pull them from **SSM Parameter Store** (SecureString) or **Secrets Manager** at startup, and give the task an IAM role instead of long-lived keys where possible. This is the same "config vs secrets" split you already enforce in .NET.
- **Timeouts and retries still apply.** `boto3` has its own retry config; set it deliberately rather than trusting defaults, same as everywhere else.

## How experts think / pitfalls

- **The API is stateless; you own the transcript.** Forgetting this leads to "why doesn't it remember?" bugs and surprise bills from resending huge histories.
- **Watch `finish_reason`.** Silent truncation at "length" produces confident, incomplete answers and invalid JSON. It's the LLM equivalent of an unchecked `Content-Length`.
- **Bound your concurrency.** Unbounded `gather` over 1000 prompts is a self-inflicted DDoS that returns a wall of 429s. Semaphore always.
- **Retries can double-bill.** Non-determinism means a retry after a mid-stream failure can produce a *different* answer you also pay for. Use idempotency keys where offered; cap attempts.
- **Log cost from day one.** Retrofitting cost accounting after a scary bill is painful; emit tokens and dollars on every call now.
- **Don't leak the vendor SDK past your interface.** The one place you import the vendor package should be inside your implementation class. Everything else sees `LlmClient`.
- **Local ≠ hosted quality.** Ollama is perfect for wiring, tests, and offline iteration; a small local model may answer worse than a frontier hosted one. Develop local, evaluate (module 09) before trusting either in prod.

## Checkpoint

You're ready for module 05 if you can:

- [ ] Explain why the chat API is stateless and what that means for cost and memory.
- [ ] Distinguish streaming from non-streaming and say what streaming does and does *not* improve.
- [ ] List which HTTP statuses you retry, which you don't, and why backoff needs jitter.
- [ ] Explain the token-per-minute vs request-per-minute distinction behind a 429.
- [ ] Compute the dollar cost of a call from its input/output token usage.
- [ ] Batch N requests with bounded concurrency and say why the bound matters.
- [ ] Justify wrapping the vendor SDK behind your own `Protocol`, and swap hosted ↔ Ollama without touching app code.
- [ ] Write a `FakeClient` and a pytest test that runs with no network.

## Going deeper

- The `httpx` docs on async clients, timeouts, and streaming responses — your `HttpClient` reference here.
- `tenacity` for declarative retry/backoff (the Polly analogue).
- Your provider's API reference for the *exact* current request/response fields, streaming format, rate-limit headers, and idempotency support — do not trust the illustrative shapes above.
- Ollama's docs on its OpenAI-compatible endpoint and model catalog.
- Amazon Bedrock's `Converse` API docs when you get to module 12.
- Provider "prompt caching" features (caching a large stable prefix to cut input cost) — a real lever revisited in module 13.

Next: [05 — Prompt engineering as engineering](05-prompt-engineering-as-engineering.md).
