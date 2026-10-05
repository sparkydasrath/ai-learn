# 04 — Calling models: APIs & SDKs

> **Background.** You're a senior/staff .NET engineer becoming an AI engineer. You already know how to call a flaky HTTP dependency well — `HttpClient` with sane timeouts, Polly for retries and circuit breakers, `IAsyncEnumerable` for streaming, an interface so you can swap the backend. A hosted LLM is exactly that kind of dependency: a slow, expensive, occasionally-rate-limited network call that streams. This module is about calling it *correctly*, which turns out to be 90% engineering you already know and 10% LLM-specific accounting (tokens and cost). Specific model names, prices, and exact request shapes age fast — treat the ones here as illustrative and check current provider docs before you pin anything.

## Where this fits

**Prerequisites:** [01 — Python for .NET engineers](01-python-for-dotnet-engineers.md) (uv, typing, pytest), [02 — The AI engineering landscape](02-ai-engineering-landscape.md) (where "calling a model" sits in a system), [03 — LLM fundamentals](03-llm-fundamentals-for-engineers.md) (tokens, context window, sampling — you need these to reason about cost and truncation here).

**Outcomes:** after this you can call a hosted model and a local model behind one interface, stream tokens, survive rate limits and timeouts with backoff, run many requests concurrently, and log tokens and dollars per call. You'll have a small, tested `LlmClient` package you reuse in every later module. You'll also build the same client in C#, where `Microsoft.Extensions.AI` already provides the interface, and be able to say what you gain and give up by adopting it instead of writing your own.

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

In .NET the shape is literal. `Microsoft.Extensions.AI`'s `IChatClient.GetStreamingResponseAsync` returns `IAsyncEnumerable<ChatResponseUpdate>`:

```csharp
var text = new StringBuilder();
await foreach (ChatResponseUpdate update in chat.GetStreamingResponseAsync(messages, cancellationToken: ct))
{
    Console.Write(update.Text);
    text.Append(update.Text);   // rule 1 below: accumulate as you go
}
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

In .NET you don't hand-roll it either. `Microsoft.Extensions.Http.Resilience` (Polly v8 underneath) adds a standard pipeline to a named `HttpClient`: retry with exponential backoff and jitter, `Retry-After` support, a circuit breaker, and timeouts.

```csharp
services.AddHttpClient("llm")
    .AddStandardResilienceHandler(o =>
    {
        o.Retry.MaxRetryAttempts = 4;
        o.AttemptTimeout.Timeout = TimeSpan.FromSeconds(90);          // default is 10 s
        o.TotalRequestTimeout.Timeout = TimeSpan.FromMinutes(5);      // default is 30 s
        o.CircuitBreaker.SamplingDuration = TimeSpan.FromMinutes(3);  // must be >= 2x attempt timeout
    });
```

The defaults are tuned for ordinary REST calls. A 10-second attempt timeout kills a long generation on every attempt, and then retries it. Set them deliberately.

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

**In .NET, the interface already exists.** `Microsoft.Extensions.AI` (MEAI) defines `IChatClient`, plus the types around it: `ChatMessage`, `ChatOptions`, `ChatResponse` (with `.Text`, `.Usage`, `.FinishReason`). Providers ship adapters (OllamaSharp's `OllamaApiClient` implements it directly; OpenAI and Bedrock have adapter packages). So in C# you depend on `IChatClient` the way you depend on `ILogger` rather than on Serilog. The trade-off:

- **You get:** adapters for many providers, a middleware pipeline (`ChatClientBuilder`, with built-in logging, OpenTelemetry, caching and function invocation), and a vocabulary other .NET libraries already speak.
- **You give up:** control of the shape. It's a lowest common denominator. Provider-specific features go through `AdditionalProperties` or `RawRepresentation`, and the package versions on Microsoft's schedule, not yours.

If your app needs a narrower contract (say, `ITicketClassifier`), define that interface *on top of* `IChatClient`, not instead of it.

## Local models via an OpenAI-compatible endpoint (Ollama)

You don't need a GPU cluster to develop. **Ollama** runs open models locally and exposes an **OpenAI-compatible HTTP endpoint**, so the *same* request/response shape works against `http://localhost:11434`. That means "hosted" and "local" can be two implementations of your one interface, differing only in base URL, auth, and model name.

This is a big deal for the learn-by-building method: you can iterate offline, for free, with no rate limits, then swap to a hosted model for quality. Module 10 goes deep on serving open models; here we just use Ollama as a swappable backend.

## The build project

**`projects/04-llm-client/`** is a reusable model client, built in Python and then in C#. Both versions:

1. Call a local Ollama model, a hosted provider, or an offline **stub**, behind one interface, picked by `LLM_BACKEND`.
2. Stream tokens as well as returning whole responses.
3. Retry 429s and 5xx with backoff and jitter, and set timeouts deliberately.
4. Log tokens, dollars, latency, and finish reason on every call.
5. Run their tests with no network: against a fake server under the client, and against the stub.

The Python version is a small typed package with its own `LlmClient` protocol. The C# version doesn't write the interface. It adopts `IChatClient` from `Microsoft.Extensions.AI` and adds the cost logging as middleware. **Every later module reuses this project** rather than writing its own model code: Python through a uv path dependency, C# through a `ProjectReference` to the `LlmClient` class library ([backend contract](adr/001-backend-contract.md)).

The `stub` backend deserves a word. It isn't a model; it's a deterministic stand-in that replies `stub: <your last message>` (or a fixed `LLM_STUB_REPLY`) and counts words as tokens. Tests, CI and every cross-check from here to module 17 run on it, so they're fast, free and offline. Both languages implement it to the same rules, which makes it a parity test too: same input, byte-identical output.

### Layout

```
projects/04-llm-client/
├── python/
│   ├── pyproject.toml
│   ├── uv.lock                  # committed: pins exact dependency versions
│   ├── Dockerfile
│   ├── Dockerfile.dockerignore  # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example             # committed; copy to .env (git-ignored)
│   ├── README.md
│   ├── demo.py
│   ├── src/llm_client/
│   │   ├── __init__.py
│   │   ├── types.py             # Message, Usage, Completion, the LlmClient protocol
│   │   ├── costs.py             # token → dollars; the llm_call log line
│   │   ├── retry.py             # backoff wrapper
│   │   ├── openai_compat.py     # the HTTP client: any OpenAI-compatible server
│   │   ├── ollama.py            # local models: OpenAICompatibleClient at <root>/v1, free
│   │   ├── hosted.py            # hosted provider: + API key, + real rates
│   │   ├── stub.py              # LLM_BACKEND=stub: deterministic, offline
│   │   └── factory.py           # client_from_env(): picks the backend from LLM_BACKEND
│   └── tests/
│       ├── test_costs.py
│       ├── test_client.py       # a fake server UNDER the client: URLs, headers, retries, streaming
│       └── test_stub.py         # the stub and the factory
└── csharp/
    ├── LlmClient.slnx
    ├── Directory.Build.props
    ├── Dockerfile
    ├── Dockerfile.dockerignore              # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   ├── LlmClient/                       # class library: what later modules reference
    │   │   ├── LlmClient.csproj
    │   │   ├── Rates.cs                     # token → dollars (decimal), rates from config
    │   │   ├── LlmResilience.cs             # retry/timeout policy, the retry.py twin
    │   │   ├── CostLoggingChatClient.cs     # IChatClient middleware: tokens, $, latency
    │   │   ├── StubChatClient.cs            # the stub.py twin
    │   │   ├── Batch.cs                     # bounded concurrency
    │   │   └── ServiceCollectionExtensions.cs  # AddLlmClient(): picks the backend
    │   └── LlmClient.Demo/                  # console app: the demo.py twin
    │       ├── LlmClient.Demo.csproj
    │       └── Program.cs
    └── tests/
        └── LlmClient.Tests/
            ├── LlmClient.Tests.csproj       # NUnit
            ├── FakeChatClient.cs
            ├── CostTests.cs
            ├── ClientTests.cs
            ├── ResilienceTests.cs
            └── StubTests.cs
```

There is no `types.py`, `openai_compat.py` or `ollama.py` counterpart on the C# side. MEAI supplies the types, OllamaSharp the Ollama client, and the OpenAI SDK the hosted one.

## Python implementation

Work in `projects/04-llm-client/python/`. It's a [library](conventions.md#python-project-shapes), because later modules import it. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 04-llm-client
cd projects/04-llm-client/python
uv add httpx
uv add --dev pytest-asyncio
```

The script names the package `llm-client`, so the import name is `llm_client`. `uv init` also writes a hello-world `main()` into `src/llm_client/__init__.py`, plus a `[project.scripts]` table that runs it. This is a library, not a command-line tool, so delete both: empty the `__init__.py`, and remove the `[project.scripts]` table from `pyproject.toml`. Delete the scaffold's `tests/test_smoke.py` once the real tests below exist.

### The interface and core types

```python
# src/llm_client/types.py
from __future__ import annotations

from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from typing import Literal, Protocol

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

> **Pythonism flag.** `@dataclass(frozen=True)` is Python's immutable value type — the rough equivalent of a C# `record`. `Protocol` is a structural interface: `OllamaClient`, `HostedClient` and `StubClient` satisfy `LlmClient` just by having the right methods; no `: LlmClient` inheritance needed, and mypy/pyright still check it.

