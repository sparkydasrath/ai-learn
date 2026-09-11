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

### Ollama — the easy on-ramp

[Ollama](https://ollama.com) is the "Docker for models." One command pulls a quantized model and serves it over HTTP:

```bash
ollama pull llama3.2:3b
ollama run llama3.2:3b "explain a b-tree in one sentence"
```

It bundles the weights, a runtime (`llama.cpp` under the hood), and a small HTTP server. Crucially for us, it **exposes an OpenAI-compatible endpoint** at `/v1/chat/completions`. That's the whole trick this module leans on (below).

Ollama is optimized for *single-user, low-concurrency* use — your laptop, a dev box, a demo. It is **not** what you'd put under production throughput.

### vLLM and TGI — the throughput engines (mention)

When you actually serve many concurrent users, you reach for a real inference server:

- **vLLM** — the current de-facto open-source serving engine. Its headline feature is **PagedAttention**, which manages the KV cache like an OS manages virtual memory pages, letting it pack far more concurrent requests onto a GPU. Also exposes an OpenAI-compatible API.
- **TGI (Text Generation Inference)** — Hugging Face's server, similar goals, tight integration with the HF ecosystem.

You don't need to run these on your laptop (they want a real GPU). Know that they exist, that they're what production self-hosting uses, and that they speak the same OpenAI-compatible dialect — so your app code doesn't care which one is behind the endpoint.

### The OpenAI-compatible endpoint pattern

Here's the load-bearing idea for the rest of this curriculum. `POST /v1/chat/completions` with `{model, messages, ...}` returning `{choices: [{message: {...}}]}` has become the *lingua franca* of LLM serving. OpenAI, Ollama, vLLM, TGI, LM Studio, LiteLLM, most gateways — they all speak it.

That means the `LlmClient` interface you built in [04](04-calling-models-apis-sdks.md) doesn't need to change at all. You just point its `base_url` at a different backend:

```python
# hosted
client = LlmClient(base_url="https://api.openai.com/v1", api_key=OPENAI_KEY)
# local Ollama, same interface
client = LlmClient(base_url="http://ollama:11434/v1", api_key="ollama")  # key ignored
```

This is exactly the `IHttpClientFactory` + typed-client discipline you already practice in .NET: program against the interface, swap the implementation by config. Backend-agnostic app code is the goal — you want to A/B a hosted frontier model against a self-hosted one *by changing an env var*, not by rewriting the app.

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

> **Docker note.** GPU passthrough into containers needs the NVIDIA Container Toolkit and `--gpus all` (or the compose `deploy.resources` device reservation). On a machine without an NVIDIA GPU — most laptops — Ollama in Docker runs on **CPU**. That's fine for this project; expect modest tokens/sec and don't benchmark a 70B model on it.

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

**`projects/10-local-serving/`** — Run a small open model via Ollama in Docker, put a thin FastAPI gateway in front exposing a clean chat endpoint (reusing the [04](04-calling-models-apis-sdks.md) client interface), and **benchmark tokens/sec + TTFT across two quantization levels**, recording results.

### Layout

```
projects/10-local-serving/
  pyproject.toml
  Dockerfile
  docker-compose.yml
  .env.example
  app/
    __init__.py
    main.py          # FastAPI gateway
    llm_client.py    # reuse of the 04 OpenAI-compatible client
    benchmark.py     # tokens/sec + TTFT across quant levels
  NOTES.md           # your lab notebook (record the numbers!)
```

### `app/llm_client.py` — backend-agnostic client (from 04)

```python
"""Thin OpenAI-compatible chat client. Works against any /v1 backend:
OpenAI, Ollama, vLLM, TGI. This is the module-04 interface, unchanged."""
from __future__ import annotations

import time
from dataclasses import dataclass

import httpx


@dataclass
class ChatResult:
    text: str
    ttft_s: float          # time to first token
    total_s: float         # wall clock, whole response
    completion_tokens: int


class LlmClient:
    def __init__(self, base_url: str, api_key: str = "unused", model: str = "llama3.2:3b"):
        # base_url points at ANY OpenAI-compatible backend
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model

    async def chat_stream(self, prompt: str, timeout: float = 120.0) -> ChatResult:
        """Stream a completion, measuring TTFT and total time."""
        payload = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
        }
        headers = {"Authorization": f"Bearer {self._api_key}"}

        start = time.perf_counter()
        ttft: float | None = None
        chunks: list[str] = []
        n_tokens = 0

        async with httpx.AsyncClient(timeout=timeout) as http:
            async with http.stream(
                "POST", f"{self._base_url}/chat/completions",
                json=payload, headers=headers,
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line.removeprefix("data: ").strip()
                    if data == "[DONE]":
                        break
                    import json
                    delta = json.loads(data)["choices"][0]["delta"].get("content", "")
                    if delta:
                        if ttft is None:
                            ttft = time.perf_counter() - start
                        chunks.append(delta)
                        n_tokens += 1  # approx: 1 stream chunk ~= 1 token for these backends

        total = time.perf_counter() - start
        return ChatResult(
            text="".join(chunks),
            ttft_s=ttft or total,
            total_s=total,
            completion_tokens=n_tokens,
        )
```

> `from __future__ import annotations` (a Python-ism) makes all annotations lazy strings, so `str | None` unions work cleanly and forward references don't need quotes. The `async with` nesting is Python's `IAsyncDisposable`/`await using` equivalent — deterministic cleanup of the HTTP stream.

### `app/main.py` — the FastAPI gateway

```python
"""A thin, clean chat gateway. The app depends on THIS, not on Ollama.
Swap OLLAMA_BASE_URL for a Bedrock/vLLM proxy later and nothing above changes."""
from __future__ import annotations

import os

from fastapi import FastAPI
from pydantic import BaseModel

from .llm_client import LlmClient

app = FastAPI(title="local-serving-gateway")

client = LlmClient(
    base_url=os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434/v1"),
    api_key=os.environ.get("LLM_API_KEY", "ollama"),
    model=os.environ.get("MODEL", "llama3.2:3b"),
)


class ChatRequest(BaseModel):
    prompt: str


class ChatResponse(BaseModel):
    text: str
    ttft_s: float
    total_s: float
    tokens_per_sec: float


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    r = await client.chat_stream(req.prompt)
    tps = r.completion_tokens / r.total_s if r.total_s > 0 else 0.0
    return ChatResponse(text=r.text, ttft_s=r.ttft_s, total_s=r.total_s, tokens_per_sec=tps)
```

### `app/benchmark.py` — turn the quantization dial

```python
"""Benchmark two quantization levels of the same base model.
Pull both first, e.g.:
    docker compose exec ollama ollama pull llama3.2:3b-instruct-q4_K_M
    docker compose exec ollama ollama pull llama3.2:3b-instruct-q8_0
Then: docker compose exec gateway python -m app.benchmark
"""
from __future__ import annotations

import asyncio
import statistics

from .llm_client import LlmClient

BASE_URL = "http://ollama:11434/v1"
PROMPTS = [
    "Summarize the CAP theorem in two sentences.",
    "Write a Python function that reverses a linked list.",
    "List three trade-offs of microservices vs a monolith.",
]
MODELS = {
    "int4 (q4_K_M)": "llama3.2:3b-instruct-q4_K_M",
    "int8 (q8_0)":   "llama3.2:3b-instruct-q8_0",
}


async def bench_model(label: str, model: str) -> None:
    client = LlmClient(base_url=BASE_URL, model=model)
    ttfts: list[float] = []
    tps: list[float] = []
    for p in PROMPTS:
        r = await client.chat_stream(p)
        ttfts.append(r.ttft_s)
        if r.total_s > 0:
            tps.append(r.completion_tokens / r.total_s)
    print(f"\n== {label} ({model}) ==")
    print(f"  TTFT   median: {statistics.median(ttfts):6.2f} s")
    print(f"  tok/s  median: {statistics.median(tps):6.1f}")


async def main() -> None:
    for label, model in MODELS.items():
        await bench_model(label, model)
    print("\nRecord these in NOTES.md, then run your module-09 evals against BOTH")
    print("to check the int4 model didn't lose quality. Cheaper is only better if it's still good.")


if __name__ == "__main__":
    asyncio.run(main())
```

### `docker-compose.yml`

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama-models:/root/.ollama      # cache pulled weights across restarts
    ports:
      - "11434:11434"
    # --- GPU: uncomment on a machine with an NVIDIA GPU + Container Toolkit ---
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  gateway:
    build: .
    environment:
      OLLAMA_BASE_URL: "http://ollama:11434/v1"
      MODEL: "llama3.2:3b"
    ports:
      - "8000:8000"
    depends_on:
      - ollama

volumes:
  ollama-models:
```

### `Dockerfile` (gateway)

```dockerfile
FROM python:3.12-slim
WORKDIR /app
# uv for fast installs (module 01)
RUN pip install --no-cache-dir uv
COPY pyproject.toml .
RUN uv pip install --system --no-cache .
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Run it locally

```bash
cd projects/10-local-serving
docker compose up -d --build
# pull the base model into the ollama container
docker compose exec ollama ollama pull llama3.2:3b
# smoke test the clean gateway
curl -s localhost:8000/chat -H 'content-type: application/json' \
  -d '{"prompt":"explain a b-tree in one sentence"}' | jq
# pull both quant levels and benchmark
docker compose exec ollama ollama pull llama3.2:3b-instruct-q4_K_M
docker compose exec ollama ollama pull llama3.2:3b-instruct-q8_0
docker compose exec gateway python -m app.benchmark
```

**Record in `NOTES.md`:** TTFT and tokens/sec for each quant level, your hardware (CPU vs GPU, VRAM), and — the point of the exercise — the [09](09-evaluation-and-testing.md) eval score for each. You're proving to yourself whether int4 saved money *without* dropping quality on *your* task.

### Moving to AWS

You have two shapes of decision: **self-host on AWS** or **use Bedrock**. For most teams, most of the time, the answer is Bedrock — but know the map.

**Just use Bedrock (managed, per-token).** Amazon Bedrock is the hosted-API answer inside AWS: managed access to a menu of models (Anthropic, Meta Llama, Amazon's own, etc.), pay-per-token, IAM auth, no GPUs to run. It's the natural backend for module [12](12-deploying-to-aws.md). If your reasons-to-self-host list above is empty, stop here. (Model and region availability vary and change — check the current Bedrock docs; don't hardcode assumptions.)

**Self-host on AWS**, roughly in order of ops burden:

- **SageMaker real-time endpoints** — the "managed self-hosting" option. You deploy a model (including open weights, often via prebuilt containers) to a managed GPU endpoint that handles autoscaling and the serving stack. Least ops of the self-host options; you still pay for the instance-hours behind the endpoint.
- **ECS Fargate** — *no GPU support for the heavy case*; fine for CPU-only tiny models or for running the *gateway* while the model lives elsewhere. Don't plan to serve a 7B model on Fargate.
- **EC2 GPU instances** (the `g`/`p` families) running vLLM or TGI in a container — maximum control, maximum ops. You own the AMI, drivers, autoscaling group, and the bill. This is "Postgres on EC2": powerful, and yours to babysit.
- **EKS** — the same as EC2 GPU but orchestrated with Kubernetes, for teams already all-in on k8s and needing to schedule GPU workloads at scale.

**Cost caution — read this twice.** A single GPU instance runs **hundreds to thousands of dollars per month whether or not it serves a single request.** Idle GPUs are how self-hosting bills balloon. Before you launch *any* GPU instance, **set an AWS Budget alarm** (module [13](13-cost-scaling-and-security.md) covers this in depth) so a forgotten `p`-family box doesn't quietly cost you a mortgage payment. The whole point of the local Docker project is to learn serving *without* renting a GPU — do that first.

The payoff of the gateway pattern: because your app talks to a clean `/chat` endpoint over an OpenAI-compatible client, "move to Bedrock" or "move to a vLLM endpoint on EC2" is a **config change behind the gateway**, not an app rewrite.

## How experts think / pitfalls

- **Default to hosted; earn the right to self-host.** The instinct to run your own model is usually premature. Make the reasons-to-self-host list explicit and require at least one real hit.
- **Idle GPU = burning money.** The entire economics of self-hosting is utilization. If you can't keep the box busy, per-token math loses to the API every time.
- **Benchmark on your task, not the leaderboard.** A model's public benchmark score doesn't tell you whether *its int4 quant* handles *your* prompts. Wire quant choices into your [09](09-evaluation-and-testing.md) evals.
- **VRAM is the first question, not tokens/sec.** "Does it fit?" precedes "is it fast?" Estimate weights (bytes/param × params) + KV cache before anything else.
- **Program against the endpoint, not the vendor.** The OpenAI-compatible interface is your seam. Keep the app backend-agnostic so switching costs stay a config change.
- **TTFT and tokens/sec are different problems.** Don't optimize throughput for a chat UI or latency for a batch job. Know which one your workload is bound by.
- **Pitfall: benchmarking on CPU and extrapolating.** Numbers from CPU Ollama on a laptop tell you *relative* quant behavior, not production throughput. Don't quote them in a capacity plan.
- **Pitfall: forgetting the KV cache in memory math.** Long contexts (hello, RAG) can consume as much VRAM as the weights. Budget for it.

## Checkpoint

You're ready for [11](11-observability-and-guardrails.md) if you can:

- Explain, to a skeptical eng manager, three concrete conditions under which self-hosting beats a hosted API — and admit when none apply.
- Estimate the VRAM to run a 7B model at fp16, int8, and int4, and say why memory (not FLOPs) is usually the local wall.
- Explain TTFT vs tokens/sec, and how prefill, decode, the KV cache, and batching relate to each.
- Point any app at a different inference backend by changing only configuration, thanks to the OpenAI-compatible gateway.
- Show `NOTES.md` with real tokens/sec **and eval scores** across two quantization levels, and state whether the cheaper quant was actually worth it.

## Going deeper

- The **vLLM** documentation and the PagedAttention paper — the clearest explanation of KV-cache-as-virtual-memory and continuous batching.
- The **`llama.cpp`** project README and its quantization (GGUF `Q*_K_*`) notes — what those quant tiers actually do.
- Hugging Face's **Text Generation Inference** docs — the other production serving engine, and its take on batching.
- Amazon **Bedrock** and **SageMaker** service docs — for the current model menu, endpoint types, and (always changing) pricing and region availability.
- Revisit module [03](03-llm-fundamentals-for-engineers.md) on tokens if the tokens/sec discussion felt fuzzy.

Next: [11 — Observability & guardrails](11-observability-and-guardrails.md).
