# 10 — Serving & inference (local)

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. These docs assume you're excellent at software engineering — architecture, testing, CI, APIs, Docker, cloud — and won't re-teach that. They teach the AI-specific layer on top, using analogies to what you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default language. When something is a Python-ism (not a general idea), it's flagged.

## Where this fits

You've finished Phase 1–3. You can call models ([04](04-calling-models-apis-sdks.md)), engineer prompts as versioned artifacts ([05](05-prompt-engineering-as-engineering.md)), get structured output and tool calls ([06](06-structured-outputs-and-tool-calling.md)), build RAG ([07](07-retrieval-augmented-generation.md)) and agents ([08](08-agents-and-orchestration.md)), and — most importantly — measure quality with evals ([09](09-evaluation-and-testing.md)).

So far the model has been *somebody else's HTTP endpoint*. You send JSON to `api.openai.com` or Bedrock and tokens come back. That's the right default. This module is about the other option: **running the model yourself**. Not because you always should — mostly you shouldn't — but because an AI engineer has to understand what's inside that endpoint to reason about cost, latency, privacy, and control.

After this module you'll be able to:

- Decide, with evidence, when self-hosting an open-weights model beats a hosted API.
- Run an open model locally in Docker and put a clean, backend-agnostic gateway in front of it.
- Read an inference performance conversation fluently: quantization, VRAM, tokens/sec, time-to-first-token, batching, KV cache.
- Map local serving onto AWS options (EC2 GPU, ECS/EKS, SageMaker endpoints) versus just using Bedrock.
- Benchmark the same server from C# with `IChatClient` (TTFT from the stream, percentiles, concurrency), and say when running the model *inside* a .NET process (LLamaSharp, ONNX Runtime GenAI) beats a separate server.

## Hosted API vs self-hosted open weights

This is the same build-vs-buy decision you've made a hundred times for databases and message brokers — RDS vs running Postgres on EC2 vs Postgres in a container you babysit. The trade-offs rhyme.

**Hosted API** (OpenAI, Anthropic, Bedrock, etc.):

- **Cost model:** pay per token. Zero fixed cost, scales to zero, no idle burn. Expensive at high, steady volume.
- **Ops burden:** basically none. No GPUs, no drivers, no capacity planning.
- **Control:** you get what they ship. Model can change under you, get deprecated, or rate-limit you.
- **Privacy/compliance:** your data leaves your boundary. Often fine (they offer no-training / zero-retention terms), sometimes a dealbreaker.
- **Capability:** frontier models you cannot get any other way.

**Self-hosted open weights** (Llama, Mistral, Qwen, Gemma, etc. — you download the weights and run them):

- **Cost model:** pay for the GPU hour whether or not a request is in flight. Cheap per token *if* you keep the box busy; ruinous if it sits idle.
- **Ops burden:** real. You own drivers, CUDA, capacity, autoscaling, upgrades, OOMs. This is the line item people underestimate.
- **Control:** total. Pin a version forever. Fine-tune it ([16](16-fine-tuning-and-adaptation.md)). Run air-gapped.
- **Privacy:** data never leaves your VPC. This alone justifies self-hosting for some regulated workloads.
- **Capability:** open models trail the frontier, but the gap keeps closing and is often irrelevant for a scoped task.

The mental shortcut: **hosted is opex that tracks usage; self-hosted is capex-shaped opex you pay for a running machine.** Same reason you don't run your own Redis for a side project but might for a fleet.

We'll come back to "when it's actually worth it" after you've felt the ops burden yourself.

## Running open models locally

### Ollama, from the inside

You've used [Ollama](https://ollama.com) since [04](04-calling-models-apis-sdks.md) as the `ollama` backend: a server on port 11434 that answers chat requests. Now look inside it. It's the "Docker for models": one command pulls a quantized model, another runs it.

```powershell
ollama pull llama3.2:3b
ollama run llama3.2:3b "explain a b-tree in one sentence"
ollama show llama3.2:3b     # parameters, quantization, context length
ollama ps                   # what's loaded right now, and whether it's on GPU or CPU
```

It bundles three things: the weights (GGUF files, below), a runtime (`llama.cpp` under the hood) and a small HTTP server. The server speaks its own native API (`/api/chat`, which module 04's C# backend uses through OllamaSharp) and an **OpenAI-compatible** one at `/v1/chat/completions` (which 04's Python backend uses). That second one is the trick this module leans on.