### Cost accounting, and the log line

```python
# src/llm_client/costs.py
import sys
from dataclasses import dataclass

from .types import Usage


@dataclass(frozen=True)
class Rates:
    """Per-MILLION-token prices. These change constantly: load them from config,
    never trust a value hardcoded here."""

    input_per_mtok: float
    output_per_mtok: float


FREE = Rates(0.0, 0.0)  # local and stub models cost nothing to run, but usage is still logged


def cost_usd(usage: Usage, rates: Rates) -> float:
    return (
        usage.prompt_tokens / 1_000_000 * rates.input_per_mtok
        + usage.completion_tokens / 1_000_000 * rates.output_per_mtok
    )


def log_call(model: str, usage: Usage, cost: float, latency_ms: float, finish: str) -> None:
    """One line per model call, on stderr like any log, so stdout stays the answer.
    Same fields, order and number formats as the C# CostLoggingChatClient, so the
    two sides' lines diff cleanly."""
    print(  # use structured logging in real code
        f"llm_call model={model} in={usage.prompt_tokens} out={usage.completion_tokens} "
        f"cost_usd={cost:.6f} latency_ms={latency_ms:.0f} finish={finish}",
        file=sys.stderr,
        flush=True,
    )
```

The log line goes to **stderr**, like any log. That keeps stdout for the answer, so `demo.py > answer.txt` captures only the answer. The C# demo does the same.

### A backoff wrapper

```python
# src/llm_client/retry.py
import asyncio
import random
from collections.abc import Awaitable, Callable
from typing import TypeVar

T = TypeVar("T")

RETRYABLE = {429, 500, 502, 503, 504}


class TransientError(Exception):
    def __init__(self, status: int, retry_after: float | None = None):
        super().__init__(f"transient {status}")
        self.status = status
        self.retry_after = retry_after


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

### The HTTP client

Ollama, most hosted providers and servers like vLLM all speak the same OpenAI chat-completions shape. So one class does the HTTP work, and the backends differ only in base URL, key and rates:

```python
# src/llm_client/openai_compat.py
import json
import time
from collections.abc import AsyncIterator, Sequence
from typing import Any

import httpx

from .costs import Rates, cost_usd, log_call
from .retry import RETRYABLE, TransientError, with_backoff
from .types import Completion, Message, Usage


class OpenAICompatibleClient:
    """Any server that speaks the OpenAI chat-completions shape: Ollama, most hosted
    providers, vLLM. base_url INCLUDES /v1, e.g. https://api.openai.com/v1."""

    def __init__(
        self,
        base_url: str,
        model: str,
        rates: Rates,
        *,
        api_key: str | None = None,
        temperature: float | None = None,  # None: the server's default
        timeout: float = 90.0,
        transport: httpx.AsyncBaseTransport | None = None,  # tests pass a MockTransport
    ):
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.AsyncClient(
            base_url=base_url, headers=headers, timeout=timeout, transport=transport
        )
        self._model = model
        self._rates = rates
        self._temperature = temperature

    def _payload(self, messages: Sequence[Message], max_tokens: int, stream: bool) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self._model,
            "messages": [{"role": m.role, "content": m.content} for m in messages],
            "max_tokens": max_tokens,
            "stream": stream,
        }
        if self._temperature is not None:
            payload["temperature"] = self._temperature
        if stream:
            payload["stream_options"] = {"include_usage": True}  # usage arrives on the last chunk
        return payload

    async def _send(self, payload: dict[str, Any], stream: bool) -> httpx.Response:
        # A relative path keeps base_url's /v1: httpx joins "chat/completions" onto it.
        request = self._client.build_request("POST", "chat/completions", json=payload)
        response = await self._client.send(request, stream=stream)
        if response.status_code in RETRYABLE:
            retry_after = response.headers.get("retry-after")
            await response.aclose()
            raise TransientError(response.status_code, float(retry_after) if retry_after else None)
        if response.is_error:
            await response.aread()  # load the body so the error message can include it
            response.raise_for_status()
        return response

    async def complete(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> Completion:
        payload = self._payload(messages, max_tokens, stream=False)
        t0 = time.perf_counter()
        response = await with_backoff(lambda: self._send(payload, stream=False))
        data = response.json()
        usage = Usage(
            prompt_tokens=data["usage"]["prompt_tokens"],
            completion_tokens=data["usage"]["completion_tokens"],
        )
        choice = data["choices"][0]
        finish = choice.get("finish_reason") or "stop"
        cost = cost_usd(usage, self._rates)
        log_call(self._model, usage, cost, (time.perf_counter() - t0) * 1000, finish)
        return Completion(
            text=choice["message"]["content"],
            usage=usage,
            model=self._model,
            finish_reason=finish,
            cost_usd=cost,
        )

    async def stream(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> AsyncIterator[str]:
        payload = self._payload(messages, max_tokens, stream=True)
        t0 = time.perf_counter()
        # Retry only until the stream opens. Once tokens flow, a retry would replay
        # (and re-bill) a different answer, so mid-stream failures propagate.
        response = await with_backoff(lambda: self._send(payload, stream=True))
        usage, finish = Usage(0, 0), "stop"
        try:
            async for line in response.aiter_lines():
                # Server-sent events: "data: {json}" lines, ending with "data: [DONE]".
                if not line.startswith("data: "):
                    continue
                body = line.removeprefix("data: ").strip()
                if body == "[DONE]":
                    break
                chunk = json.loads(body)
                if chunk.get("usage"):
                    usage = Usage(chunk["usage"]["prompt_tokens"], chunk["usage"]["completion_tokens"])
                for choice in chunk.get("choices", []):
                    finish = choice.get("finish_reason") or finish
                    if delta := choice.get("delta", {}).get("content"):
                        yield delta
        finally:
            await response.aclose()
        log_call(self._model, usage, cost_usd(usage, self._rates), (time.perf_counter() - t0) * 1000, finish)
```

Five details are worth slowing down for:

- **`base_url` includes `/v1`** and the request path is relative (`"chat/completions"`, no leading slash). httpx then joins it onto the base path instead of replacing it, so `https://api.example.com/v1` becomes `https://api.example.com/v1/chat/completions`.
- **Streaming retries only until the stream opens.** Once tokens are flowing, a retry would replay the call, and you'd pay for a *different* answer. So mid-stream failures propagate to the caller.
- **Streamed usage needs asking for.** `stream_options.include_usage` makes the server send token counts on a final chunk. A server that ignores it leaves usage at zero, and the log line shows that honestly rather than guessing.
- **`temperature` is sent only when set.** Leave it out and the server uses its own default (Ollama's is 0.8). `LLM_TEMPERATURE` sets it for every call; module 09 sets it to 0 for its judge, where sampling noise would make the measurement noisy.
- **`transport=`** is the test seam: tests pass an `httpx.MockTransport`, so everything above the network is the real code.

### The backends

```python
# src/llm_client/ollama.py
from typing import TYPE_CHECKING

import httpx

from .costs import FREE
from .openai_compat import OpenAICompatibleClient

if TYPE_CHECKING:
    from .types import LlmClient


class OllamaClient(OpenAICompatibleClient):
    """Local models through Ollama's OpenAI-compatible endpoint. Free to run; usage still logged."""

    def __init__(
        self, base_url: str, model: str, *, temperature: float | None = None, timeout: float = 90.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        # OLLAMA_BASE_URL is the server root (http://localhost:11434); the OpenAI shape lives under /v1.
        super().__init__(
            f"{base_url.rstrip('/')}/v1", model, FREE,
            temperature=temperature, timeout=timeout, transport=transport,
        )


if TYPE_CHECKING:
    # A structural-typing check that OllamaClient satisfies LlmClient. The type checker
    # reads it; at runtime it never executes, so no httpx client is created at import.
    _: LlmClient = OllamaClient(base_url="http://x", model="y")
```

Don't silence that last line with `# type: ignore`. The ignore would hide exactly the error the check exists to catch.

```python
# src/llm_client/hosted.py
import httpx

from .costs import Rates
from .openai_compat import OpenAICompatibleClient


class HostedClient(OpenAICompatibleClient):
    """A hosted OpenAI-compatible provider: a key, a real model name, real rates."""

    def __init__(
        self, base_url: str, api_key: str, model: str, rates: Rates, *,
        temperature: float | None = None, timeout: float = 90.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        # base_url includes /v1 (LLM_BASE_URL); the key comes from .env / SSM, never from source.
        super().__init__(
            base_url, model, rates,
            api_key=api_key, temperature=temperature, timeout=timeout, transport=transport,
        )
```

```python
# src/llm_client/stub.py
import time
from collections.abc import AsyncIterator, Sequence

from .costs import FREE, log_call
from .types import Completion, Message, Usage


class StubClient:
    """LLM_BACKEND=stub: deterministic, offline, free. What tests, CI and the
    cross-checks run on. It isn't a model; it's a predictable stand-in for one.

    Reply: the next of `replies` (cycling), else "stub: <last user message>".
    Usage: whitespace-separated words, so both languages count the same way.
    """

    def __init__(self, replies: Sequence[str] = ()):
        self._replies = list(replies)
        self._next = 0

    def _reply(self, messages: Sequence[Message]) -> str:
        if self._replies:
            reply = self._replies[self._next % len(self._replies)]
            self._next += 1
            return reply
        last_user = next((m.content for m in reversed(messages) if m.role == "user"), "")
        return f"stub: {last_user}"

    @staticmethod
    def _usage(messages: Sequence[Message], reply: str) -> Usage:
        return Usage(
            prompt_tokens=sum(len(m.content.split()) for m in messages),
            completion_tokens=len(reply.split()),
        )

    async def complete(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> Completion:
        t0 = time.perf_counter()
        reply = self._reply(messages)
        usage = self._usage(messages, reply)
        log_call("stub", usage, 0.0, (time.perf_counter() - t0) * 1000, "stop")
        return Completion(reply, usage, model="stub", finish_reason="stop", cost_usd=0.0)

    async def stream(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> AsyncIterator[str]:
        t0 = time.perf_counter()
        reply = self._reply(messages)
        for i, word in enumerate(reply.split(" ")):
            yield word if i == 0 else f" {word}"
        usage = self._usage(messages, reply)
        log_call("stub", usage, 0.0, (time.perf_counter() - t0) * 1000, "stop")
```

One small factory picks the backend, the twin of C#'s `AddLlmClient`. `demo.py` and the later modules call it instead of constructing a client themselves. An unknown value fails loudly; silently falling back to some other model would be a correctness bug ([conventions](conventions.md#model-backends)).

```python
# src/llm_client/factory.py
import os

from .costs import Rates
from .hosted import HostedClient
from .ollama import OllamaClient
from .stub import StubClient
from .types import LlmClient

BACKENDS = ("stub", "ollama", "hosted")


def _temperature_from_env() -> float | None:
    """LLM_TEMPERATURE, if set (e.g. 0 for an eval judge). Unset means the server's default."""
    value = os.environ.get("LLM_TEMPERATURE")
    return float(value) if value else None


def client_from_env() -> LlmClient:
    """Pick the backend from LLM_BACKEND (docs/conventions.md#model-backends)."""
    backend = os.environ.get("LLM_BACKEND", "ollama")
    if backend == "stub":
        reply = os.environ.get("LLM_STUB_REPLY")
        return StubClient([reply] if reply else [])
    if backend == "ollama":
        return OllamaClient(
            base_url=os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434"),  # no /v1
            model=os.environ.get("OLLAMA_MODEL", "llama3.2"),
            temperature=_temperature_from_env(),
        )
    if backend == "hosted":
        return HostedClient(
            base_url=os.environ["LLM_BASE_URL"],  # includes /v1
            api_key=os.environ["LLM_API_KEY"],
            model=os.environ["LLM_MODEL"],
            temperature=_temperature_from_env(),
            # .NET's env-var spelling of Rates:InputPerMTok, so one .env drives both sides.
            rates=Rates(
                input_per_mtok=float(os.environ["Rates__InputPerMTok"]),
                output_per_mtok=float(os.environ["Rates__OutputPerMTok"]),
            ),
        )
    raise ValueError(f"unknown LLM_BACKEND {backend!r} (expected one of: {' | '.join(BACKENDS)})")
```

```python
# demo.py
import asyncio

from llm_client.factory import client_from_env
from llm_client.types import Message

MESSAGES = [
    Message("system", "You are a terse assistant."),
    Message("user", "Name three primary colors."),
]


async def main() -> None:
    client = client_from_env()  # which backend? LLM_BACKEND decides; this code doesn't care

    reply = await client.complete(MESSAGES, max_tokens=512)
    print(reply.text)

    async for chunk in client.stream(MESSAGES):
        print(chunk, end="", flush=True)
    print()


if __name__ == "__main__":
    asyncio.run(main())
```

### Configuration

```bash
# projects/04-llm-client/python/.env.example
# Copy to .env (git-ignored) and fill in. Names: docs/conventions.md#environment-variables
# compose reads this file; a bare `uv run` doesn't, so set variables in your shell there.

# stub | ollama | hosted
LLM_BACKEND=ollama

# ollama: the server root, without /v1. Leave it commented: compose then uses
# http://host.docker.internal:11434 (or the ollama profile's service), and local runs
# default to http://localhost:11434. A localhost value here would point the container at itself.
# OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.2

# stub: a fixed reply instead of "stub: <last user message>"
# LLM_STUB_REPLY=

# Sampling temperature for every call (e.g. 0 for an eval judge). Unset: the server's default.
# LLM_TEMPERATURE=

# hosted: any OpenAI-compatible API. LLM_BASE_URL includes /v1.
LLM_BASE_URL=https://api.openai.com/v1
LLM_API_KEY=
LLM_MODEL=
# $ per million tokens, from your provider's current price list
Rates__InputPerMTok=0
Rates__OutputPerMTok=0
```

`Rates__InputPerMTok` is .NET's environment-variable spelling of the config key `Rates:InputPerMTok` (`__` stands for `:`). Python reads the same names, so one set of variables drives both sides.

### Tests with no network

A test that only calls a fake of your client proves nothing about your client (the review track's `mock-the-subject`). So the fake goes *under* the client: an `httpx.MockTransport` plays the server, and the tests exercise the code you wrote, which is the URL, headers, parsing, retries and streaming.

```python
# tests/test_costs.py
import pytest

from llm_client.costs import Rates, cost_usd
from llm_client.types import Usage


@pytest.mark.parametrize(
    ("inp", "out", "in_rate", "out_rate", "expected"),
    [
        (1_000_000, 500_000, 3.0, 15.0, 10.5),   # $3 in + $7.50 out
        (0, 0, 3.0, 15.0, 0.0),
        (10, 3, 1.0, 2.0, 0.000016),
    ],
)
def test_cost_usd_uses_per_million_rates(inp, out, in_rate, out_rate, expected):
    usage = Usage(prompt_tokens=inp, completion_tokens=out)
    assert cost_usd(usage, Rates(in_rate, out_rate)) == pytest.approx(expected)
```

```python
# tests/test_client.py
import json

import httpx
import pytest

from llm_client import retry
from llm_client.costs import Rates
from llm_client.hosted import HostedClient
from llm_client.ollama import OllamaClient
from llm_client.types import Message

OK_BODY = {
    "choices": [{"message": {"content": "blue, red, yellow"}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 10, "completion_tokens": 3},
}


class FakeServer:
    """The fake sits UNDER the client, as an httpx transport, so the tests exercise the
    code you wrote (URL, headers, parsing, retries) instead of a fake of it.
    `statuses` are returned in order; after that, 200 with OK_BODY."""

    def __init__(self, *statuses: int):
        self.statuses = list(statuses)
        self.requests: list[httpx.Request] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.statuses:
            return httpx.Response(self.statuses.pop(0))
        return httpx.Response(200, json=OK_BODY)

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)


def ollama(server: FakeServer) -> OllamaClient:
    # transport= swaps the network for the fake server; everything above it is real.
    return OllamaClient(base_url="http://ollama.test:11434", model="llama3.2", transport=server.transport)


@pytest.fixture(autouse=True)
def no_sleep(monkeypatch):
    async def instant(_delay: float) -> None:
        pass

    monkeypatch.setattr(retry.asyncio, "sleep", instant)  # keep tests fast; the shape is under test


@pytest.mark.asyncio
async def test_ollama_posts_to_v1_chat_completions():
    server = FakeServer()
    result = await ollama(server).complete([Message("user", "colors?")])
    assert result.text == "blue, red, yellow"
    assert str(server.requests[0].url) == "http://ollama.test:11434/v1/chat/completions"
    assert json.loads(server.requests[0].content)["messages"] == [{"role": "user", "content": "colors?"}]


@pytest.mark.asyncio
async def test_hosted_sends_key_and_prices_usage():
    server = FakeServer()
    client = HostedClient(
        "https://llm.test/v1", api_key="k-123", model="m", rates=Rates(1.0, 2.0), transport=server.transport
    )
    result = await client.complete([Message("user", "hi")])
    assert server.requests[0].headers["authorization"] == "Bearer k-123"
    assert str(server.requests[0].url) == "https://llm.test/v1/chat/completions"
    assert result.cost_usd == pytest.approx(0.000016)  # 10 in @ $1/M + 3 out @ $2/M


@pytest.mark.asyncio
@pytest.mark.parametrize(("status", "expected_calls"), [(429, 2), (503, 2)])
async def test_retries_transient_statuses(status, expected_calls):
    server = FakeServer(status)
    result = await ollama(server).complete([Message("user", "colors?")])
    assert result.text == "blue, red, yellow"
    assert len(server.requests) == expected_calls


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [400, 401])  # won't get better: no retry
async def test_does_not_retry_client_errors(status):
    server = FakeServer(status)
    with pytest.raises(httpx.HTTPStatusError):
        await ollama(server).complete([Message("user", "hi")])
    assert len(server.requests) == 1


@pytest.mark.asyncio
async def test_gives_up_after_max_attempts():
    server = FakeServer(*[503] * 10)
    with pytest.raises(retry.TransientError):
        await ollama(server).complete([Message("user", "hi")])
    assert len(server.requests) == 5  # same as C#'s 1 try + 4 retries


@pytest.mark.asyncio
async def test_stream_yields_deltas_and_reads_usage(capsys):
    sse = "\n".join(
        [
            'data: {"choices":[{"delta":{"content":"blue,"}}]}',
            'data: {"choices":[{"delta":{"content":" red"},"finish_reason":"stop"}]}',
            'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}',
            "data: [DONE]",
        ]
    )
    client = OllamaClient(
        base_url="http://ollama.test:11434", model="llama3.2",
        transport=httpx.MockTransport(lambda _: httpx.Response(200, text=sse)),
    )
    chunks = [c async for c in client.stream([Message("user", "colors?")])]
    assert chunks == ["blue,", " red"]
    assert "in=10 out=2" in capsys.readouterr().err


@pytest.mark.asyncio
@pytest.mark.parametrize("temperature", [None, 0.0])
async def test_temperature_is_sent_only_when_set(temperature):
    server = FakeServer()
    client = OllamaClient(
        base_url="http://ollama.test:11434", model="llama3.2", temperature=temperature, transport=server.transport
    )
    await client.complete([Message("user", "hi")])
    body = json.loads(server.requests[0].content)
    assert ("temperature" in body) == (temperature is not None)
    assert body.get("temperature") == temperature
```

```python
# tests/test_stub.py
import pytest

from llm_client.factory import client_from_env
from llm_client.stub import StubClient
from llm_client.types import Message

MESSAGES = [Message("system", "You are terse."), Message("user", "Name three colors.")]


@pytest.mark.asyncio
async def test_stub_echoes_the_last_user_message_and_counts_words():
    result = await StubClient().complete(MESSAGES)
    assert result.text == "stub: Name three colors."
    assert (result.usage.prompt_tokens, result.usage.completion_tokens) == (6, 4)
    assert result.cost_usd == 0.0


@pytest.mark.asyncio
async def test_stub_cycles_scripted_replies():
    stub = StubClient(["one", "two"])
    texts = [(await stub.complete(MESSAGES)).text for _ in range(3)]
    assert texts == ["one", "two", "one"]


@pytest.mark.asyncio
async def test_stub_stream_reassembles_to_the_reply():
    chunks = [c async for c in StubClient(["blue, red, yellow"]).stream(MESSAGES)]
    assert chunks == ["blue,", " red,", " yellow"]


@pytest.mark.asyncio
async def test_factory_builds_stub_with_env_reply(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.setenv("LLM_STUB_REPLY", "canned")
    assert (await client_from_env().complete(MESSAGES)).text == "canned"


def test_factory_rejects_unknown_backend(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "bedrok")
    with pytest.raises(ValueError, match="stub | ollama | hosted"):
        client_from_env()
```

> **Pythonism flag.** `pytest` is xUnit-flavored but leaner: plain functions named `test_*`, bare `assert` (the plugin rewrites it to show a rich diff), fixtures instead of constructor setup. `pytest-asyncio` + `@pytest.mark.asyncio` lets you `await` inside a test. `monkeypatch` sets env vars and patches attributes for one test and undoes it afterwards.

Run locally:

```powershell
uv run pytest
$env:LLM_BACKEND = 'stub'; uv run python demo.py     # offline: no model needed
$env:LLM_BACKEND = 'ollama'; uv run python demo.py   # needs Ollama on localhost:11434
```

`$env:` settings last for the rest of the PowerShell session; `Remove-Item Env:LLM_BACKEND` clears one.

### Running the Python version in Docker

```dockerfile
# projects/04-llm-client/python/Dockerfile
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /app
# Library pattern: dependencies first (cached layer), then the code, then install the project.
# README.md comes early because uv_build reads the readme pyproject.toml names.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-install-project
COPY src/ ./src/
COPY tests/ ./tests/
COPY demo.py ./
RUN uv sync --frozen          # installs llm_client plus the dev group (pytest) by default
# Put the venv first on PATH, so `python` and `pytest` resolve to it without `uv run`.
ENV PATH="/app/.venv/bin:$PATH"
CMD ["python", "demo.py"]
```

```yaml
# projects/04-llm-client/python/compose.yaml
name: llm-client-py   # otherwise the project is named after the folder: "python"
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: .
    env_file:
      - path: .env             # hosted keys, rates and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}     # example; pull whatever you have
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

`environment:` wins over `env_file:`, which is why those values use `${VAR:-default}`. Compose fills them from the `.env` next to `compose.yaml`, so a value you set in `.env` takes effect and a missing one falls back to the default. The `.env` itself is optional (`required: false`), so the stack runs before you've created one. The `ollama` service sits behind a [profile](conventions.md#ollama): plain `docker compose` commands leave it out, and the app reaches native Ollama at `host.docker.internal:11434`. Add `--profile ollama` to run Ollama in the stack instead, as below. `extra_hosts` makes `host.docker.internal` resolve on Linux hosts too.

```powershell
cd projects/04-llm-client/python
Copy-Item .env.example .env                        # fill in a hosted key if you have one
docker compose run --rm --no-deps -e LLM_BACKEND=stub app   # offline: no model, no Ollama
docker compose run --rm --no-deps app pytest -q             # tests need no network
docker compose --profile ollama up -d ollama   # skip if Ollama runs natively
docker compose exec ollama ollama pull llama3.2    # one-time model download   # native: ollama pull llama3.2
docker compose run --rm app                        # demo.py against local Ollama
```

Set `LLM_BACKEND=hosted` in `.env` and the *same* `demo.py` runs against the hosted provider. That's the payoff of the interface.

## C# implementation

Work in `projects/04-llm-client/csharp/`. Same backends, same environment variables, same demo, same log line. What differs:

- **You don't write the interface.** `IChatClient` is it. `Message`, `Usage` and `Completion` become MEAI's `ChatMessage`, `UsageDetails` and `ChatResponse`. That deletes `types.py` entirely, at the price of the trade-off described in the provider-abstraction section above.
- **Cost logging is middleware, not code inside each backend.** The Python version calls `log_call` from each client. In C#, a `DelegatingChatClient` wraps *any* `IChatClient` once. It's the same idea as an ASP.NET Core middleware or a `DelegatingHandler`.
- **Retries live on the `HttpClient`, not around the call.** `with_backoff` wraps a Python coroutine. In .NET the resilience handler sits in the `HttpClient` pipeline, so every request through that client gets the policy and the calling code never sees it.
- **Ollama goes through OllamaSharp**, which talks to Ollama's native `/api/chat` endpoint. The Python version posts to the OpenAI-compatible `/v1/chat/completions`. Both are fine. If you want the C# side on the exact same endpoint, use `LLM_BACKEND=hosted` with `LLM_BASE_URL=http://localhost:11434/v1`.
- **Money is `decimal`**, as in module 03.

### Scaffold

Later modules reference the library, so scaffold a class library and add the demo console app next to it. From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 04-llm-client -Template classlib -Name LlmClient
cd projects/04-llm-client/csharp
Remove-Item src/LlmClient/Class1.cs, tests/LlmClient.Tests/SmokeTests.cs
dotnet new console -o src/LlmClient.Demo
dotnet sln add src/LlmClient.Demo/LlmClient.Demo.csproj
dotnet add src/LlmClient.Demo reference src/LlmClient/LlmClient.csproj

dotnet add src/LlmClient package Microsoft.Extensions.AI
dotnet add src/LlmClient package Microsoft.Extensions.AI.OpenAI
dotnet add src/LlmClient package OllamaSharp
dotnet add src/LlmClient package Microsoft.Extensions.Http.Resilience
dotnet add src/LlmClient package Microsoft.Extensions.Configuration.Binder
dotnet add src/LlmClient.Demo package Microsoft.Extensions.Hosting
```

This doc was built against Microsoft.Extensions.AI 10.10, Microsoft.Extensions.AI.OpenAI 10.10, OllamaSharp 5.5 and Microsoft.Extensions.Http.Resilience 10.10. Newer versions should work; if something doesn't compile, compare against those.

The test project already references `src/LlmClient`, and package references flow through project references, so it sees MEAI and the resilience package without adding them again.

### `src/LlmClient/Rates.cs`

```csharp
// src/LlmClient/Rates.cs
using Microsoft.Extensions.AI;

namespace LlmClient;

/// <summary>
/// Per-MILLION-token prices. These change constantly: bind them from config,
/// never trust a value hardcoded here.
/// </summary>
public sealed record Rates(decimal InputPerMTok, decimal OutputPerMTok)
{
    /// <summary>Local and stub models are free to run, but usage is still logged.</summary>
    public static Rates Free { get; } = new(0m, 0m);

    public decimal CostUsd(UsageDetails? usage) =>
        (usage?.InputTokenCount ?? 0) / 1_000_000m * InputPerMTok
        + (usage?.OutputTokenCount ?? 0) / 1_000_000m * OutputPerMTok;
}
```

`UsageDetails` token counts are nullable (`long?`) because not every provider reports them. Treat "missing" as zero for cost, but notice it: a backend that never reports usage makes your cost log quietly wrong.

### `src/LlmClient/LlmResilience.cs`

```csharp
// src/LlmClient/LlmResilience.cs
using Microsoft.Extensions.Http.Resilience;

namespace LlmClient;

/// <summary>The retry.py twin, as an HttpClient policy: same attempts and backoff shape, plus timeouts.</summary>
public static class LlmResilience
{
    public static void Configure(HttpStandardResilienceOptions o)
    {
        // retry.py: max_attempts=5 (1 try + 4 retries), base=0.5 s, cap=30 s, jitter.
        // Retry-After is honored by default, as in the Python version.
        o.Retry.MaxRetryAttempts = 4;
        o.Retry.Delay = TimeSpan.FromMilliseconds(500);
        o.Retry.MaxDelay = TimeSpan.FromSeconds(30);
        o.Retry.UseJitter = true;

        // Defaults are 10 s per attempt and 30 s total: fine for REST, fatal for a long generation.
        o.AttemptTimeout.Timeout = TimeSpan.FromSeconds(90);
        o.TotalRequestTimeout.Timeout = TimeSpan.FromMinutes(5);

        // Options validation requires the breaker's sampling window to be at least 2x the attempt timeout.
        o.CircuitBreaker.SamplingDuration = TimeSpan.FromMinutes(3);
    }
}
```

The standard handler retries 408, 429, every 5xx, connection failures and attempt timeouts. That's slightly wider than Python's `{429, 500, 502, 503, 504}`, and it never retries 400 or 401. It also retries `POST` by default. For a model call that's the double-billing risk from the idempotency bullet above. Accept it knowingly, or call `o.Retry.DisableForUnsafeHttpMethods()` and retry at a higher level where you can attach an idempotency key.

### `src/LlmClient/CostLoggingChatClient.cs`

```csharp
// src/LlmClient/CostLoggingChatClient.cs
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

namespace LlmClient;

/// <summary>
/// Middleware: wraps any IChatClient and logs model, tokens, dollars, latency and finish reason
/// on every call. Write it once; every backend gets it.
/// </summary>
public sealed class CostLoggingChatClient(IChatClient inner, Rates rates, ILogger<CostLoggingChatClient> logger)
    : DelegatingChatClient(inner)
{
    /// <summary>Key under ChatResponse.AdditionalProperties: the Completion.cost_usd twin.</summary>
    public const string CostKey = "cost_usd";

    public override async Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        long start = Stopwatch.GetTimestamp();
        ChatResponse response = await base.GetResponseAsync(messages, options, cancellationToken);
        Record(response, Stopwatch.GetElapsedTime(start));
        return response;
    }

    public override async IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        long start = Stopwatch.GetTimestamp();
        List<ChatResponseUpdate> updates = [];
        await foreach (ChatResponseUpdate update in base.GetStreamingResponseAsync(messages, options, cancellationToken))
        {
            updates.Add(update);   // accumulate as you go
            yield return update;
        }
        // Usage arrives on the last update(s). Fold the stream into one response to read it.
        Record(updates.ToChatResponse(), Stopwatch.GetElapsedTime(start));
    }

    private void Record(ChatResponse response, TimeSpan latency)
    {
        decimal cost = rates.CostUsd(response.Usage);
        response.AdditionalProperties ??= new AdditionalPropertiesDictionary();
        response.AdditionalProperties[CostKey] = cost;

        // Structured logging: named placeholders become queryable fields, not just text.
        // The number formats match Python's log_call, so the two sides' lines diff cleanly.
        logger.LogInformation(
            "llm_call model={Model} in={InputTokens} out={OutputTokens} cost_usd={CostUsd} latency_ms={LatencyMs} finish={FinishReason}",
            response.ModelId, response.Usage?.InputTokenCount ?? 0, response.Usage?.OutputTokenCount ?? 0,
            cost.ToString("F6", CultureInfo.InvariantCulture), (long)latency.TotalMilliseconds,
            response.FinishReason?.Value);

        if (response.FinishReason == ChatFinishReason.Length)
            logger.LogWarning("llm_call truncated: finish_reason=length");
    }
}
```

If the stream fails halfway, the exception propagates out of the `await foreach` and `Record` never runs. That's the honest outcome: you have partial text and no usage. Log the failure at the call site.

MEAI also ships `UseLogging()` and `UseOpenTelemetry()` for the builder. They log and trace calls, but they don't know your prices. Cost is the part you add.

### `src/LlmClient/StubChatClient.cs`

The `stub.py` twin, rule for rule, so the two sides produce identical output for the same input. `Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)` is the .NET spelling of Python's `str.split()`: split on runs of whitespace, drop the empties.

```csharp
// src/LlmClient/StubChatClient.cs
using System.Runtime.CompilerServices;
using Microsoft.Extensions.AI;

namespace LlmClient;

/// <summary>
/// LLM_BACKEND=stub: deterministic, offline, free. The stub.py twin, rule for rule:
/// the reply is the next of <paramref name="replies"/> (cycling), else "stub: &lt;last user message&gt;",
/// and usage counts whitespace-separated words, so both languages report the same numbers.
/// </summary>
public sealed class StubChatClient(IReadOnlyList<string>? replies = null) : IChatClient
{
    public const string Model = "stub";
    private readonly IReadOnlyList<string> _replies = replies ?? [];
    private int _next = -1;

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        ChatMessage[] call = [.. messages];
        string reply = NextReply(call);
        return Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, reply))
        {
            ModelId = Model,
            FinishReason = ChatFinishReason.Stop,
            Usage = UsageFor(call, reply),
        });
    }

    public async IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await Task.Yield();   // behave like a real stream: the caller gets control back first
        ChatMessage[] call = [.. messages];
        string reply = NextReply(call);
        string[] words = reply.Split(' ');
        for (int i = 0; i < words.Length; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return new ChatResponseUpdate(ChatRole.Assistant, i == 0 ? words[i] : " " + words[i]) { ModelId = Model };
        }
        yield return new ChatResponseUpdate
        {
            ModelId = Model,
            FinishReason = ChatFinishReason.Stop,
            Contents = [new UsageContent(UsageFor(call, reply))],
        };
    }

    public object? GetService(Type serviceType, object? serviceKey = null) =>
        serviceKey is null && serviceType.IsInstanceOfType(this) ? this : null;

    public void Dispose() { }

    private string NextReply(ChatMessage[] call)
    {
        if (_replies.Count > 0)
            return _replies[Interlocked.Increment(ref _next) % _replies.Count];
        string lastUser = call.LastOrDefault(m => m.Role == ChatRole.User)?.Text ?? "";
        return $"stub: {lastUser}";
    }

    private static UsageDetails UsageFor(ChatMessage[] call, string reply) => new()
    {
        InputTokenCount = call.Sum(m => Words(m.Text)),
        OutputTokenCount = Words(reply),
    };

    // Python's str.split(): split on whitespace runs, drop empties.
    private static int Words(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
```

### `src/LlmClient/Batch.cs`

```csharp
// src/LlmClient/Batch.cs
using Microsoft.Extensions.AI;

namespace LlmClient;

public static class Batch
{
    /// <summary>The asyncio.Semaphore + gather idiom: bounded concurrency, results in input order.</summary>
    public static async Task<ChatResponse[]> CompleteAllAsync(
        IChatClient client, IEnumerable<string> prompts, int concurrency = 8, CancellationToken ct = default)
    {
        using var gate = new SemaphoreSlim(concurrency);

        async Task<ChatResponse> One(string prompt)
        {
            await gate.WaitAsync(ct);
            try { return await client.GetResponseAsync(prompt, cancellationToken: ct); }
            finally { gate.Release(); }
        }

        return await Task.WhenAll(prompts.Select(One));
    }
}
```

Unlike `asyncio.gather`, these tasks can run on thread-pool threads in parallel. That makes no difference here, since the work is waiting on the network. `Parallel.ForEachAsync` with `MaxDegreeOfParallelism` is the other idiomatic option, but it doesn't return results in order, so you'd collect them yourself.

### `src/LlmClient/ServiceCollectionExtensions.cs`

The composition root for the backends. It reads the same `LLM_BACKEND`, `OLLAMA_*`, `LLM_*` and `LLM_STUB_REPLY` variables as the Python factory. `IConfiguration` merges env vars, `appsettings.json` and user-secrets, so the code doesn't care where a value came from. As in Python, an unknown backend fails at startup with the list of valid ones.

```csharp
// src/LlmClient/ServiceCollectionExtensions.cs
using System.ClientModel;
using System.ClientModel.Primitives;
using System.Globalization;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OllamaSharp;
using OpenAI;

namespace LlmClient;

public static class ServiceCollectionExtensions
{
    public static readonly string[] Backends = ["stub", "ollama", "hosted"];

    /// <summary>
    /// Registers IChatClient for the backend named by LLM_BACKEND (docs/conventions.md#model-backends),
    /// wrapped in cost logging. App code only ever asks for IChatClient.
    /// </summary>
    public static ChatClientBuilder AddLlmClient(this IServiceCollection services, IConfiguration config)
    {
        string backend = config["LLM_BACKEND"] ?? "ollama";
        if (!Backends.Contains(backend))
            throw new InvalidOperationException(
                $"unknown LLM_BACKEND '{backend}' (expected one of: {string.Join(" | ", Backends)})");

        Rates rates = backend is "stub" or "ollama"
            ? Rates.Free
            : config.GetSection("Rates").Get<Rates>()
              ?? throw new InvalidOperationException("Rates:InputPerMTok and Rates:OutputPerMTok are required");

        float? temperature = config["LLM_TEMPERATURE"] is { Length: > 0 } t
            ? float.Parse(t, CultureInfo.InvariantCulture)
            : null;

        services.AddHttpClient("llm", c => c.Timeout = Timeout.InfiniteTimeSpan) // the resilience handler owns timeouts
            .AddStandardResilienceHandler(LlmResilience.Configure);

        return services
            .AddChatClient(sp => CreateBackend(
                backend, config, sp.GetRequiredService<IHttpClientFactory>().CreateClient("llm")))
            .Use((inner, sp) => new CostLoggingChatClient(
                inner, rates, sp.GetRequiredService<ILogger<CostLoggingChatClient>>()))
            // LLM_TEMPERATURE, if set (e.g. 0 for an eval judge), is every call's default; a call that sets its own wins.
            .ConfigureOptions(o => o.Temperature ??= temperature);
    }

    private static IChatClient CreateBackend(string backend, IConfiguration config, HttpClient http)
    {
        switch (backend)
        {
            case "stub":
                // An empty value means "not set", as in Python: .env files often carry LLM_STUB_REPLY= blank.
                return new StubChatClient(config["LLM_STUB_REPLY"] is { Length: > 0 } reply ? [reply] : null);

            case "ollama":
                // OLLAMA_BASE_URL is the server root; OllamaSharp calls the native /api/chat under it.
                http.BaseAddress = new Uri(config["OLLAMA_BASE_URL"] ?? "http://localhost:11434");
                return new OllamaApiClient(http, config["OLLAMA_MODEL"] ?? "llama3.2");

            default: // "hosted"
                // Any OpenAI-compatible endpoint; LLM_BASE_URL includes /v1. Route it through our HttpClient
                // and turn the SDK's own retries off, so attempts don't multiply (SDK retries x handler retries).
                var options = new OpenAIClientOptions
                {
                    Endpoint = new Uri(Required(config, "LLM_BASE_URL")),
                    Transport = new HttpClientPipelineTransport(http),
                    RetryPolicy = new ClientRetryPolicy(maxRetries: 0),
                };
                return new OpenAIClient(new ApiKeyCredential(Required(config, "LLM_API_KEY")), options)
                    .GetChatClient(Required(config, "LLM_MODEL"))
                    .AsIChatClient();
        }
    }

    private static string Required(IConfiguration config, string key) =>
        config[key] ?? throw new InvalidOperationException($"missing config value '{key}'");
}
```

The hosted branch uses the OpenAI SDK's `System.ClientModel` plumbing (`HttpClientPipelineTransport`, `ClientRetryPolicy`) and the MEAI adapter's `AsIChatClient()`. All three have changed names across previews, so if they don't compile, check the current `Microsoft.Extensions.AI.OpenAI` docs.

### `src/LlmClient.Demo/Program.cs`

```csharp
// src/LlmClient.Demo/Program.cs
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// The generic host gives you config (env vars, appsettings, user-secrets in Development),
// console logging and DI: the plumbing demo.py does by hand.
HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
// Logs go to stderr, as in demo.py, so stdout is only the answer.
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Services.AddLlmClient(builder.Configuration);
using IHost host = builder.Build();

IChatClient chat = host.Services.GetRequiredService<IChatClient>();
List<ChatMessage> messages =
[
    new(ChatRole.System, "You are a terse assistant."),
    new(ChatRole.User, "Name three primary colors."),
];

ChatResponse reply = await chat.GetResponseAsync(messages, new ChatOptions { MaxOutputTokens = 512 });
Console.WriteLine(reply.Text);

await foreach (ChatResponseUpdate update in chat.GetStreamingResponseAsync(messages))
    Console.Write(update.Text);
Console.WriteLine();
```

Nothing here knows which backend it's talking to. That's the same payoff as the Python `demo.py`.

### Tests

The review track's `mock-the-subject` warning applies here too. `FakeChatClient` is the *inner* client, under the middleware, and the tests exercise the parts you wrote: the cost math, the middleware, the batching bound, the retry policy and the stub. The stub tests use the same messages and expect the same numbers as `test_stub.py`.

```csharp
// tests/LlmClient.Tests/FakeChatClient.cs
using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using Microsoft.Extensions.AI;

namespace LlmClient.Tests;

/// <summary>Canned responses, plus the instrumentation tests need (calls, max in-flight).</summary>
public sealed class FakeChatClient(string reply = "ok", TimeSpan delay = default) : IChatClient
{
    private readonly Lock _gate = new();
    private int _inFlight;

    /// <summary>Reply with the last message's text instead of the canned reply.</summary>
    public bool Echo { get; init; }
    public ConcurrentQueue<ChatMessage[]> Calls { get; } = new();
    public int MaxInFlight { get; private set; }

    public async Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        ChatMessage[] call = [.. messages];
        Calls.Enqueue(call);
        lock (_gate) MaxInFlight = Math.Max(MaxInFlight, ++_inFlight);
        try
        {
            await Task.Delay(delay, cancellationToken);
            return new ChatResponse(new ChatMessage(ChatRole.Assistant, ReplyFor(call)))
            {
                ModelId = "fake",
                FinishReason = ChatFinishReason.Stop,
                Usage = new UsageDetails { InputTokenCount = 10, OutputTokenCount = 3 },
            };
        }
        finally
        {
            lock (_gate) _inFlight--;
        }
    }

    public async IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ChatMessage[] call = [.. messages];
        Calls.Enqueue(call);
        await Task.Delay(delay, cancellationToken);
        yield return new ChatResponseUpdate(ChatRole.Assistant, ReplyFor(call)) { ModelId = "fake" };
        yield return new ChatResponseUpdate
        {
            FinishReason = ChatFinishReason.Stop,
            Contents = [new UsageContent(new UsageDetails { InputTokenCount = 10, OutputTokenCount = 3 })],
        };
    }

    public object? GetService(Type serviceType, object? serviceKey = null) =>
        serviceType.IsInstanceOfType(this) ? this : null;

    public void Dispose() { }

    private string ReplyFor(ChatMessage[] call) => Echo ? call[^1].Text : reply;
}
```

```csharp
// tests/LlmClient.Tests/CostTests.cs
using Microsoft.Extensions.AI;
using NUnit.Framework;