How you run it (natively on Windows, or in compose with the shared `ai-learn-ollama` volume, never both at once) is in [conventions](conventions.md#ollama). Nothing about that changes here.

Ollama is optimized for *single-user, low-concurrency* use: your laptop, a dev box, a demo. It is **not** what you'd put under production throughput.

### vLLM and TGI — the throughput engines (mention)

When you actually serve many concurrent users, you reach for a real inference server:

- **vLLM** — the current de-facto open-source serving engine. Its headline feature is **PagedAttention**, which manages the KV cache like an OS manages virtual memory pages, letting it pack far more concurrent requests onto a GPU. Also exposes an OpenAI-compatible API.
- **TGI (Text Generation Inference)** — Hugging Face's server, similar goals, tight integration with the HF ecosystem.

You don't need to run these on your laptop (they want a real GPU). Know that they exist, that they're what production self-hosting uses, and that they speak the same OpenAI-compatible dialect — so your app code doesn't care which one is behind the endpoint.

### The OpenAI-compatible endpoint pattern

Here's the load-bearing idea for the rest of this curriculum. `POST /v1/chat/completions` with `{model, messages, ...}` returning `{choices: [{message: {...}}]}` has become the *lingua franca* of LLM serving. OpenAI, Ollama, vLLM, TGI, LM Studio, LiteLLM, most gateways — they all speak it.

That means the client you built in [04](04-calling-models-apis-sdks.md) doesn't need a new shape per backend. Its `hosted` backend posts to `{LLM_BASE_URL}/chat/completions` with a bearer key, so it talks to *any* server that speaks the dialect, in both languages. Moving between servers is configuration:

```powershell
# Local Ollama, through 04's ollama backend (Python: /v1; C#: OllamaSharp's native API)
$env:LLM_BACKEND = 'ollama'; $env:OLLAMA_MODEL = 'llama3.2:3b'

# Ollama again, but through its OpenAI-compatible /v1, the same path a vLLM or hosted server takes
$env:LLM_BACKEND = 'hosted'; $env:LLM_BASE_URL = 'http://localhost:11434/v1'; $env:LLM_API_KEY = 'ollama'
$env:LLM_MODEL = 'llama3.2:3b'; $env:Rates__InputPerMTok = '0'; $env:Rates__OutputPerMTok = '0'

# vLLM on a GPU box: the same backend, a different URL and model name
$env:LLM_BASE_URL = 'http://vllm:8000/v1'; $env:LLM_MODEL = 'meta-llama/Llama-3.2-3B-Instruct'
```

Ollama ignores the key, and a local model costs nothing per token, so the rates are zero. This is the `IHttpClientFactory` + typed-client discipline you already practice in .NET: program against the interface, swap the implementation by config. Backend-agnostic app code is the goal: you want to A/B a hosted frontier model against a self-hosted one *by changing an env var*, not by rewriting the app.

## Quantization intuition (no heavy math)

A model's weights are just numbers. Trained models usually store them in 16-bit floats (**fp16**/**bf16**). **Quantization** stores them in fewer bits — **int8**, **int4** — trading precision for size and speed.

Think of it like image compression. A PNG is lossless (fp16). A high-quality JPEG (int8) is much smaller and you can't tell the difference. A low-quality JPEG (int4) is tiny and mostly fine, but you start seeing artifacts on hard cases.

Rules of thumb that actually matter to you:

- **Memory scales with bits.** A 7-billion-parameter model at fp16 needs ~14 GB just for weights (2 bytes × 7B). At int8, ~7 GB. At int4, ~3.5 GB. This is *the* number that decides whether a model fits on your hardware.
- **Smaller is faster and cheaper**, because inference is mostly memory-bandwidth-bound — moving weights from VRAM to compute units is the bottleneck, so fewer bytes = more tokens/sec.
- **Quality degrades gradually, then sharply.** fp16→int8 is usually a rounding error in eval scores. int8→int4 is often still fine for many tasks. Below int4 it falls apart. *You measure this with your evals from [09](09-evaluation-and-testing.md) — never assume.*
- **GGUF** is the file format you'll see everywhere for quantized models (the `llama.cpp`/Ollama ecosystem). A model tagged `Q4_K_M` is a 4-bit quantization; `Q8_0` is 8-bit. The `_K_M` bits are the specific quantization scheme — treat them as "quality tier" labels and benchmark rather than memorize.

The engineer's move: **quantization is a quality-vs-cost dial you tune with evals**, not a setting you pick by vibe. Our build project makes you turn that dial and record what happens.

## Hardware reality

Why does your beefy dev laptop choke on a 7B model while a hosted API answers instantly?

- **CPU vs GPU.** LLM inference is thousands of matrix multiplies. GPUs do those massively in parallel; CPUs plod through them. Running on CPU works for tiny models but is *slow* — think single-digit tokens/sec.
- **VRAM is the wall.** The model's weights (plus the KV cache, below) must fit in GPU memory. If they don't, you either can't load it or you spill to system RAM and speed collapses. A consumer GPU has 8–24 GB VRAM; that's why quantization matters so much locally.
- **Apple Silicon** is a pleasant exception: unified memory lets the GPU use a large shared pool, so Macs punch above their weight for local inference (this is why so much local-LLM tooling is Mac-first).

The honest takeaway: your laptop is a fine place to *learn* serving and to run small (1–8B) quantized models for dev. It is not where throughput lives. For that you need real GPUs, which is exactly the cost conversation that pushes most teams back toward hosted APIs.

> **GPU on Windows.** You have two ways to put an NVIDIA GPU under Ollama, and you don't need the NVIDIA Container Toolkit for either (that's for native Linux hosts):
>
> - **Native Ollama on Windows** uses the GPU directly with no Docker involved. Containers reach it at `http://host.docker.internal:11434`. This is the simplest option.
> - **Ollama in Docker Desktop** with the WSL2 backend and a current Windows NVIDIA driver: add `gpus: all` to the compose service (the compose files below have it commented out).
>
> Pick one. Both bind port 11434, so running both means one fails to start, or you benchmark a different server than you think. Details: [conventions](conventions.md#ollama). Without an NVIDIA GPU, Ollama runs on **CPU**. That's fine for this project: expect modest tokens/sec, and don't benchmark a 70B model on it. `ollama ps` tells you which one you got.

## Batching, KV cache, throughput vs latency

Two numbers describe inference performance, and they trade off:

- **Time-to-first-token (TTFT)** — latency. How long before the *first* token streams back. Dominated by the **prefill** phase: the model reads your whole prompt. Long prompts (big RAG contexts!) inflate TTFT.
- **Tokens/sec** — throughput of the **decode** phase, where tokens come out one at a time, each depending on the last.

Two mechanisms shape these:

**KV cache.** Generating token *N* requires attending to all previous tokens. Rather than recompute their key/value projections every step, the server caches them. That cache **grows with sequence length and lives in VRAM** — it's a major memory consumer alongside the weights, and it's why long conversations and huge contexts cost more than the token count alone suggests. (This is exactly what vLLM's PagedAttention manages efficiently.)

**Batching.** A GPU processing one request wastes most of its parallelism. Serving engines **batch** concurrent requests through the model together, dramatically raising *aggregate* tokens/sec — at a small latency cost to each individual request. **Continuous batching** (vLLM/TGI) slots new requests into the batch as others finish, instead of waiting for a whole batch to complete.

The engineer's framing — and it mirrors every server you've capacity-planned:

- **Latency-bound** (a chat UI, one user waiting): you care about TTFT and single-stream tokens/sec. Streaming helps *perceived* latency enormously — same reason you stream large responses in .NET.
- **Throughput-bound** (a batch job scoring 100k documents): you care about aggregate tokens/sec/dollar. Batch hard, don't care about per-request latency.

Ollama on your laptop is single-stream and unbatched — great for feeling TTFT and tokens/sec, useless for feeling batching. Just know the axis exists.

## When self-hosting is actually worth it

Be honest with yourself. Self-hosting an open model is worth the ops burden when **at least one** of these is true:

1. **Privacy/compliance forbids sending data out** — the strongest reason. Air-gapped, regulated, or contractually locked-in data.
2. **Volume is high and steady** enough that a busy GPU is cheaper per token than the API bill — and you can *keep it busy* (idle GPUs are the killer).
3. **You need control the API won't give** — a pinned version forever, a custom fine-tune ([16](16-fine-tuning-and-adaptation.md)), an exotic sampling setup, or on-prem/edge deployment.
4. **Latency/locality** — you need inference physically near the data or user and can't tolerate a round trip to a provider.

If none of these hold, **use a hosted API** and spend your ops budget elsewhere. Most teams reach for self-hosting too early, underestimate the GPU-babysitting, and would've been better off on Bedrock. The frontier-vs-open quality gap is real but shrinking; the ops gap is real and permanent.

## The build project

**`projects/10-local-serving/`**: run a small open model through Ollama, put a thin gateway in front of it, and **benchmark TTFT and tokens/sec across two quantization levels**, then score both quants with your module 09 eval. Record everything in one `NOTES.md`.

The model server is the part that doesn't care about your language. Both versions talk to the *same* Ollama. What you build twice is everything around it:

1. A gateway with `GET /health` and `POST /chat {"prompt": ...}` returning `{text, ttft_s, total_s, tokens_per_sec}`. A missing or empty `prompt` is a **422** in both languages.
2. A benchmark that streams the same three prompts through the int4 and int8 quants and prints median TTFT and tokens/sec.

Neither version writes model code. The model call is module 04's client, reused as a path dependency (Python) and a `ProjectReference` (C#), per the [backend contract](adr/001-backend-contract.md). So `LLM_BACKEND=stub` works here too, which is what the tests and the cross-check run on. This module adds only the *timing* around 04's streaming call. The C# benchmark also adds a concurrency knob and percentiles, and the C# section covers the .NET option Python developers rarely reach for: running the model in-process.

### Layout

```
projects/10-local-serving/
├── NOTES.md                         # your lab notebook for both languages: the numbers go here
├── python/
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── Dockerfile                   # build context: projects/ (reaches 04-llm-client)
│   ├── Dockerfile.dockerignore      # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example                 # committed; copy to .env (git-ignored)
│   ├── app/
│   │   ├── __init__.py
│   │   ├── timing.py                # TTFT, total time, chunk count around 04's stream()
│   │   ├── main.py                  # FastAPI gateway
│   │   └── benchmark.py             # tokens/sec + TTFT per quant
│   └── tests/
│       ├── test_gateway.py          # stub and a fake Ollama server; the JSON contract; the 422
│       └── test_timing.py
└── csharp/
    ├── LocalServing.slnx
    ├── Directory.Build.props        # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                   # build context: projects/
    ├── Dockerfile.dockerignore      # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   └── LocalServing/
    │       ├── LocalServing.csproj  # references 04-llm-client's LlmClient
    │       ├── appsettings.json     # from the webapi template
    │       ├── StreamingTimer.cs    # TTFT + tokens/sec from a streamed response
    │       ├── Benchmark.cs         # concurrency, percentiles
    │       ├── BenchCommand.cs      # the `bench` subcommand
    │       └── Program.cs           # minimal API gateway
    └── tests/
        └── LocalServing.Tests/
            ├── LocalServing.Tests.csproj    # NUnit
            ├── FakeStreamingChatClient.cs
            ├── StreamingTimerTests.cs       # also holds StatsTests
            └── GatewayTests.cs              # WebApplicationFactory<Program>, on the stub
```

No model weights live in the repo. Ollama keeps them in the shared `ai-learn-ollama` volume (or its own folder when it runs natively), and the repo's `.gitignore` already excludes `models/`, `*.gguf` and `*.onnx` for the in-process option below.

### Ports, and what else wants them

This module's stacks share host ports with stacks you've already built. Two stacks that publish the same port can't run together ([conventions](conventions.md#ports)):

| Port | Who wants it |
|---|---|
| 11434 | native Ollama, the `ollama` service in 04's compose files and 07's C# one, and this module's opt-in `ollama` profile. Run exactly one. |
| 8000 | this Python gateway, and module 07's Python RAG service (which the eval recipe below needs) |
| 8001 | this C# gateway, and module 07's C# RAG service |

The gateway services here don't start their own Ollama. They call `host.docker.internal:11434`, which is whichever Ollama you're running: native, or one started with `--profile ollama`. This module's Ollama service mounts the same `ai-learn-ollama` volume as 04's, so a model pulled in one stack is there in the others. If 04's or 07's stack is up, `docker compose down` in its folder first, or just use its Ollama.

## Python implementation

Work in `projects/10-local-serving/python/`. It's a [service](conventions.md#python-project-shapes): code in `app/` at the `python/` root, never installed. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 10-local-serving -Mode app
cd projects/10-local-serving/python
Remove-Item tests/test_smoke.py
uv add --editable ../../04-llm-client/python
uv add fastapi uvicorn httpx
```

The script already wrote `pythonpath = ["."]` under `[tool.pytest.ini_options]` and added pytest as a dev dependency, so the tests can import `app`. The resulting `pyproject.toml`:

```toml
[project]
name = "local-serving"
version = "0.1.0"
description = "Add your description here"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.142.2",
    "httpx>=0.28.1",
    "llm-client",
    "uvicorn>=0.54.0",
]

[tool.pytest.ini_options]
pythonpath = ["."]

[tool.uv.sources]
llm-client = { path = "../../04-llm-client/python", editable = true }

[dependency-groups]
dev = [
    "pytest>=9.1.1",
]
```

### `app/timing.py`: timing 04's stream

There's no new client here. 04's `LlmClient.stream()` already does the HTTP, the SSE parsing and the retries, and it's what you'd ship. This module only wants three numbers from the outside of that call: when the first chunk arrived, when the last one did, and how many chunks there were. A stream chunk is roughly one token on Ollama and vLLM, which is close enough for a benchmark, and the C# side checks how close.

```python
# app/timing.py
import time
from dataclasses import dataclass

from llm_client.types import LlmClient, Message

MAX_TOKENS = 512  # the same cap on both sides, or tokens/sec isn't comparable


@dataclass(frozen=True)
class ChatResult:
    text: str
    ttft_s: float           # time to first token
    total_s: float          # wall clock, whole response
    completion_tokens: int  # stream chunks: ~1 token per chunk on Ollama and vLLM

    @property
    def tokens_per_sec(self) -> float:
        # End to end, prefill included. Decode-only speed is tokens / (total - ttft).
        return self.completion_tokens / self.total_s if self.total_s > 0 else 0.0


async def timed_chat(client: LlmClient, prompt: str) -> ChatResult:
    """Stream one completion through module 04's client and time it from the outside."""
    start = time.perf_counter()
    ttft: float | None = None
    chunks: list[str] = []
    async for delta in client.stream([Message("user", prompt)], max_tokens=MAX_TOKENS):
        if ttft is None:
            ttft = time.perf_counter() - start  # first visible token
        chunks.append(delta)
    total = time.perf_counter() - start
    return ChatResult(
        text="".join(chunks),
        ttft_s=total if ttft is None else ttft,
        total_s=total,
        completion_tokens=len(chunks),
    )
```

`MAX_TOKENS` is passed explicitly because a benchmark's output length is part of the measurement. 04's default happens to be the same 512, but the C# side has to set it, so both say it.

### `app/main.py`: the FastAPI gateway

```python
# app/main.py
"""A thin chat gateway. Callers depend on THIS contract, not on Ollama: point
LLM_BACKEND / OLLAMA_BASE_URL / LLM_BASE_URL somewhere else and nothing above changes."""
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, FastAPI
from pydantic import BaseModel, Field

from llm_client.factory import client_from_env
from llm_client.types import LlmClient

from .timing import timed_chat

app = FastAPI(title="local-serving-gateway")


@lru_cache
def get_client() -> LlmClient:
    """Built on first use from LLM_BACKEND, then reused. Tests override this dependency."""
    return client_from_env()


class ChatRequest(BaseModel):
    prompt: str = Field(min_length=1)  # missing or empty -> 422, same as the C# gateway


class ChatResponse(BaseModel):
    text: str
    ttft_s: float
    total_s: float
    tokens_per_sec: float


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat")
async def chat(req: ChatRequest, client: Annotated[LlmClient, Depends(get_client)]) -> ChatResponse:
    r = await timed_chat(client, req.prompt)
    return ChatResponse(text=r.text, ttft_s=r.ttft_s, total_s=r.total_s, tokens_per_sec=r.tokens_per_sec)
```

`get_client` is a FastAPI *dependency*: the endpoint asks for an `LlmClient` and FastAPI supplies one. It's constructor injection, and `app.dependency_overrides` is how tests swap it, the way `ConfigureTestServices` does in ASP.NET Core. `@lru_cache` with no arguments makes it a lazy singleton. `Field(min_length=1)` is what makes an empty prompt a 422 as well as a missing one.

### `app/benchmark.py`: turn the quantization dial

```python
# app/benchmark.py
"""Turn the quantization dial: the same prompts through two quants of one model.

    uv run python -m app.benchmark
    uv run python -m app.benchmark --models llama3.2:3b-instruct-q4_K_M,llama3.2:3b-instruct-q8_0
"""
import argparse
import asyncio
import os
import statistics
from dataclasses import dataclass

from llm_client.factory import client_from_env
from llm_client.types import LlmClient

from .timing import ChatResult, timed_chat

PROMPTS = [
    "Summarize the CAP theorem in two sentences.",
    "Write a Python function that reverses a linked list.",
    "List three trade-offs of microservices vs a monolith.",
]
DEFAULT_MODELS = "llama3.2:3b-instruct-q4_K_M,llama3.2:3b-instruct-q8_0"


@dataclass(frozen=True)
class BenchStats:
    results: list[ChatResult]

    @property
    def ttft_median(self) -> float:
        return statistics.median(r.ttft_s for r in self.results)

    @property
    def tps_median(self) -> float:
        return statistics.median(r.tokens_per_sec for r in self.results)

    @property
    def chunks(self) -> int:
        return sum(r.completion_tokens for r in self.results)


def client_for(model: str) -> LlmClient:
    """client_from_env() with the model swapped. The quant tags are Ollama tags, so this sets
    OLLAMA_MODEL, and LLM_MODEL for an OpenAI-compatible server in front of the same models.
    The stub ignores both."""
    override = {"OLLAMA_MODEL": model, "LLM_MODEL": model}
    saved = {k: os.environ.get(k) for k in override}
    os.environ.update(override)
    try:
        return client_from_env()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


async def bench(client: LlmClient, prompts: list[str]) -> BenchStats:
    # Warm-up, not counted: the first request pays for loading the weights into memory.
    await timed_chat(client, "Reply with OK.")
    return BenchStats([await timed_chat(client, p) for p in prompts])  # one at a time, on purpose


async def main(models: list[str]) -> None:
    for model in models:
        s = await bench(client_for(model), PROMPTS)
        print(f"\n== {model} ==")
        print(f"  TTFT   median: {s.ttft_median:6.2f} s")
        print(f"  tok/s  median: {s.tps_median:6.1f}")
        print(f"  chunks counted as tokens: {s.chunks}  (compare the out= values in the llm_call lines)")
    print("\nRecord these in NOTES.md, then run the module 09 eval against each quant.")
    print("Cheaper is only better if it's still good.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TTFT and tokens/sec per model")
    parser.add_argument("--models", default=DEFAULT_MODELS, help="comma-separated Ollama tags")
    asyncio.run(main(parser.parse_args().models.split(",")))
```

`client_for` puts the model into the environment only long enough for 04's factory to read it. That keeps one rule for picking a backend: `LLM_BACKEND`, in every module. The prompts run one at a time on purpose. A single-stream benchmark measures latency. The C# side adds the concurrency knob.

### Tests

No test touches a model. The gateway tests run on 04's `StubClient`, plus one with a fake server *under* 04's real `OllamaClient` (`httpx.MockTransport`, as in module 04), so the `/v1` URL and the SSE parsing are exercised end to end.

```python
# tests/test_gateway.py
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app, get_client
from llm_client.ollama import OllamaClient
from llm_client.stub import StubClient


@pytest.fixture
def gateway():
    """The gateway over module 04's stub: no network, no model."""
    app.dependency_overrides[get_client] = lambda: StubClient()
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_chat_returns_the_contract_keys(gateway):
    # The same keys the C# GatewayTests pin: a client of one gateway works against the other.
    body = gateway.post("/chat", json={"prompt": "hi"}).json()
    assert set(body) == {"text", "ttft_s", "total_s", "tokens_per_sec"}
    assert body["text"] == "stub: hi"
    assert 0 <= body["ttft_s"] <= body["total_s"]


@pytest.mark.parametrize("payload", [{}, {"prompt": ""}])
def test_missing_or_empty_prompt_is_422(gateway, payload):
    assert gateway.post("/chat", json=payload).status_code == 422


def test_health(gateway):
    assert gateway.get("/health").json() == {"status": "ok"}


def sse(*deltas: str) -> bytes:
    """An OpenAI-style stream: one data: line per delta, then [DONE]."""
    events = [{"choices": [{"delta": {"content": d}, "finish_reason": None}]} for d in deltas]
    lines = [f"data: {json.dumps(e)}\n\n" for e in events] + ["data: [DONE]\n\n"]
    return "".join(lines).encode()


def test_chat_over_a_fake_ollama_server():
    # A fake server UNDER 04's real OllamaClient, so the SSE parsing and the /v1 URL are exercised too.
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, content=sse("Hel", "lo", "!"), headers={"content-type": "text/event-stream"})

    client = OllamaClient("http://ollama:11434", "llama3.2:3b", transport=httpx.MockTransport(handler))
    app.dependency_overrides[get_client] = lambda: client
    try:
        body = TestClient(app).post("/chat", json={"prompt": "hi"}).json()
    finally:
        app.dependency_overrides.clear()

    assert seen == ["http://ollama:11434/v1/chat/completions"]
    assert body["text"] == "Hello!"
    assert body["tokens_per_sec"] > 0