namespace LlmClient.Tests;

public class CostTests
{
    [TestCase(1_000_000, 500_000, 3.0, 15.0, 10.5)]   // $3 in + $7.50 out
    [TestCase(0, 0, 3.0, 15.0, 0.0)]
    [TestCase(10, 3, 1.0, 2.0, 0.000016)]
    public void CostUsd_uses_per_million_rates(long input, long output, decimal inRate, decimal outRate, decimal expected)
    {
        var usage = new UsageDetails { InputTokenCount = input, OutputTokenCount = output };
        Assert.That(new Rates(inRate, outRate).CostUsd(usage), Is.EqualTo(expected));
    }
}
```

NUnit converts the `double` literals in `[TestCase]` to the `decimal` parameters, since attributes can't hold `decimal` constants.

```csharp
// tests/LlmClient.Tests/ClientTests.cs
using System.Text;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using NUnit.Framework;

namespace LlmClient.Tests;

public class ClientTests
{
    private static CostLoggingChatClient Wrap(FakeChatClient fake) =>
        new(fake, new Rates(1m, 2m), NullLogger<CostLoggingChatClient>.Instance);

    [Test]
    public async Task Complete_records_history()
    {
        var fake = new FakeChatClient("blue, red, yellow");
        using var client = Wrap(fake);

        ChatResponse result = await client.GetResponseAsync("colors?");

        Assert.That(result.Text, Is.EqualTo("blue, red, yellow"));
        Assert.That(fake.Calls.Single()[0].Text, Is.EqualTo("colors?"));
    }