```

```python
# tests/test_timing.py
import asyncio
import os

from app.benchmark import PROMPTS, bench, client_for
from app.timing import ChatResult, timed_chat
from llm_client.stub import StubClient


def test_timed_chat_concatenates_and_counts_chunks():
    r = asyncio.run(timed_chat(StubClient(["a b c"]), "hi"))
    assert r.text == "a b c"
    assert r.completion_tokens == 3  # the stub streams one word per chunk
    assert 0 <= r.ttft_s <= r.total_s


def test_tokens_per_sec_is_end_to_end():
    assert ChatResult("x", ttft_s=0.5, total_s=2.0, completion_tokens=10).tokens_per_sec == 5.0
    assert ChatResult("", ttft_s=0.0, total_s=0.0, completion_tokens=0).tokens_per_sec == 0.0


def test_bench_times_every_prompt_on_the_stub():
    s = asyncio.run(bench(StubClient(), PROMPTS))
    assert len(s.results) == len(PROMPTS)
    assert s.chunks == sum(len(f"stub: {p}".split()) for p in PROMPTS)  # one word per chunk


def test_client_for_restores_the_environment(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.delenv("OLLAMA_MODEL", raising=False)
    assert isinstance(client_for("llama3.2:3b-instruct-q8_0"), StubClient)
    assert "OLLAMA_MODEL" not in os.environ
```

```powershell
uv run pytest
```

Recent Starlette versions print a deprecation warning about the test client's `httpx`. It's harmless here.

### Configuration

```bash
# projects/10-local-serving/python/.env.example: copy to .env. Compose reads it; never commit .env.
LLM_BACKEND=ollama
OLLAMA_MODEL=llama3.2:3b
# Leave OLLAMA_BASE_URL unset: compose defaults it to host.docker.internal:11434,
# and local runs default to localhost:11434.
# To go through an OpenAI-compatible /v1 instead (Ollama's own, or vLLM):
# LLM_BACKEND=hosted
# LLM_BASE_URL=http://host.docker.internal:11434/v1
# LLM_API_KEY=ollama
# LLM_MODEL=llama3.2:3b
# Rates__InputPerMTok=0
# Rates__OutputPerMTok=0
```

The C# compose file reads the same names from its own `.env`.

### Running the Python version

Offline first, on the stub. Nothing needs a model:

```powershell
$env:LLM_BACKEND = 'stub'
uv run python -m app.benchmark                       # silly numbers, but every line of the path runs
uv run --no-sync uvicorn app.main:app --port 8000    # then, from another terminal:
Invoke-RestMethod http://localhost:8000/chat -Method Post -ContentType application/json -Body '{"prompt":"hi"}'
Remove-Item Env:LLM_BACKEND                          # back to the default, ollama
```

Then against a real model. Start Ollama one way, [natively or in compose](conventions.md#ollama), and pull the base model and both quants:

```powershell
# Native Ollama:
ollama pull llama3.2:3b
ollama pull llama3.2:3b-instruct-q4_K_M
ollama pull llama3.2:3b-instruct-q8_0

# Or Ollama in compose (stop native Ollama first: both want port 11434):
docker compose --profile ollama up -d ollama
docker compose exec ollama ollama pull llama3.2:3b
docker compose exec ollama ollama pull llama3.2:3b-instruct-q4_K_M
docker compose exec ollama ollama pull llama3.2:3b-instruct-q8_0
```

`llama3.2:3b` is probably the same weights as the `q4_K_M` tag (it's Ollama's default quant for that model). If `ollama show` agrees, the pull costs nothing extra. Then benchmark from your machine, which reaches Ollama on `localhost:11434` either way:

```powershell
uv run python -m app.benchmark
uv run python -m app.benchmark --models llama3.2:3b-instruct-q4_K_M,llama3.2:3b-instruct-q8_0,llama3.2:1b
```

The `llm_call` lines on stderr are 04's cost log. Their `out=` is the token count Ollama reported, which you can hold against the chunk count the benchmark prints.

### Running the Python gateway in Docker

The image needs 04's library, so the build context widens to `projects/` and the Dockerfile copies the two projects into the same relative layout they have in the repo. `Dockerfile.dockerignore` (from the bootstrap script) sits next to the Dockerfile, and its `**/` patterns apply at any depth of that wider context.

```dockerfile
# projects/10-local-serving/python/Dockerfile. Build context: projects/ (to reach 04-llm-client)
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
# Mirror the repo layout, so uv.lock's "../../04-llm-client/python" resolves inside the image.
WORKDIR /src/10-local-serving/python
COPY 04-llm-client/python/pyproject.toml 04-llm-client/python/README.md /src/04-llm-client/python/
COPY 04-llm-client/python/src/ /src/04-llm-client/python/src/
# Service shape: locked deps (llm_client included) on a cached layer, then the code. Nothing is installed.
COPY 10-local-serving/python/pyproject.toml 10-local-serving/python/uv.lock ./
RUN uv sync --frozen --no-install-project
COPY 10-local-serving/python/app/ ./app/
EXPOSE 8000
CMD ["uv", "run", "--no-sync", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

```yaml
# projects/10-local-serving/python/compose.yaml
name: local-serving-py   # otherwise the project is named after the folder: "python"
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]     # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]
    # NVIDIA GPU on Docker Desktop (WSL2 backend, current Windows driver): uncomment.
    # gpus: all

  gateway-py:
    build:
      context: ../..                                   # projects/, to reach 04-llm-client
      dockerfile: 10-local-serving/python/Dockerfile
    ports: ["8000:8000"]
    env_file:
      - path: .env             # hosted keys, rates and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      # Native Ollama and the ollama profile both answer on the host's port 11434.
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2:3b}
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

The `ollama` service sits behind a [profile](https://docs.docker.com/compose/how-tos/profiles/), so `docker compose up` doesn't start it unless you ask. That's how one compose file serves both ways of running Ollama.

```powershell
cd projects/10-local-serving/python
docker compose up -d --build gateway-py
Invoke-RestMethod http://localhost:8000/chat -Method Post -ContentType application/json -Body '{"prompt":"explain a b-tree in one sentence"}'
docker compose run --rm -e LLM_BACKEND=stub gateway-py uv run --no-sync python -m app.benchmark
```

Without compose, from the repo root: `docker build -f projects/10-local-serving/python/Dockerfile -t local-serving-py projects`.

### Eval score per quantization level

Tokens/sec says the int4 quant is cheaper. Only an eval says whether it's still *good*. You have all the pieces: module 07's RAG service reads `OLLAMA_MODEL`, and module 09's harness scores whatever answers on `RAG_URL`. So restart 07 on each quant and run 09 against it. Steps, for the Python services:

1. **Free port 8000.** Module 07's Python service publishes it, and so does this gateway. From `projects/10-local-serving/python`: `docker compose stop gateway-py`. Keep Ollama running, with both quants pulled (above).
2. **Start 07 on the int4 quant.** Compose fills `${OLLAMA_MODEL}` from your shell, and 07 already reaches Ollama on `host.docker.internal:11434`. From `projects/07-rag-service/python`:
   ```powershell
   $env:LLM_BACKEND = 'ollama'; $env:OLLAMA_MODEL = 'llama3.2:3b-instruct-q4_K_M'
   docker compose up -d --force-recreate
   ```
   If the vector store is empty (first run), ingest the corpus as module 07 shows. Ask it one question, then check `ollama ps` (or `docker compose --profile ollama exec ollama ollama ps` from this module's folder): the quant you asked for should be the one loaded.
3. **Score it.** From `projects/09-eval-harness/python`, with the judge pinned so only the system under test changes:
   ```powershell
   $env:RAG_URL = 'http://localhost:8000'; $env:JUDGE_MODEL = 'llama3.2'   # the judge you used in 09; same for both runs
   uv run pytest -m eval -s
   ```
   Copy the scorecard into `NOTES.md`. A failing gate is a result too: write it down.
4. **Repeat for int8.** Back in step 2 with `$env:OLLAMA_MODEL = 'llama3.2:3b-instruct-q8_0'`, then step 3.
5. **Clean up** the shell: `Remove-Item Env:OLLAMA_MODEL, Env:RAG_URL, Env:JUDGE_MODEL`, and `docker compose down` in 07's folder before you restart this gateway.

The C# services run the same recipe: C# 07 on port 8001, and `$env:RAG_URL = 'http://localhost:8001'` with module 09's `dotnet test --settings eval.runsettings` (and `$env:JUDGE_MODEL`, as above). A `--filter` there would combine with the default run settings' filter and select nothing.

### `NOTES.md`

One notebook for both languages, at the project root. A shape that answers the Checkpoint:

```markdown
<!-- projects/10-local-serving/NOTES.md -->
Hardware: CPU / GPU model, VRAM, RAM. Ollama: native or compose. `ollama ps` says: GPU / CPU.
Tokens/sec definition: end to end (tokens / total_s), prefill included.

| Quant | TTFT median (py / cs) | tok/s median (py / cs) | C# tokens per chunk | 09 eval scorecard (contains_all / similarity / judge) |
|---|---|---|---|---|
| q4_K_M | | | | |
| q8_0 | | | | |

C# bench --concurrency 4 --repeats 3: TTFT p95 ..., aggregate tok/s ...
Verdict: was the cheaper quant worth it on this task? Why?
```

## C# implementation

Work in `projects/10-local-serving/csharp/`. Same Ollama, same endpoints, same prompts and models, same env vars. What changes:

- **No streaming code of your own, in either language now.** The C# gateway takes `IChatClient` from 04's `AddLlmClient` and streams with `GetStreamingResponseAsync`. Note one wire difference: 04's C# `ollama` backend uses OllamaSharp and Ollama's *native* API, while Python's goes through `/v1`. To put C# on Python's exact path, use `LLM_BACKEND=hosted` with `LLM_BASE_URL=http://localhost:11434/v1`. Switching is configuration, which is the module's point.
- **Real token counts when the backend reports them.** Python counts stream chunks. The C# timer reads `UsageContent` from the stream when it's there and falls back to the chunk count when it isn't. It keeps both, so the benchmark can tell you how far off Python's "1 chunk ≈ 1 token" is.
- **A benchmark with load.** Python runs prompts one at a time. The C# benchmark adds `--concurrency` and `--repeats`, and reports p95 and aggregate tokens/sec. That's the axis the batching section talks about. Ollama won't batch like vLLM, but you will see queueing push TTFT up.
- **One executable, two modes.** `dotnet LocalServing.dll` serves HTTP. `dotnet LocalServing.dll bench` runs the benchmark. That mirrors `uvicorn app.main:app` vs `python -m app.benchmark` from the same image.

### Scaffold

From the repo root, create the C# side as a web API (see [project bootstrap automation](project-bootstrap-automation.md)), delete the sample bits and reference 04's library:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 10-local-serving -Template webapi -Name LocalServing
cd projects/10-local-serving/csharp
Remove-Item tests/LocalServing.Tests/SmokeTests.cs, src/LocalServing/LocalServing.http
dotnet remove src/LocalServing package Microsoft.AspNetCore.OpenApi
dotnet add src/LocalServing reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add tests/LocalServing.Tests package Microsoft.AspNetCore.Mvc.Testing
```

Microsoft.Extensions.AI and OllamaSharp come in through 04's project reference, so there are no AI packages to add. `Program.cs` is replaced below, which removes the WeatherForecast sample. This doc was built against 04's package versions plus Microsoft.AspNetCore.Mvc.Testing 10.0.

### `src/LocalServing/StreamingTimer.cs`

The C# counterpart of `timed_chat`. `Stopwatch.GetTimestamp` / `GetElapsedTime` are the allocation-free versions of `time.perf_counter()`.

```csharp
// src/LocalServing/StreamingTimer.cs
using System.Diagnostics;
using System.Text;
using Microsoft.Extensions.AI;

namespace LocalServing;

/// <summary>One streamed completion, timed. Python's ChatResult, plus the raw chunk count.</summary>
public sealed record ChatResult(string Text, double TtftS, double TotalS, int CompletionTokens, int Chunks)
{
    // End to end, prefill included: the same formula as Python. Decode-only is tokens / (total - ttft).
    public double TokensPerSec => TotalS > 0 ? CompletionTokens / TotalS : 0.0;
}

public static class StreamingTimer
{
    // The same cap as Python's MAX_TOKENS, or tokens/sec isn't comparable.
    private static readonly ChatOptions Options = new() { MaxOutputTokens = 512 };

    public static async Task<ChatResult> MeasureAsync(IChatClient client, string prompt, CancellationToken ct = default)
    {
        long start = Stopwatch.GetTimestamp();
        TimeSpan? ttft = null;
        var text = new StringBuilder();
        int chunks = 0;
        long? reportedTokens = null;

        await foreach (ChatResponseUpdate update in client.GetStreamingResponseAsync(prompt, Options, ct))
        {
            if (!string.IsNullOrEmpty(update.Text))
            {
                ttft ??= Stopwatch.GetElapsedTime(start);   // first visible token
                text.Append(update.Text);
                chunks++;
            }
            // Backends that report usage send it as UsageContent, usually on the last update.
            foreach (UsageContent usage in update.Contents.OfType<UsageContent>())
                reportedTokens = usage.Details.OutputTokenCount ?? reportedTokens;
        }

        double total = Stopwatch.GetElapsedTime(start).TotalSeconds;
        return new ChatResult(
            Text: text.ToString(),
            TtftS: ttft?.TotalSeconds ?? total,
            TotalS: total,
            // Prefer the server's count; fall back to Python's "1 chunk ~= 1 token".
            CompletionTokens: (int)(reportedTokens ?? chunks),
            Chunks: chunks);
    }
}
```

Whether usage shows up depends on the backend. OllamaSharp's native API reports it, 04's stub reports it, and an OpenAI-compatible server reports it when the client asks (`stream_options.include_usage`). The `Chunks` field is there so you can see which path you got.

### `src/LocalServing/Benchmark.cs`

`Parallel.ForEachAsync` with `MaxDegreeOfParallelism` caps how many requests are in flight. It's the built-in version of the `SemaphoreSlim` + `Task.WhenAll` pattern in 04's `Batch.cs`.

```csharp
// src/LocalServing/Benchmark.cs
using System.Diagnostics;
using Microsoft.Extensions.AI;

namespace LocalServing;

public static class Stats
{
    /// <summary>Linear-interpolated percentile, p in [0, 1]. p = 0.5 matches Python's statistics.median.</summary>
    public static double Percentile(IEnumerable<double> values, double p)
    {
        double[] sorted = values.Order().ToArray();
        if (sorted.Length == 0)
            return 0.0;
        double rank = p * (sorted.Length - 1);
        int lo = (int)Math.Floor(rank), hi = (int)Math.Ceiling(rank);
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
    }
}

public sealed record BenchStats(int Concurrency, IReadOnlyList<ChatResult> Results, TimeSpan Wall)
{
    public double TtftMedian => Stats.Percentile(Results.Select(r => r.TtftS), 0.5);
    public double TtftP95 => Stats.Percentile(Results.Select(r => r.TtftS), 0.95);
    public double TpsMedian => Stats.Percentile(Results.Select(r => r.TokensPerSec), 0.5);

    // How far off "1 chunk ~= 1 token" is: 1.0 when the backend reports no usage (the count IS the chunks).
    public double TokensPerChunk =>
        Results.Sum(r => r.Chunks) is int chunks and > 0 ? (double)Results.Sum(r => r.CompletionTokens) / chunks : 0.0;

    // What a capacity plan cares about: every token produced, divided by wall-clock time.
    public double AggregateTps => Wall.TotalSeconds > 0 ? Results.Sum(r => r.CompletionTokens) / Wall.TotalSeconds : 0.0;
}

public static class Benchmark
{
    public static async Task<BenchStats> RunAsync(
        IChatClient client, IReadOnlyList<string> prompts, int concurrency, int repeats, CancellationToken ct = default)
    {
        // Warm-up, not counted: the first request pays for loading the weights into memory.
        await StreamingTimer.MeasureAsync(client, "Reply with OK.", ct);

        string[] work = Enumerable.Repeat(prompts, repeats).SelectMany(p => p).ToArray();
        var results = new ChatResult[work.Length];

        long start = Stopwatch.GetTimestamp();
        await Parallel.ForEachAsync(
            Enumerable.Range(0, work.Length),
            new ParallelOptions { MaxDegreeOfParallelism = concurrency, CancellationToken = ct },
            async (i, token) => results[i] = await StreamingTimer.MeasureAsync(client, work[i], token));

        return new BenchStats(concurrency, results, Stopwatch.GetElapsedTime(start));
    }
}
```

### `src/LocalServing/BenchCommand.cs`

```csharp
// src/LocalServing/BenchCommand.cs
using System.Globalization;
using LlmClient;
using Microsoft.Extensions.AI;

namespace LocalServing;

/// <summary>`bench [--models a,b] [--concurrency N] [--repeats N]`. Same prompts and models as benchmark.py.</summary>
public static class BenchCommand
{
    private static readonly string[] Prompts =
    [
        "Summarize the CAP theorem in two sentences.",
        "Write a Python function that reverses a linked list.",
        "List three trade-offs of microservices vs a monolith.",
    ];

    private const string DefaultModels = "llama3.2:3b-instruct-q4_K_M,llama3.2:3b-instruct-q8_0";

    public static async Task<int> RunAsync(string[] args, IConfiguration config, CancellationToken ct = default)
    {
        string[] models = Opt(args, "--models", DefaultModels).Split(',');
        int concurrency = int.Parse(Opt(args, "--concurrency", "1"), CultureInfo.InvariantCulture);
        int repeats = int.Parse(Opt(args, "--repeats", "1"), CultureInfo.InvariantCulture);
        var inv = CultureInfo.InvariantCulture;

        foreach (string model in models)
        {
            await using ServiceProvider services = ServicesFor(config, model);
            IChatClient client = services.GetRequiredService<IChatClient>();

            BenchStats s = await Benchmark.RunAsync(client, Prompts, concurrency, repeats, ct);
            Console.WriteLine($"\n== {model} ==");
            Console.WriteLine(string.Create(inv, $"  TTFT   median: {s.TtftMedian,6:F2} s   p95: {s.TtftP95,6:F2} s"));
            Console.WriteLine(string.Create(inv, $"  tok/s  median: {s.TpsMedian,6:F1}"));
            Console.WriteLine(string.Create(inv, $"  tokens per chunk: {s.TokensPerChunk,6:F2}"));
            Console.WriteLine(string.Create(inv, $"  aggregate tok/s at concurrency {concurrency}: {s.AggregateTps,6:F1}"));
        }

        Console.WriteLine("\nRecord these in NOTES.md, then run the module 09 eval against each quant.");
        Console.WriteLine("Cheaper is only better if it's still good.");
        return 0;
    }

    /// <summary>
    /// Module 04's AddLlmClient with the model swapped. The quant tags are Ollama tags, so this sets
    /// OLLAMA_MODEL, and LLM_MODEL for an OpenAI-compatible server in front of the same models.
    /// </summary>
    private static ServiceProvider ServicesFor(IConfiguration config, string model)
    {
        IConfiguration withModel = new ConfigurationBuilder()
            .AddConfiguration(config)
            .AddInMemoryCollection(new Dictionary<string, string?> { ["OLLAMA_MODEL"] = model, ["LLM_MODEL"] = model })
            .Build();
        var services = new ServiceCollection().AddLogging();   // no providers: the llm_call lines stay quiet
        services.AddLlmClient(withModel);
        return services.BuildServiceProvider();
    }

    private static string Opt(string[] args, string name, string fallback)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback;
    }
}
```

`ServicesFor` is the twin of Python's `client_for`: the same `AddLlmClient` the gateway uses, with the model swapped in through an in-memory configuration layer, which wins over the environment because it's added last. Each model gets its own service provider, disposed when its run ends.

04's client retries 429s and 5xx, and gives each attempt 90 seconds. That's right for an app and can mislead a benchmark: a retried request looks like one slow request, and a slow CPU model can run into the attempt timeout. If a number looks wrong, check the `llm_call` lines and the retry settings before you believe it.

### `src/LocalServing/Program.cs`

FastAPI returns snake_case because the Pydantic fields are snake_case. ASP.NET Core defaults to camelCase, so set the naming policy once and the records serialize to the same contract.

```csharp
// src/LocalServing/Program.cs
using System.Text.Json;
using LlmClient;
using LocalServing;
using Microsoft.Extensions.AI;

if (args is ["bench", .. var rest])
    return await BenchCommand.RunAsync(rest, new ConfigurationBuilder().AddEnvironmentVariables().Build());

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);

// The gateway depends on IChatClient, not on Ollama: module 04 picks the backend from LLM_BACKEND.
builder.Services.AddLlmClient(builder.Configuration);

var app = builder.Build();

app.MapGet("/health", () => new { status = "ok" });

app.MapPost("/chat", async (PromptRequest req, IChatClient client, CancellationToken ct) =>
{
    // Missing or empty prompt -> 422, the status FastAPI gives for the same body.
    if (string.IsNullOrEmpty(req.Prompt))
        return Results.ValidationProblem(
            new Dictionary<string, string[]> { ["prompt"] = ["A non-empty prompt is required."] },
            statusCode: StatusCodes.Status422UnprocessableEntity);

    ChatResult r = await StreamingTimer.MeasureAsync(client, req.Prompt, ct);
    return Results.Ok(new ChatReply(r.Text, r.TtftS, r.TotalS, r.TokensPerSec));
});

await app.RunAsync();
return 0;

// string? because a body without "prompt" binds to null; the check above turns that into a 422.
public sealed record PromptRequest(string? Prompt);
public sealed record ChatReply(string Text, double TtftS, double TotalS, double TokensPerSec);

public partial class Program;   // lets WebApplicationFactory<Program> find the entry point
```

A missing `prompt` binds to `null` rather than failing, so the endpoint checks it and returns 422 with a problem-details body, the status FastAPI gives. The bodies differ (FastAPI returns `{"detail": [...]}`); the status code is the contract. `ChatReply` rather than `ChatResponse`, because `Microsoft.Extensions.AI` already has a `ChatResponse` and the clash gets confusing fast.

### Tests

No test touches a model. The gateway tests run on 04's stub by setting `LLM_BACKEND=stub` through `UseSetting`, which reaches `builder.Configuration` before `AddLlmClient` reads it. The timer tests use a fake `IChatClient` that streams canned chunks with a delay, so TTFT is measurable.

```csharp
// tests/LocalServing.Tests/FakeStreamingChatClient.cs
using System.Runtime.CompilerServices;
using Microsoft.Extensions.AI;