    [Test]
    public async Task Middleware_attaches_cost()
    {
        using var client = Wrap(new FakeChatClient());
        ChatResponse result = await client.GetResponseAsync("hi");
        // 10 in @ $1/M + 3 out @ $2/M
        Assert.That(result.AdditionalProperties?[CostLoggingChatClient.CostKey], Is.EqualTo(0.000016m));
    }

    [Test]
    public async Task Streaming_passes_every_chunk_through()
    {
        using var client = Wrap(new FakeChatClient("blue, red, yellow"));
        var text = new StringBuilder();
        await foreach (ChatResponseUpdate update in client.GetStreamingResponseAsync("colors?"))
            text.Append(update.Text);
        Assert.That(text.ToString(), Is.EqualTo("blue, red, yellow"));
    }

    [Test]
    public async Task Batch_bounds_concurrency_and_keeps_order()
    {
        var fake = new FakeChatClient(delay: TimeSpan.FromMilliseconds(20)) { Echo = true };
        string[] prompts = [.. Enumerable.Range(0, 20).Select(i => $"p{i}")];

        ChatResponse[] results = await Batch.CompleteAllAsync(fake, prompts, concurrency: 4);

        Assert.That(results.Select(r => r.Text), Is.EqualTo(prompts));
        Assert.That(fake.MaxInFlight, Is.LessThanOrEqualTo(4));
    }
}
```

The resilience test puts a stub `HttpMessageHandler` at the bottom of a real pipeline and counts how many requests reach it. That tests your policy, not Polly.

```csharp
// tests/LlmClient.Tests/ResilienceTests.cs
using System.Net;
using Microsoft.Extensions.DependencyInjection;
using NUnit.Framework;