namespace LocalServing.Tests;

/// <summary>Streams canned chunks with a small delay, optionally followed by a usage update.</summary>
public sealed class FakeStreamingChatClient(string[] chunks, long? reportedOutputTokens = null, int delayMs = 5) : IChatClient
{
    public async IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        foreach (string chunk in chunks)
        {
            await Task.Delay(delayMs, cancellationToken);
            yield return new ChatResponseUpdate(ChatRole.Assistant, chunk);
        }
        if (reportedOutputTokens is long n)
            yield return new ChatResponseUpdate { Contents = [new UsageContent(new UsageDetails { OutputTokenCount = n })] };
    }

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages, ChatOptions? options = null, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("The gateway only streams.");

    public object? GetService(Type serviceType, object? serviceKey = null) => null;
    public void Dispose() { }
}
```

```csharp
// tests/LocalServing.Tests/StreamingTimerTests.cs
using LlmClient;

namespace LocalServing.Tests;

public class StreamingTimerTests
{
    [Test]
    public async Task Concatenates_text_and_ttft_comes_before_total()
    {
        ChatResult r = await StreamingTimer.MeasureAsync(new FakeStreamingChatClient(["Hel", "lo", "!"]), "hi");
        Assert.That(r.Text, Is.EqualTo("Hello!"));
        Assert.That(r.TtftS, Is.GreaterThan(0).And.LessThanOrEqualTo(r.TotalS));
    }