namespace LlmClient.Tests;

public class ResilienceTests
{
    private sealed class SequenceHandler(params HttpStatusCode[] codes) : HttpMessageHandler
    {
        public int Calls;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            int i = Interlocked.Increment(ref Calls) - 1;
            return Task.FromResult(new HttpResponseMessage(codes[Math.Min(i, codes.Length - 1)]));
        }
    }

    private static (HttpClient Http, SequenceHandler Stub) Build(params HttpStatusCode[] codes)
    {
        var stub = new SequenceHandler(codes);
        var services = new ServiceCollection();
        services.AddHttpClient("t")
            .ConfigurePrimaryHttpMessageHandler(() => stub)
            .AddStandardResilienceHandler(o =>
            {
                LlmResilience.Configure(o);
                o.Retry.Delay = TimeSpan.Zero;   // keep the test fast; the shape is what's under test
            });
        var http = services.BuildServiceProvider().GetRequiredService<IHttpClientFactory>().CreateClient("t");
        return (http, stub);
    }

    [TestCase(HttpStatusCode.TooManyRequests, 2)]
    [TestCase(HttpStatusCode.ServiceUnavailable, 2)]
    [TestCase(HttpStatusCode.BadRequest, 1)]     // won't get better: no retry
    [TestCase(HttpStatusCode.Unauthorized, 1)]
    public async Task Retries_only_transient_statuses(HttpStatusCode first, int expectedCalls)
    {
        var (http, stub) = Build(first, HttpStatusCode.OK);
        using HttpResponseMessage _ = await http.PostAsync("http://llm.test/v1/chat", new StringContent("{}"));
        Assert.That(stub.Calls, Is.EqualTo(expectedCalls));
    }

    [Test]
    public async Task Gives_up_after_max_attempts()
    {
        var (http, stub) = Build(HttpStatusCode.ServiceUnavailable);
        using HttpResponseMessage response = await http.PostAsync("http://llm.test/v1/chat", new StringContent("{}"));
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(stub.Calls, Is.EqualTo(5));   // 1 try + 4 retries, same as max_attempts=5
    }
}
```

Note what `Gives_up_after_max_attempts` shows. After the last retry the handler hands back the final 503 response; it doesn't throw. The MEAI adapter or your own code turns that into an exception. Check that it does, rather than letting a failed call look like an empty answer (`swallowed-error`).

```csharp
// tests/LlmClient.Tests/StubTests.cs
using System.Text;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using NUnit.Framework;