    [Test]
    public async Task Prefers_reported_usage_over_chunk_count()
    {
        ChatResult r = await StreamingTimer.MeasureAsync(new FakeStreamingChatClient(["a", "b", "c"], reportedOutputTokens: 7), "hi");
        Assert.That(r.Chunks, Is.EqualTo(3));
        Assert.That(r.CompletionTokens, Is.EqualTo(7));
    }

    [Test]
    public async Task Falls_back_to_chunks_without_usage()
    {
        ChatResult r = await StreamingTimer.MeasureAsync(new FakeStreamingChatClient(["a", "b", "c"]), "hi");
        Assert.That(r.CompletionTokens, Is.EqualTo(3));
    }

    [Test]
    public async Task Stub_counts_match_python()
    {
        // Module 04's stub streams one word per chunk and reports the word count: test_timing.py's numbers.
        ChatResult r = await StreamingTimer.MeasureAsync(new StubChatClient(["a b c"]), "hi");
        Assert.That(r.Text, Is.EqualTo("a b c"));
        Assert.That((r.Chunks, r.CompletionTokens), Is.EqualTo((3, 3)));
    }

    [Test]
    public void Tokens_per_sec_is_end_to_end()
    {
        Assert.That(new ChatResult("x", TtftS: 0.5, TotalS: 2.0, CompletionTokens: 10, Chunks: 10).TokensPerSec, Is.EqualTo(5.0));
        Assert.That(new ChatResult("", 0, 0, 0, 0).TokensPerSec, Is.EqualTo(0.0));
    }

    [Test]
    public async Task Bench_times_every_prompt_on_the_stub()
    {
        BenchStats s = await Benchmark.RunAsync(new StubChatClient(), ["one", "two", "three"], concurrency: 2, repeats: 2);
        Assert.That(s.Results, Has.Count.EqualTo(6));
        Assert.That(s.TokensPerChunk, Is.EqualTo(1.0));   // the stub reports one token per streamed word
    }
}

public class StatsTests
{
    [TestCase(new[] { 3.0, 1.0, 2.0 }, 0.5, 2.0)]
    [TestCase(new[] { 1.0, 2.0, 3.0, 4.0 }, 0.5, 2.5)]          // even count: mean of the middle two, like statistics.median
    [TestCase(new[] { 1.0, 2.0, 3.0, 4.0, 5.0 }, 0.95, 4.8)]
    public void Percentile_interpolates(double[] values, double p, double expected) =>
        Assert.That(Stats.Percentile(values, p), Is.EqualTo(expected).Within(1e-9));
}
```

The gateway test pins the JSON contract and the 422. Its Python twin is `test_gateway.py`. If both pass, a client written against one gateway works against the other.

```csharp
// tests/LocalServing.Tests/GatewayTests.cs
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace LocalServing.Tests;

public class GatewayTests
{
    private WebApplicationFactory<Program> _factory = null!;
    private HttpClient _http = null!;

    [SetUp]
    public void SetUp()
    {
        // The gateway over module 04's stub: no network, no model.
        _factory = new WebApplicationFactory<Program>()
            .WithWebHostBuilder(b => b.UseSetting("LLM_BACKEND", "stub"));
        _http = _factory.CreateClient();
    }

    [TearDown]
    public void TearDown()
    {
        _http.Dispose();
        _factory.Dispose();
    }

    [Test]
    public async Task Chat_returns_the_same_keys_as_the_python_gateway()
    {
        using HttpResponseMessage resp = await _http.PostAsJsonAsync("/chat", new { prompt = "hi" });
        resp.EnsureSuccessStatusCode();
        using JsonDocument doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        JsonElement body = doc.RootElement;

        string[] keys = body.EnumerateObject().Select(p => p.Name).ToArray();
        Assert.That(keys, Is.EquivalentTo(new[] { "text", "ttft_s", "total_s", "tokens_per_sec" }));
        Assert.That(body.GetProperty("text").GetString(), Is.EqualTo("stub: hi"));
        Assert.That(body.GetProperty("ttft_s").GetDouble(), Is.LessThanOrEqualTo(body.GetProperty("total_s").GetDouble()));
    }

    [TestCase("{}")]
    [TestCase("""{"prompt": ""}""")]
    public async Task Missing_or_empty_prompt_is_422(string json)
    {
        using var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
        using HttpResponseMessage resp = await _http.PostAsync("/chat", content);
        Assert.That(resp.StatusCode, Is.EqualTo(HttpStatusCode.UnprocessableEntity));
    }

    [Test]
    public async Task Health()
    {
        var body = await _http.GetFromJsonAsync<Dictionary<string, string>>("/health");
        Assert.That(body, Is.EqualTo(new Dictionary<string, string> { ["status"] = "ok" }));
    }
}
```

Run locally. The tests need nothing; the benchmark needs Ollama on `localhost:11434` (native, or the `ollama` profile):

```powershell
dotnet test
dotnet test --filter "FullyQualifiedName~StatsTests"
$env:LLM_BACKEND = 'stub'; dotnet run --project src/LocalServing -- bench; Remove-Item Env:LLM_BACKEND
dotnet run --project src/LocalServing -- bench
dotnet run --project src/LocalServing -- bench --concurrency 4 --repeats 3
```

### Running the C# version in Docker

The same shape as the Python image: the context is `projects/`, the restore layer copies both projects' `.csproj` files (and 04's `Directory.Build.props`, which its library build reads), and there's a `test` target.

```dockerfile
# projects/10-local-serving/csharp/Dockerfile. Build context: projects/ (to reach 04-llm-client)
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
# Mirror the repo layout, so the ProjectReference to 04's LlmClient resolves inside the image.
WORKDIR /src
# Restore on its own layer: project files (and 04's Directory.Build.props) first.
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 10-local-serving/csharp/LocalServing.slnx 10-local-serving/csharp/Directory.Build.props 10-local-serving/csharp/
COPY 10-local-serving/csharp/src/LocalServing/LocalServing.csproj 10-local-serving/csharp/src/LocalServing/
COPY 10-local-serving/csharp/tests/LocalServing.Tests/LocalServing.Tests.csproj 10-local-serving/csharp/tests/LocalServing.Tests/
WORKDIR /src/10-local-serving/csharp
RUN dotnet restore
COPY 04-llm-client/csharp/src/LlmClient/ /src/04-llm-client/csharp/src/LlmClient/
COPY 10-local-serving/csharp/ ./
RUN dotnet publish src/LocalServing -c Release -o /app --no-restore

FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "LocalServing.dll"]
```

```yaml
# projects/10-local-serving/csharp/compose.yaml
name: local-serving-cs
services:
  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]     # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]
    # gpus: all            # NVIDIA GPU on Docker Desktop (WSL2 backend, current Windows driver)

  gateway-cs:
    build:
      context: ../..                                   # projects/, to reach 04-llm-client
      dockerfile: 10-local-serving/csharp/Dockerfile
      target: final
    ports: ["8001:8080"]       # listens on 8080 in the container, published on 8001
    env_file:
      - path: .env             # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2:3b}
    extra_hosts: ["host.docker.internal:host-gateway"]

  test:
    build:
      context: ../..
      dockerfile: 10-local-serving/csharp/Dockerfile
      target: test
    profiles: [test]           # only runs when asked for by name

volumes:
  ollama:
    name: ai-learn-ollama      # shared by every stack: each model downloads once
```

```powershell
cd projects/10-local-serving/csharp
docker compose up -d --build gateway-cs
Invoke-RestMethod http://localhost:8001/chat -Method Post -ContentType application/json -Body '{"prompt":"explain a b-tree in one sentence"}'
docker compose exec gateway-cs dotnet LocalServing.dll bench
docker compose exec gateway-cs dotnet LocalServing.dll bench --concurrency 4 --repeats 3
docker compose run --rm test
```

The same benchmark through Ollama's OpenAI-compatible `/v1` instead of its native API is a configuration change:

```powershell
docker compose exec -e LLM_BACKEND=hosted -e LLM_BASE_URL=http://host.docker.internal:11434/v1 -e LLM_API_KEY=ollama `
  -e Rates__InputPerMTok=0 -e Rates__OutputPerMTok=0 gateway-cs dotnet LocalServing.dll bench