namespace LlmClient.Tests;

/// <summary>The test_stub.py twin: same messages, same numbers.</summary>
public class StubTests
{
    private static readonly ChatMessage[] Messages =
        [new(ChatRole.System, "You are terse."), new(ChatRole.User, "Name three colors.")];

    [Test]
    public async Task Stub_echoes_the_last_user_message_and_counts_words()
    {
        ChatResponse result = await new StubChatClient().GetResponseAsync(Messages);
        Assert.That(result.Text, Is.EqualTo("stub: Name three colors."));
        Assert.That(result.Usage?.InputTokenCount, Is.EqualTo(6));
        Assert.That(result.Usage?.OutputTokenCount, Is.EqualTo(4));
    }

    [Test]
    public async Task Stub_cycles_scripted_replies()
    {
        var stub = new StubChatClient(["one", "two"]);
        var texts = new List<string>();
        for (int i = 0; i < 3; i++)
            texts.Add((await stub.GetResponseAsync(Messages)).Text);
        Assert.That(texts, Is.EqualTo(new[] { "one", "two", "one" }));
    }

    [Test]
    public async Task Stub_stream_reassembles_to_the_reply()
    {
        var chunks = new List<string>();
        await foreach (ChatResponseUpdate update in new StubChatClient(["blue, red, yellow"]).GetStreamingResponseAsync(Messages))
            if (update.Text.Length > 0)
                chunks.Add(update.Text);
        Assert.That(chunks, Is.EqualTo(new[] { "blue,", " red,", " yellow" }));
    }

    private static IChatClient Resolve(params (string Key, string Value)[] settings)
    {
        IConfiguration config = new ConfigurationBuilder()
            .AddInMemoryCollection(settings.Select(s => KeyValuePair.Create(s.Key, (string?)s.Value)))
            .Build();
        var services = new ServiceCollection().AddLogging();
        services.AddLlmClient(config);
        return services.BuildServiceProvider().GetRequiredService<IChatClient>();
    }

    [Test]
    public async Task AddLlmClient_builds_stub_with_configured_reply_and_cost()
    {
        IChatClient chat = Resolve(("LLM_BACKEND", "stub"), ("LLM_STUB_REPLY", "canned"));
        ChatResponse result = await chat.GetResponseAsync(Messages);
        Assert.That(result.Text, Is.EqualTo("canned"));
        Assert.That(result.AdditionalProperties?[CostLoggingChatClient.CostKey], Is.EqualTo(0m));
    }

    [Test]
    public async Task AddLlmClient_accepts_a_temperature()
    {
        IChatClient chat = Resolve(("LLM_BACKEND", "stub"), ("LLM_TEMPERATURE", "0"));
        Assert.That((await chat.GetResponseAsync(Messages)).Text, Is.EqualTo("stub: Name three colors."));
    }

    [Test]
    public void AddLlmClient_rejects_unknown_backend()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Resolve(("LLM_BACKEND", "bedrok")));
        Assert.That(ex!.Message, Does.Contain("stub | ollama | hosted"));
    }
}
```

Run locally:

```powershell
dotnet test
dotnet test --filter "FullyQualifiedName~StubTests"

$env:LLM_BACKEND = 'stub'; dotnet run --project src/LlmClient.Demo     # offline
$env:LLM_BACKEND = 'ollama'; dotnet run --project src/LlmClient.Demo   # Ollama on localhost:11434

# Hosted: keys go in user-secrets locally, never in appsettings.json or source
dotnet user-secrets init --project src/LlmClient.Demo
dotnet user-secrets set LLM_API_KEY "<your key>" --project src/LlmClient.Demo
dotnet user-secrets set Rates:InputPerMTok 3 --project src/LlmClient.Demo
dotnet user-secrets set Rates:OutputPerMTok 15 --project src/LlmClient.Demo
$env:LLM_BACKEND = 'hosted'; $env:LLM_BASE_URL = '<endpoint, with /v1>'; $env:LLM_MODEL = '<model>'
$env:DOTNET_ENVIRONMENT = 'Development'
dotnet run --project src/LlmClient.Demo
```

The host only loads user-secrets when the environment is `Development`, hence `DOTNET_ENVIRONMENT`. The rate values are placeholders; look up current prices.

### Running the C# version in Docker

A multi-stage build, as in module 03: the SDK image restores, builds and tests, and the runtime image runs the demo as the non-root `app` user.

```dockerfile
# projects/04-llm-client/csharp/Dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer so package downloads cache across code changes.
COPY LlmClient.slnx Directory.Build.props ./
COPY src/LlmClient/LlmClient.csproj src/LlmClient/
COPY src/LlmClient.Demo/LlmClient.Demo.csproj src/LlmClient.Demo/
COPY tests/LlmClient.Tests/LlmClient.Tests.csproj tests/LlmClient.Tests/
RUN dotnet restore
COPY . .
RUN dotnet publish src/LlmClient.Demo -c Release -o /app --no-restore

FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
ENTRYPOINT ["dotnet", "LlmClient.Demo.dll"]
```

```yaml
# projects/04-llm-client/csharp/compose.yaml
name: llm-client-cs
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: { context: ., target: final }
    env_file:
      - path: .env             # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}     # example; pull whatever you have
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

  test:
    build: { context: ., target: test }
    profiles: [test]           # only runs when asked for by name

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

```powershell
cd projects/04-llm-client/csharp
docker compose run --rm --no-deps -e LLM_BACKEND=stub app   # offline
docker compose run --rm test                                # dotnet test, no network needed
docker compose --profile ollama up -d ollama   # skip if Ollama runs natively
docker compose exec ollama ollama pull llama3.2   # native: ollama pull llama3.2
docker compose run --rm app                                 # the demo against local Ollama
```

Only one stack can publish port 11434 at a time, so stop the Python stack's Ollama first (`docker compose down` in `python/`). The fixed volume name means models you pull in one stack are there in the other, so you only download each model once. Keep the two top-level `name:`s different: those name the stacks, and sharing one would merge them.

## Cross-check the two

**Exact, on the stub.** Run both demos with `LLM_BACKEND=stub`. Their stdout must be byte-identical, and so must their `llm_call` lines apart from `latency_ms`. That covers the reply, the streamed chunks, token counts, cost formatting and finish reason. From `projects/04-llm-client`:

```powershell
$env:LLM_BACKEND = 'stub'
uv run --project python python python/demo.py 2> py.err > py.out
dotnet run --project csharp/src/LlmClient.Demo 2> cs.err > cs.out
Compare-Object (Get-Content py.out) (Get-Content cs.out)    # no output = identical
$strip = { (Select-String 'llm_call.*' $args[0]).Matches.Value -replace 'latency_ms=\d+ ', '' }
Compare-Object (& $strip py.err) (& $strip cs.err)          # no output = identical
```

C#'s console logger prefixes each line with its category (`info: LlmClient.CostLoggingChatClient[0]`), so the comparison takes the `llm_call...` part of each line.

**Approximate, on a real model.** Point both at the same Ollama model:

- **Cost math** must match **exactly** for the same usage and rates. Run the `CostTests` cases through Python's `cost_usd` too: they're the same table.
- **Input tokens** should match for the same messages and model: same tokenizer, same chat template. One caveat: Ollama can report fewer prompt tokens when it reuses a cached prefix from a previous call, so compare first calls.
- **Output text and output tokens** won't match, and that's not a bug. It's sampling (module 03). If you need them closer, set temperature to 0 on both sides, and expect "closer," not "identical."
- **Finish reason** should agree. Run both with a tiny `max_tokens` and both should report `length` (MEAI normalizes it to `ChatFinishReason.Length`).
- **Retry behavior** matches in shape (4 retries, exponential, jittered, `Retry-After` honored), not in exact delays. The jitter formulas differ, and C# also retries 408 and the rarer 5xx codes.

| Concern | Python | C# / .NET |
|---|---|---|
| The interface | your own `LlmClient` `Protocol` | `IChatClient` from `Microsoft.Extensions.AI` |
| Core types | your frozen dataclasses | `ChatMessage`, `ChatOptions`, `ChatResponse`, `UsageDetails` |
| HTTP | `httpx.AsyncClient` | `HttpClient` from `IHttpClientFactory` |
| Retries/timeouts | hand-rolled `with_backoff` (or `tenacity`) | `AddStandardResilienceHandler` (Polly v8) |
| Streaming | async generator over SSE lines | `IAsyncEnumerable<ChatResponseUpdate>` |
| Ollama | `/v1/chat/completions` (OpenAI-compatible) | OllamaSharp `OllamaApiClient` (`/api/chat`) |
| Offline backend | `StubClient` | `StubChatClient` |
| Cost logging | `log_call` from each client | one `DelegatingChatClient` middleware + `ILogger` |
| Bounded concurrency | `asyncio.Semaphore` + `gather` | `SemaphoreSlim` + `Task.WhenAll` |
| Cancellation | task cancellation | `CancellationToken` on every call |
| Config/secrets | env vars, `.env` via compose | `IConfiguration`: env vars, user-secrets, appsettings |
| Test seam | `httpx.MockTransport` under the client | `FakeChatClient` under the middleware; a stub `HttpMessageHandler` under the resilience pipeline |
| Tests | `pytest` + `pytest-asyncio` | NUnit, `async Task` tests |

## Moving llm-client to AWS

- **Bedrock is just another backend.** Amazon Bedrock exposes many models through one API (its `Converse` API normalizes the request shape across model families — convenient, since it's already provider-agnostic). Only the backend seam moves, and you'll make that move in module 12, **in this library**, so every project that reuses it gets `LLM_BACKEND=bedrock` at once:
  - **Python:** a `BedrockClient` that satisfies your `LlmClient` protocol, plus a `bedrock` branch in `client_from_env`. The `boto3` SDK handles AWS auth via the standard credential chain.
  - **C#:** a `"bedrock"` case in `CreateBackend`. The `AWSSDK.Extensions.Bedrock.MEAI` package adapts the Bedrock runtime client to `IChatClient`, so the case is roughly `bedrockRuntime.AsIChatClient(modelId)` on an `IAmazonBedrockRuntime` (from `AWSSDK.BedrockRuntime`). The cost middleware, the demo and the later projects don't change.
- **Secrets.** Locally, keys live in `.env` (Python, git-ignored) or user-secrets (C#). On AWS, don't ship keys in env vars in plaintext — pull them from **SSM Parameter Store** (SecureString) or **Secrets Manager** at startup, and give the task an IAM role instead of long-lived keys where possible. In .NET, the `Amazon.Extensions.Configuration.SystemsManager` package loads Parameter Store values straight into `IConfiguration`, so `config["LLM_API_KEY"]` doesn't change. This is the same "config vs secrets" split you already enforce in .NET.
- **Timeouts and retries still apply.** `boto3` and the AWS SDK for .NET both have their own retry config (retry mode, max attempts, timeouts on the client config); set it deliberately rather than trusting defaults, same as everywhere else. The Bedrock client doesn't go through your named `HttpClient`, so the resilience handler doesn't apply to it. Its retries are the SDK's.

## How experts think / pitfalls

- **The API is stateless; you own the transcript.** Forgetting this leads to "why doesn't it remember?" bugs and surprise bills from resending huge histories.
- **Watch `finish_reason`.** Silent truncation at "length" produces confident, incomplete answers and invalid JSON. It's the LLM equivalent of an unchecked `Content-Length`.
- **Bound your concurrency.** Unbounded `gather` over 1000 prompts is a self-inflicted DDoS that returns a wall of 429s. Semaphore always.
- **Retries can double-bill.** Non-determinism means a retry after a mid-stream failure can produce a *different* answer you also pay for. Use idempotency keys where offered; cap attempts.
- **Log cost from day one.** Retrofitting cost accounting after a scary bill is painful; emit tokens and dollars on every call now.
- **Don't leak the vendor SDK past your interface.** The one place you import the vendor package should be inside your implementation class. Everything else sees `LlmClient`.
- **Local ≠ hosted quality.** Ollama is perfect for wiring, tests, and offline iteration; a small local model may answer worse than a frontier hosted one. Develop local, evaluate (module 09) before trusting either in prod.
- **Library defaults are tuned for REST, not LLMs.** .NET's standard resilience handler gives up on an attempt after 10 seconds. That's a sane default for a CRUD API and a guaranteed failure for a 60-second generation. Read every timeout default in the stack (HttpClient, resilience handler, SDK client) and set each one on purpose.
- **Don't stack retries.** Vendor SDKs (OpenAI's, the AWS SDK) retry on their own. Put a resilience handler under one and 4 handler retries times 3 SDK retries is up to 20 calls per request, each one billable. Pick exactly one layer to own retries and turn the others off.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **During the build:** write one full [single-change review](R-reviewing-ai-written-code.md#review-templates) of the agent's retry/backoff implementation.
- **Watch for:** `swallowed-error` (a broad `except` returning `None` after the last retry), `silent-regression` (retrying non-idempotent calls, changed timeout defaults) and `mock-the-subject` (tests that only exercise the fake client, never the retry logic itself).
- **C#-specific watch:** `Microsoft.Extensions.AI` renamed its core API before 1.0, and agents mix the eras: `CompleteAsync` / `CompleteStreamingAsync` / `ChatCompletion` / `StreamingChatCompletionUpdate` are the old preview names for `GetResponseAsync` / `GetStreamingResponseAsync` / `ChatResponse` / `ChatResponseUpdate`, and `AsChatClient()` became `AsIChatClient()`. Expect also the deprecated `Microsoft.Extensions.AI.Ollama` package instead of OllamaSharp, Polly v7 syntax (`Policy.Handle<>().WaitAndRetryAsync`, `AddTransientHttpErrorPolicy`) instead of v8 resilience pipelines, and invented resilience option names. If it doesn't compile against the current package, it's the wrong era.
- **Before moving on:** finish the gameable-tests lab (8–10 tasks, with mutation testing run in Docker).

## Checkpoint

You're ready for module 05 if you can:

- [ ] Explain why the chat API is stateless and what that means for cost and memory.
- [ ] Distinguish streaming from non-streaming and say what streaming does and does *not* improve.
- [ ] List which HTTP statuses you retry, which you don't, and why backoff needs jitter.
- [ ] Explain the token-per-minute vs request-per-minute distinction behind a 429.
- [ ] Compute the dollar cost of a call from its input/output token usage.
- [ ] Batch N requests with bounded concurrency and say why the bound matters.
- [ ] Justify wrapping the vendor SDK behind your own `Protocol`, and swap hosted ↔ Ollama without touching app code.
- [ ] Write a test that runs with no network, with the fake *under* your client (`httpx.MockTransport`) rather than in place of it, and say why that placement matters.
- [ ] Run both demos on `LLM_BACKEND=stub` and show their output and `llm_call` lines match exactly.
- [ ] Say what `IChatClient` gives you over a hand-written interface and what it costs, and add a behavior (cost logging) as `DelegatingChatClient` middleware.
- [ ] Run both demos against the same Ollama model and say which values must match (cost math, input tokens, finish reason) and which can't (text, output tokens).

## Going deeper

- The `httpx` docs on async clients, timeouts, and streaming responses — your `HttpClient` reference here.
- `tenacity` for declarative retry/backoff (the Polly analogue).
- Your provider's API reference for the *exact* current request/response fields, streaming format, rate-limit headers, and idempotency support — do not trust the illustrative shapes above.
- Ollama's docs on its OpenAI-compatible endpoint and model catalog.
- Amazon Bedrock's `Converse` API docs when you get to module 12.
- Provider "prompt caching" features (caching a large stable prefix to cut input cost) — a real lever revisited in module 13.
- "Microsoft.Extensions.AI IChatClient" and "DelegatingChatClient middleware": the abstraction, the builder pipeline, and the built-in logging/OpenTelemetry/caching middleware.
- "Microsoft.Extensions.Http.Resilience standard resilience handler": what each strategy does, its defaults, and the options validation rules.
- "OllamaSharp IChatClient" and "AWSSDK.Extensions.Bedrock.MEAI": the local and Bedrock adapters for `IChatClient`.

*Last verified: 2026-10-05. Built: Python (pytest 18 passed, pyright clean) and C# (dotnet test 18 passed) in a throwaway build; demos and the stub cross-check run on both. Read-only: Docker images (compose files validated with `docker compose config`) and the Ollama and hosted paths against a live model.*

**Verify on first build:** that your Ollama version sends usage on streamed responses (`stream_options.include_usage`); if `in=0 out=0` shows on streamed calls, it doesn't.

Next: [05 — Prompt engineering as engineering](05-prompt-engineering-as-engineering.md).