```

Watch what `--concurrency 4` does. Aggregate tokens/sec may rise a little (Ollama can run a few requests in parallel, controlled by `OLLAMA_NUM_PARALLEL`), while TTFT p95 climbs as requests queue. That's the latency-vs-throughput trade from the batching section, on your own machine.

Run one benchmark at a time. Both gateways share one Ollama, and two benchmarks at once skew each other's numbers.

### In-process inference: the .NET option

Everything so far keeps the model in a separate server. .NET can also load the model **into your own process**:

- **LLamaSharp** wraps llama.cpp. It loads the same GGUF files Ollama uses (`Q4_K_M`, `Q8_0`) and picks a native backend package per hardware (CPU, CUDA, and others; check the package list for current names).
- **Microsoft.ML.OnnxRuntimeGenAI** runs generative models exported to ONNX, with the generation loop (sampling, KV cache) built in. It has CPU, CUDA and DirectML variants.

Both give you the model as a library call, with no HTTP hop. Python has the same options (`llama-cpp-python`, `transformers`), so this is a deployment decision, not a language one.

In-process makes sense when there's one user and no server to run: a desktop or offline app, an edge device, a CLI tool, a test harness. It's the SQLite choice. A separate server (Ollama, vLLM) is the Postgres choice, and it wins for anything shared. You get batching across callers, the model's memory isn't duplicated in every app instance, a native crash doesn't take the app down, and you can scale and upgrade the model separately from the code. For a web gateway like this one, keep the server.

If you try either library, put the weights under `models/` (gitignored) or mount them as a volume. Never commit them.

## Cross-check the two

**Exact, on the stub.** Run both gateways on `LLM_BACKEND=stub` and compare. The `text` must be identical (`stub: <prompt>` from 04's stub in both), the key sets must be identical, and a missing prompt must be a 422 from both. Timings will differ, and that's fine.

```powershell
# Terminal 1, in projects/10-local-serving/python:
$env:LLM_BACKEND = 'stub'; uv run --no-sync uvicorn app.main:app --port 8000
# Terminal 2, in projects/10-local-serving/csharp:
$env:LLM_BACKEND = 'stub'; dotnet run --project src/LocalServing --urls http://localhost:8001
# Terminal 3:
$body = '{"prompt":"explain a b-tree in one sentence"}'
$py = Invoke-RestMethod http://localhost:8000/chat -Method Post -ContentType application/json -Body $body
$cs = Invoke-RestMethod http://localhost:8001/chat -Method Post -ContentType application/json -Body $body
$py.text -ceq $cs.text                                                     # True
Compare-Object $py.PSObject.Properties.Name $cs.PSObject.Properties.Name   # no output = same keys
foreach ($port in 8000, 8001) {                                            # 422, 422
  (Invoke-WebRequest "http://localhost:$port/chat" -Method Post -ContentType application/json -Body '{}' -SkipHttpErrorCheck).StatusCode
}
```

**Approximate, on a real model.** Point both at the same Ollama and run both benchmarks, one after the other:

- **The response text won't match**, and it shouldn't. That's sampling (module 03), not a bug.
- **TTFT and tokens/sec should be in the same ballpark** for the same model on the same machine, with the same *ordering* between int4 and int8. The absolute numbers depend on your hardware. Both sides warm up first, so the cold load isn't in either median. If they disagree by a lot, look at the wire first: Python's `ollama` backend uses `/v1` and C#'s uses the native API, so rerun C# through `/v1` (the `hosted` command above) before blaming either language. Then look at retries and timeouts.
- **Chunks vs tokens.** On the native API, C#'s `tokens per chunk` line is the real ratio. In Python, compare the printed chunk count with the sum of the `out=` values in the `llm_call` lines. Either way, that's how far "1 chunk ≈ 1 token" is off for this backend.
- **Both report end-to-end tokens/sec**, prefill included. Decode speed is `tokens / (total − ttft)`, and it's higher. Pick one definition and write it in `NOTES.md`, because people quote both.

| Concern | Python | C# / .NET |
|---|---|---|
| Model server | Ollama, native or the `ollama` profile | the same Ollama |
| Model client | 04's `LlmClient` via `client_from_env()` | 04's `IChatClient` via `AddLlmClient` |
| Ollama wire | `/v1/chat/completions` | native `/api/chat` (OllamaSharp); `/v1` via `LLM_BACKEND=hosted` |
| Streaming | `async for` over `client.stream(...)` | `await foreach` over `GetStreamingResponseAsync` |
| Timing | `time.perf_counter()` | `Stopwatch.GetTimestamp` / `GetElapsedTime` |
| Token count | 1 chunk ≈ 1 token | `UsageContent` if reported, else chunks |
| Per-model client | `client_for`: env override around `client_from_env()` | `ServicesFor`: in-memory config layer over `AddLlmClient` |
| Concurrency | sequential | `Parallel.ForEachAsync` with `--concurrency` |
| Stats | `statistics.median` | hand-rolled percentile (`Stats.Percentile`) |
| Web layer | FastAPI + Pydantic (snake_case), dependency override | minimal API + records + `SnakeCaseLower` |
| Missing `prompt` | 422 from Pydantic validation | 422 from an explicit check |
| In-process option | `llama-cpp-python`, `transformers` | LLamaSharp, `Microsoft.ML.OnnxRuntimeGenAI` |
| Tests | pytest: `StubClient`, `httpx.MockTransport` under `OllamaClient` | NUnit: `StubChatClient`, `FakeStreamingChatClient`, `WebApplicationFactory<Program>` |

## Moving local-serving to AWS

You have two shapes of decision: **self-host on AWS** or **use Bedrock**. For most teams, most of the time, the answer is Bedrock — but know the map.

**Just use Bedrock (managed, per-token).** Amazon Bedrock is the hosted-API answer inside AWS: managed access to a menu of models (Anthropic, Meta Llama, Amazon's own, etc.), pay-per-token, IAM auth, no GPUs to run. It's the natural backend for module [12](12-deploying-to-aws.md). If your reasons-to-self-host list above is empty, stop here. (Model and region availability vary and change — check the current Bedrock docs; don't hardcode assumptions.)

**Self-host on AWS**, roughly in order of ops burden:

- **SageMaker real-time endpoints** — the "managed self-hosting" option. You deploy a model (including open weights, often via prebuilt containers) to a managed GPU endpoint that handles autoscaling and the serving stack. Least ops of the self-host options; you still pay for the instance-hours behind the endpoint.
- **ECS Fargate** — *no GPU support for the heavy case*; fine for CPU-only tiny models or for running the *gateway* while the model lives elsewhere. Don't plan to serve a 7B model on Fargate.
- **EC2 GPU instances** (the `g`/`p` families) running vLLM or TGI in a container — maximum control, maximum ops. You own the AMI, drivers, autoscaling group, and the bill. This is "Postgres on EC2": powerful, and yours to babysit.
- **EKS** — the same as EC2 GPU but orchestrated with Kubernetes, for teams already all-in on k8s and needing to schedule GPU workloads at scale.

**Cost caution — read this twice.** A single GPU instance runs **hundreds to thousands of dollars per month whether or not it serves a single request.** Idle GPUs are how self-hosting bills balloon. Before you launch *any* GPU instance, **set an AWS Budget alarm** (module [13](13-cost-scaling-and-security.md) covers this in depth) so a forgotten `p`-family box doesn't quietly cost you a mortgage payment. The whole point of the local Docker project is to learn serving *without* renting a GPU — do that first.

The payoff of the gateway pattern: because your app talks to a clean `/chat` endpoint over an OpenAI-compatible client, "move to Bedrock" or "move to a vLLM endpoint on EC2" is a **config change behind the gateway**, not an app rewrite.

Where that change lands: nowhere in this project. The backend choice lives in module 04's library, which both gateways reuse.

- **vLLM or TGI on EC2:** `LLM_BACKEND=hosted` with its `LLM_BASE_URL` (the `/v1` URL) and model name, in both languages. No code changes.
- **Bedrock:** isn't OpenAI-compatible, so it's a new backend. Module [12](12-deploying-to-aws.md) adds `LLM_BACKEND=bedrock` **to 04's library** (a `BedrockClient` behind the `LlmClient` protocol in Python, a `bedrock` case in `AddLlmClient` in C#), and every project that reuses the library, this one included, gets it at once. The gateways and the benchmarks don't change.
- **A SageMaker endpoint** is called through the SageMaker Runtime `InvokeEndpoint` API with AWS auth, not a `/v1` URL. It would be one more backend in 04's library, behind the same interface.

Both gateway images are CPU-only, so they run fine on ECS Fargate while the model lives on Bedrock or a GPU box.

## How experts think / pitfalls

- **Default to hosted; earn the right to self-host.** The instinct to run your own model is usually premature. Make the reasons-to-self-host list explicit and require at least one real hit.
- **Idle GPU = burning money.** The entire economics of self-hosting is utilization. If you can't keep the box busy, per-token math loses to the API every time.
- **Benchmark on your task, not the leaderboard.** A model's public benchmark score doesn't tell you whether *its int4 quant* handles *your* prompts. Wire quant choices into your [09](09-evaluation-and-testing.md) evals.
- **VRAM is the first question, not tokens/sec.** "Does it fit?" precedes "is it fast?" Estimate weights (bytes/param × params) + KV cache before anything else.
- **Program against the endpoint, not the vendor.** The OpenAI-compatible interface is your seam. Keep the app backend-agnostic so switching costs stay a config change.
- **TTFT and tokens/sec are different problems.** Don't optimize throughput for a chat UI or latency for a batch job. Know which one your workload is bound by.
- **Pitfall: benchmarking on CPU and extrapolating.** Numbers from CPU Ollama on a laptop tell you *relative* quant behavior, not production throughput. Don't quote them in a capacity plan.
- **Pitfall: forgetting the KV cache in memory math.** Long contexts (hello, RAG) can consume as much VRAM as the weights. Budget for it.
- **Your client is part of the measurement.** Timeouts (04's 90 s per attempt), retry policies, and a cold first request all show up in latency numbers. Know what your client does on a 503 or a slow response before you trust a benchmark in either language.
- **Know which server you measured.** With native Ollama and a container both configured, it's easy to benchmark the CPU container while believing you're on the GPU. `ollama ps` before every run.
- **In-process vs out-of-process is a deployment decision.** Loading a model into the app (LLamaSharp, ONNX Runtime GenAI) removes a hop and a container. It also ties the model's memory, crashes and scaling to the app. Fine for a desktop tool, wrong for a shared service.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Extend the benchmark:** add your local open model (at both quantization levels) to your [personal benchmark](R-reviewing-ai-written-code.md#tracking-model-releases). Write a model note on how small or quantized models fail differently from frontier ones (typically more `hallucinated-api` and `misread-spec`).
- **C#-specific watch:** `Microsoft.Extensions.AI` renamed its core API on the way to GA, so agent-written code often uses the preview names: `CompleteAsync` / `CompleteStreamingAsync` / `ChatCompletion` instead of `GetResponseAsync` / `GetStreamingResponseAsync` / `ChatResponse`, and `AsChatClient()` instead of `AsIChatClient()`. The OpenAI SDK has the same problem: the old `Azure.AI.OpenAI` 1.x beta style (`OpenAIClient.GetChatCompletionsAsync`) gets mixed with the 2.x `ChatClient.CompleteChatAsync`. OllamaSharp's own chat APIs also changed between major versions. Check every call against the package version in 04's `.csproj`. In this module specifically, watch for an agent writing a second model client (a new `OpenAIClient(...)` or `OllamaApiClient` in `LocalServing`) instead of reusing `AddLlmClient`, and for `Results.BadRequest` where the contract says 422.

## Checkpoint

You're ready for [11](11-observability-and-guardrails.md) if you can:

- Explain, to a skeptical eng manager, three concrete conditions under which self-hosting beats a hosted API — and admit when none apply.
- Estimate the VRAM to run a 7B model at fp16, int8, and int4, and say why memory (not FLOPs) is usually the local wall.
- Explain TTFT vs tokens/sec, and how prefill, decode, the KV cache, and batching relate to each.
- Point the gateway at a different inference backend (native API, Ollama's `/v1`, a vLLM URL) by changing only configuration, as in [the OpenAI-compatible endpoint pattern](#the-openai-compatible-endpoint-pattern).
- Show `NOTES.md` with real tokens/sec **and eval scores** across two quantization levels ([the recipe](#eval-score-per-quantization-level)), and state whether the cheaper quant was actually worth it.
- Run both gateways on the stub and show the [cross-check](#cross-check-the-two) passes: same text, same keys, 422 for a missing prompt from both.
- Run the Python and C# benchmarks against the same model. Say which outputs must match (the `/chat` JSON contract) and which only roughly (timings), and how far "1 chunk ≈ 1 token" was off.
- Explain what happened to TTFT p95 and aggregate tokens/sec when you raised `--concurrency`, and when you'd load a model in-process in .NET instead of calling a server.

## Going deeper

- The **vLLM** documentation and the PagedAttention paper — the clearest explanation of KV-cache-as-virtual-memory and continuous batching.
- The **`llama.cpp`** project README and its quantization (GGUF `Q*_K_*`) notes — what those quant tiers actually do.
- Hugging Face's **Text Generation Inference** docs — the other production serving engine, and its take on batching.
- Amazon **Bedrock** and **SageMaker** service docs — for the current model menu, endpoint types, and (always changing) pricing and region availability.
- Revisit module [03](03-llm-fundamentals-for-engineers.md) on tokens if the tokens/sec discussion felt fuzzy.
- "Microsoft.Extensions.AI IChatClient streaming" and "Microsoft.Extensions.AI.OpenAI": the abstraction and the adapter that points the OpenAI .NET SDK at any `/v1` server.
- "OllamaSharp": the native Ollama client for .NET, and what it reports beyond the OpenAI-compatible API.
- "LLamaSharp" and "ONNX Runtime GenAI C#": the in-process options. Read their current backend and model-format support before you pick one.

*Last verified: 2026-10-05. Built: Python (pytest 9 passed, pyright clean) and C# (dotnet test 13 passed) in a throwaway build against module 04's built library; both benchmarks and both gateways run on the stub, and the stub cross-check passes (same text, same keys, 422 from both). Read-only: Docker images (compose files validated with `docker compose config`, with and without the `ollama` profile), every run against a live Ollama model, and the eval-per-quant recipe (modules 07 and 09 not built alongside).*

**Verify on first build:**

- That the quant tags `llama3.2:3b-instruct-q4_K_M` and `llama3.2:3b-instruct-q8_0` still exist in the Ollama library (check its tags page), and whether `llama3.2:3b` is the same weights as the `q4_K_M` tag (`ollama show`).
- Module 07's `${OLLAMA_MODEL}` / `${LLM_BACKEND}` interpolation picks up a model set in your shell before `docker compose up --force-recreate`.
- That OllamaSharp's streaming reports usage as `UsageContent` (C#'s `tokens per chunk` should read something other than exactly 1.00 on the native API), and that your Ollama sends usage on `/v1` streams (Python's `llm_call` lines show `out=0` if not).
- That `gpus: all` gives the Ollama container the GPU on your Docker Desktop (`ollama ps` shows it).

Next: [11 — Observability & guardrails](11-observability-and-guardrails.md).
