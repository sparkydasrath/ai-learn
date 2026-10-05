# 07 — Retrieval-augmented generation (RAG)

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point.

By now you can call a model, get structured output, and let it call your tools (04–06). But the model only knows what it was trained on — frozen at some cutoff, with no access to your wiki, your tickets, or last Tuesday's incident. RAG fixes that by fetching relevant text at query time and putting it in the prompt. This module builds a real, **measurable** RAG pipeline.

## Where this fits

You've finished Phase 2:

- **04** — you can call hosted and local models with retries, timeouts, and cost accounting.
- **05** — you treat prompts as versioned, tested artifacts.
- **06** — you can get reliable JSON out and let the model call your code.

RAG is the first "system" module: you're no longer sending one prompt, you're building a pipeline with an offline part (ingest and index) and an online part (retrieve and generate). Everything here feeds forward: **08** wraps a RAG service as a tool an agent can call, and **09** is where you learn to actually measure whether your retrieval and answers are any good. You will hit the ceiling of "tune by feel" fast in this module — that's the setup for 09.

As in every module from 03 on, you build the project twice: a FastAPI service in Python, then an ASP.NET Core minimal API in C# with the same endpoints, talking to the same kind of Chroma server. Both generate through module 04's client, so the whole service also runs offline on its `stub` backend. The C# side is where you find out how much of "RAG" a Python package was doing for you.

This service is load-bearing for later modules: 08, 09, 11 and 12 call it over HTTP through `RAG_URL`, so its [contract](#the-service-contract) stays fixed from here on.

## Why RAG at all

Think of the model as a very well-read colleague with **no access to your systems** and a memory that stopped updating months ago. You have four ways to get your data into its answer:

1. **Put it in the prompt every time.** Works, but your knowledge base doesn't fit in a context window, and paying to send 200 pages on every question is absurd.
2. **Fine-tune the model on it** (module 16). Expensive, slow to update, and it bakes facts into weights where you can't cite them or delete one. Great for *behavior and format*, bad for *facts that change*.
3. **RAG** — index your documents, fetch the few relevant chunks per question, and put *those* in the prompt. Cheap, updates the instant you re-index, and every answer can cite its sources.
4. **Give the model a search tool** (agent territory, 08) — a dynamic cousin of RAG.

RAG wins when the knowledge is **large, changing, and needs attribution**. The .NET analogy: fine-tuning is compiling data into your assembly; RAG is a query against a database at runtime. You'd never recompile to change a customer's address. Concretely, RAG gives you:

- **Grounding** — answers tied to real documents, which sharply cuts hallucination.
- **Freshness** — re-index and the model "knows" the new thing; no retraining.
- **Cost** — send 5 relevant chunks, not the whole corpus, and skip fine-tuning entirely.
- **Citations** — you retrieved the sources, so you can show them. This is often the actual product requirement.

## The pipeline

RAG is two pipelines sharing a store. Draw it once and it stops being mysterious:

```
INGEST (offline, batch)          QUERY (online, per request)
  documents                        user question
    │ chunk                          │ embed
    ▼                                ▼
  chunks                           query vector
    │ embed                          │ search (top-k) + filter
    ▼                                ▼
  vectors ──► vector store ◄──── candidate chunks
                                     │ rerank (optional)
                                     ▼
                                   assemble context + prompt
                                     │ generate
                                     ▼
                                   answer + citations
```

The offline side is an ETL job — you already know how to build those. The online side is a request handler that does a similarity search and one model call. Let's walk each stage.

### Ingest

Load source documents and normalize to plain text: strip HTML/markdown chrome, keep structure hints (headings, source path) as **metadata** you'll attach to each chunk. Metadata is not decoration — it powers filtering ("only search the 2024 runbooks") and citations ("this came from `oncall.md#rollbacks`"). Treat ingest like any ETL: idempotent, re-runnable, logged.

### Chunk

Models and embeddings work on bounded spans of text, so you split documents into **chunks**. This is the stage that most quietly decides whether your RAG is good.

- **Too big** — a chunk covers three topics; its embedding is a blurry average of all three and matches nothing well. You also waste context tokens on irrelevant text.
- **Too small** — you shatter a coherent idea across chunks, and no single chunk carries enough to answer.

A workable default: a few hundred tokens per chunk (say 300–500) with **overlap** of ~10–20% so a sentence spanning a boundary isn't orphaned. Better than fixed-size splitting is **structure-aware** splitting — break on headings and paragraphs so chunks align with ideas. There's no universal right answer; chunking is a knob you *tune against an eval* (09), not a constant you guess once.

### Embed

An **embedding** turns a chunk of text into a vector — a list of a few hundred to a couple thousand floats — positioned so that texts with similar meaning land near each other. "How do I roll back a deploy?" and "reverting a release" end up close even with no shared words. You met these in 03; here's the one paragraph of intuition you need.

**Cosine similarity** measures the angle between two vectors, ignoring their length: `cos θ = (A·B) / (|A| |B|)`. It ranges from 1 (same direction, ~same meaning) through 0 (unrelated) to -1 (opposite). We use the *angle*, not the distance, because we care about direction-of-meaning, not how long the text is. That's the whole trick behind retrieval: embed the query, find the chunks whose vectors point the most nearly the same way. In Python it's a one-liner:

```python
import numpy as np

def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
```

(`a @ b` is the dot product — NumPy's `@` operator. A Pythonism worth knowing: operator overloading like this is idiomatic in the numeric stack, unlike in most C# you write.) In C# it's the `TensorPrimitives.CosineSimilarity(a, b)` call from module 03, SIMD-accelerated over `ReadOnlySpan<float>`.

You get embeddings from a model — a hosted one (an API call per batch) or a local one like `sentence-transformers` (runs on CPU, no per-call cost, great for learning). The rule that trips everyone once: **you must embed queries with the exact same model you embedded the documents with.** Different model, different vector space, garbage results.

### Store

A **vector store** holds vectors plus their text and metadata, and answers "give me the k nearest vectors to this one" fast. At small scale that's a brute-force scan; at large scale it's an **approximate nearest neighbor** (ANN) index (HNSW and friends) that trades a sliver of recall for a huge speedup.

- **Local / learning:** Chroma or FAISS — in-process, zero infrastructure. We'll use Chroma.
- **Production:** `pgvector` (Postgres extension — vectors live next to your relational data, and you already run Postgres), OpenSearch/Elasticsearch (vector + keyword in one engine), or a managed vector DB.

Mental model: it's an index, like a database index. Approximate search is the equivalent of accepting an occasionally-stale read for a massive latency win — a trade you've made before.

### Retrieve

Embed the question, ask the store for the **top-k** most similar chunks (k is typically 3–10). Three refinements you'll reach for immediately:

- **Metadata filtering** — constrain by structured fields (`source == "runbooks"`, `year >= 2024`) *before or during* the vector search. This is your `WHERE` clause.
- **Hybrid search** — pure vector search is semantic but fumbles exact tokens (error codes, function names, SKUs). Keyword search (BM25) nails those but misses paraphrases. **Hybrid** runs both and fuses the ranked lists (e.g. reciprocal rank fusion). In practice hybrid beats either alone on real corpora.
- **Rerank** — retrieval optimizes for speed over precision, so the top-k is a decent but noisy candidate set. A **reranker** (a cross-encoder model that scores each `(query, chunk)` pair jointly) re-sorts those candidates for relevance. Pattern: retrieve 50 cheaply, rerank to the best 5. It's the "cheap coarse filter, then expensive precise filter" pattern you use in query planners.

### Assemble context and generate

Now you build the prompt: a system instruction, the retrieved chunks (each tagged with a source id), and the question. Two things that matter more than they look:

- **Instruct grounding and citation.** Tell the model to answer *only* from the provided context, to cite the source id for each claim, and — critically — **to say it doesn't know when the context doesn't cover the question.** A RAG system that confidently answers from nothing is worse than useless.
- **Order and budget.** Put the most relevant chunks where the model attends best (see lost-in-the-middle below), and keep total context within budget — retrieval doesn't mean "dump everything."

```
System: Answer using ONLY the context below. Cite sources like [S1].
        If the context doesn't contain the answer, say you don't know.

Context:
[S1] (runbooks/oncall.md) To roll back, run `deploy --revert <sha>` ...
[S2] (runbooks/oncall.md) Rollbacks are safe within 24h of release ...

Question: How do I roll back a deploy?
```

### The failure modes (memorize these)

RAG fails in specific, recognizable ways. Knowing the taxonomy is half of debugging:

- **Bad chunks** — retrieval works but the chunk is a blurry multi-topic blob or a fragment. Fix chunking, not the prompt.
- **Wrong k** — too small misses the answer; too large drowns it in noise and cost.
- **Lost in the middle** — models attend most to the **start and end** of a long context and skim the middle. Put your best chunk first or last, not buried.
- **No relevant docs** — the answer isn't in your corpus. The system *must* detect this and say "I don't know" rather than confabulate. This is a retrieval-quality problem masquerading as a generation problem.
- **Retrieval/answer mismatch** — you retrieved the right chunk but the model ignored it or contradicted it (a **faithfulness** failure).

Here's the load-bearing point of this whole module: **you cannot tell which of these is happening, or whether a change helped, without metrics.** Retrieval quality is `recall@k` (did the right chunk make the top-k?); answer quality is faithfulness and relevance (09). Tuning chunk size or k by eyeballing three answers is the vibe-coding trap. We'll build the tiniest possible retrieval eval in this project and the real thing in 09.

## The build project

**`projects/07-rag-service/`** — ingest a folder of markdown, chunk, embed, store, and answer questions **with citations** over an HTTP API. Includes a tiny `recall@k` retrieval eval. Built twice, with the same endpoints, the same request and response JSON, and the same corpus:

- **Python:** FastAPI, module 04's client for generation, `sentence-transformers` for embeddings in-process, the `chromadb` client, and a `recall@k` script.
- **C#:** an ASP.NET Core minimal API, module 04's `LlmClient` library for generation, `Microsoft.Extensions.AI`'s `IEmbeddingGenerator` (backed by Ollama), a small typed `HttpClient` over Chroma's REST API, and `recall@k` as an NUnit eval.

The service has three seams, and each one is picked by an environment variable with the same name in both languages. Each has an offline choice, and with all three set offline the whole service runs with no model, no embedding download and no Chroma. The tests and the exact cross-check run that way.

| Seam | Env var | Default (Python / C#) | Offline |
|---|---|---|---|
| Chat model | `LLM_BACKEND` | `ollama`, through module 04's client | `stub` |
| Embeddings | `EMBED_BACKEND` | `sentence-transformers` / `ollama` | `hashing` |
| Vector store | `VECTOR_STORE` | `chroma` | `memory` |

An unknown value fails at startup with the list of valid ones, the same rule as `LLM_BACKEND` ([conventions](conventions.md#model-backends)).

### The service contract

Modules 08, 09, 11 and 12 call this service over HTTP, at the URL in `RAG_URL`, so this contract is the module's public API. Keep it stable:

| Endpoint | Request | Response |
|---|---|---|
| `GET /health` | | `{"status": "ok"}` |
| `POST /ingest?folder=.` | `folder`: a directory under `fixtures/corpus`; the default `.` is the whole corpus | `{"chunks_indexed": 3}`, or 400 `{"detail": "..."}` for a folder outside the corpus |
| `POST /ask` | `{"question": "...", "k": 4}`: `question` required and non-empty, `k` from 1 to 20, default 4 | `{"answer": "...", "citations": [{"tag": "S1", "source": "oncall.md", "chunk_id": "oncall.md#0"}]}`, or 422 for a bad request |

The Python service listens on 8000. The C# one listens on 8080 in its container and is published on 8001 (module 12 moves it to 8000, [conventions](conventions.md#ports)). `/ask` before `/ingest` answers from an empty context, and with `VECTOR_STORE=memory` the index starts empty on every restart, so ingest first.

### Layout

The corpus and the labeled set live once, in `fixtures/` at the project root, and both languages read them from there. The repo `.gitignore` ignores `data/` and `*.jsonl` but re-includes `fixtures/`, so they get committed. One copy means the two sides can't drift.

```
projects/07-rag-service/
├── fixtures/                          # shared, committed datasets (FIXTURES_DIR)
│   ├── corpus/
│   │   ├── oncall.md
│   │   └── billing.md
│   └── qa.jsonl                       # question → expected source
├── python/
│   ├── pyproject.toml                 # path dependency on 04; CPU-only torch
│   ├── uv.lock                        # committed: pins exact dependency versions
│   ├── README.md                      # from the bootstrap script
│   ├── Dockerfile                     # build context: projects/
│   ├── Dockerfile.dockerignore        # from the bootstrap script
│   ├── compose.yaml
│   ├── .env.example                   # committed; copy to .env (git-ignored)
│   ├── app/
│   │   ├── __init__.py
│   │   ├── config.py                  # settings from env
│   │   ├── store.py                   # Chunk, Hit, the VectorIndex seam: InMemoryIndex, ChromaIndex
│   │   ├── embeddings.py              # the Embedder seam: sentence-transformers, hashing
│   │   ├── ingest.py                  # load → chunk → embed → store
│   │   ├── retriever.py               # embed query → search
│   │   ├── rag.py                     # assemble context → generate → cite
│   │   └── main.py                    # FastAPI: /health, /ingest, /ask
│   ├── eval/
│   │   └── recall_at_k.py             # recall@k over ../fixtures/qa.jsonl
│   └── tests/
│       ├── conftest.py                # the offline app, for the API tests
│       ├── test_chunker.py
│       ├── test_prompt.py
│       ├── test_retrieval.py
│       └── test_api.py                # FastAPI TestClient, on stub
└── csharp/
    ├── RagService.slnx
    ├── Directory.Build.props          # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                     # build context: projects/
    ├── Dockerfile.dockerignore        # from the bootstrap script
    ├── compose.yaml
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   └── RagService/
    │       ├── RagService.csproj      # ProjectReference to 04's LlmClient
    │       ├── appsettings.json       # from the template
    │       ├── Properties/launchSettings.json
    │       ├── RagOptions.cs          # settings from env, same names as Python
    │       ├── Chunker.cs             # same packing rules as the Python chunker
    │       ├── VectorIndex.cs         # IVectorIndex seam + in-memory brute-force index
    │       ├── ChromaVectorIndex.cs   # typed HttpClient over Chroma's REST API
    │       ├── HashingEmbeddingGenerator.cs  # EMBED_BACKEND=hashing, the HashingEmbedder twin
    │       ├── Ingestor.cs            # load → chunk → embed → store
    │       ├── Retriever.cs           # embed query → search
    │       ├── RagAnswerer.cs         # assemble context → generate → cite
    │       ├── RecallAtK.cs           # the metric, as a pure function
    │       └── Program.cs             # minimal API: /health, /ingest, /ask
    └── tests/
        └── RagService.Tests/
            ├── RagService.Tests.csproj  # NUnit + Microsoft.AspNetCore.Mvc.Testing
            ├── TestPaths.cs             # finds ../fixtures from the test output folder
            ├── ChunkerTests.cs
            ├── PromptTests.cs
            ├── RetrievalTests.cs
            ├── RecallAtKTests.cs
            ├── ApiTests.cs              # WebApplicationFactory<Program>, on stub
            └── RecallEvalTests.cs       # [Category("Eval")]: real embeddings, skipped without Ollama
```

### The corpus and the labeled set

Two short runbooks, small enough to read, big enough that `oncall.md` splits into two chunks. The tests pin their chunk ids, so if you change a word here, update the pinned values in both test suites.

`fixtures/corpus/oncall.md`:

```markdown
# On-call runbook

## Rolling back a deploy

To roll back, run `deploy --revert <sha>` with the SHA of the last good release. The command redeploys that build to every region and takes about five minutes. Post the SHA in the incident channel before you start, so nobody deploys over you.

Rollbacks are safe within 24 hours of a release. After that, a database migration may have run that the old build doesn't understand, so check the migrations folder first and ask the owning team whether anything changed.

## Paging and escalation

Acknowledge a page within 15 minutes. If you can't fix the problem within an hour, escalate to the secondary on-call, and then to the engineering manager on duty.

Every page gets a short incident note: what fired, what you did, and whether the alert was useful. Alerts that never lead to action get deleted at the weekly review.

## Restarting a stuck worker

A worker that stops pulling from the queue usually has a hung database connection. Run `svc restart worker --region <region>` and watch the queue depth fall. If it climbs again within ten minutes, take a heap dump before you restart it a second time.
```

`fixtures/corpus/billing.md`:

```markdown
# Billing

## Plans and overages

Customers are billed monthly for the plan they hold on the first of the month. Usage above the plan's included quota is charged as an overage at the end of the billing period, at the per-unit rate on the pricing page.

## Refunds

Refunds for duplicate charges are issued automatically within five business days. Any other refund needs approval from a billing lead and goes back to the original payment method.

## Invoices

Invoices are emailed on the first business day of each month. Customers can download past invoices from the account settings page for up to seven years.
```

`fixtures/qa.jsonl`, one question per line with the file that answers it:

```jsonl
{"question": "How do I roll back a deploy?", "expected_source": "oncall.md"}
{"question": "When is a rollback still safe?", "expected_source": "oncall.md"}
{"question": "What do I do when a worker stops pulling from the queue?", "expected_source": "oncall.md"}
{"question": "How are customers billed for overages?", "expected_source": "billing.md"}
{"question": "Who has to approve a refund?", "expected_source": "billing.md"}
```

## Python implementation

Work in `projects/07-rag-service/python/`. Run everything from there, so the default `FIXTURES_DIR` of `../fixtures` points at the shared folder.

This is a [service-shaped](conventions.md#python-project-shapes) project: code in `app/` and `eval/` at the `python/` root, never installed. Scaffold it with `-Mode app`, which also writes `pythonpath = ["."]` for pytest. Then add module 04's client as a path dependency, and the rest. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 07-rag-service -Mode app
cd projects/07-rag-service/python
uv add --editable ../../04-llm-client/python
uv add fastapi uvicorn "chromadb-client>=1.5.9,<1.6" numpy pydantic-settings
uv add --dev httpx2
```

`chromadb-client` is the HTTP-only client: the full `chromadb` package also bundles a server you don't need here. Its version range matches the Chroma server image the compose file pins. `httpx2` is for FastAPI's `TestClient`, which wraps Starlette's: current Starlette warns that running it on plain `httpx` is deprecated. Delete the scaffold's `tests/test_smoke.py` once the real tests exist.

`sentence-transformers` pulls in PyTorch, which needs the [CPU wheel index](conventions.md#pytorch-wheels) or Linux gets the multi-GB CUDA build. Add the index and the source to `pyproject.toml` first, then add both packages, torch as a *direct* dependency so the source applies:

```powershell
uv add sentence-transformers torch
Select-String -Context 0,2 'name = "torch"' uv.lock   # the source should be download.pytorch.org/whl/cpu
```

The finished `pyproject.toml`:

```toml
# projects/07-rag-service/python/pyproject.toml
[project]
name = "rag-service"
version = "0.1.0"
description = "RAG service: ingest, retrieve, answer with citations"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "chromadb-client>=1.5.9,<1.6",
    "fastapi>=0.142.2",
    "llm-client",
    "numpy>=2.5.3",
    "pydantic-settings>=2.15.0",
    "sentence-transformers>=6.1.0",
    "torch>=2.14.1",
    "uvicorn>=0.54.0",
]

[tool.pytest.ini_options]
pythonpath = ["."]

[tool.uv.sources]
llm-client = { path = "../../04-llm-client/python", editable = true }
torch = [{ index = "pytorch-cpu" }]

[dependency-groups]
dev = [
    "httpx2>=2.13.1",
    "pytest>=9.1.1",
]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true
```

### Settings

```python
# app/config.py
from pathlib import Path

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Each field reads the environment variable of the same name, case-insensitively
    (VECTOR_STORE, CHROMA_URL, ...). The model backend isn't here: LLM_BACKEND and
    OLLAMA_* belong to module 04's client_from_env()."""

    vector_store: str = "chroma"                     # chroma | memory
    chroma_url: str = "http://localhost:8003"        # where compose.yaml publishes Chroma
    chroma_collection: str = "docs"
    embed_backend: str = "sentence-transformers"     # sentence-transformers | hashing
    embed_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    # The shared corpus and labeled set: ../fixtures from python/; the Dockerfile sets the container path.
    fixtures_dir: Path = Path("../fixtures")
```

`pydantic-settings` reads each field from the environment variable of the same name, case-insensitively, and converts types. The model backend isn't here: `LLM_BACKEND` and `OLLAMA_*` belong to module 04's `client_from_env()`, which this project reuses unchanged.

### The store seam

`VectorIndex` is a `Protocol` with two methods, the same seam as C#'s `IVectorIndex`. Chroma is one implementation and an in-memory brute-force scan is the other: exact, offline, and plenty fast for a corpus this size.

```python
# app/store.py
from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlparse

import chromadb
import numpy as np

from app.config import Settings

VECTOR_STORES = ("chroma", "memory")


@dataclass(frozen=True)
class Chunk:
    id: str
    text: str
    source: str


@dataclass(frozen=True)
class Hit:
    id: str
    text: str
    source: str
    score: float


class VectorIndex(Protocol):
    """The store seam. Chroma locally, in memory for tests, something managed in prod."""

    def upsert(self, chunks: Sequence[Chunk], vectors: Sequence[Sequence[float]]) -> None: ...

    def query(self, vector: Sequence[float], k: int) -> list[Hit]: ...


class InMemoryIndex:
    """VECTOR_STORE=memory: a brute-force cosine scan. Exact, and plenty fast for a few thousand chunks."""

    def __init__(self) -> None:
        self._rows: dict[str, tuple[Chunk, np.ndarray]] = {}

    def upsert(self, chunks: Sequence[Chunk], vectors: Sequence[Sequence[float]]) -> None:
        for chunk, vector in zip(chunks, vectors, strict=True):
            self._rows[chunk.id] = (chunk, np.asarray(vector, dtype=np.float32))

    def query(self, vector: Sequence[float], k: int) -> list[Hit]:
        q = np.asarray(vector, dtype=np.float32)
        hits = [Hit(c.id, c.text, c.source, _cosine(q, v)) for c, v in self._rows.values()]
        # Best first, ties broken by id, so both languages return the same order. Rounding
        # absorbs the last-bit noise of different float summation orders.
        hits.sort(key=lambda h: (-round(h.score, 6), h.id))
        return hits[:k]


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    norms = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(a @ b) / norms if norms else 0.0   # an empty text has no direction: score 0


class ChromaIndex:
    """VECTOR_STORE=chroma: a Chroma server over HTTP. Connects on first use, so the
    service starts (and /health answers) before Chroma is up."""

    def __init__(self, url: str, collection: str) -> None:
        self._url = urlparse(url)
        self._name = collection
        self._collection: Any = None

    def _get(self) -> Any:
        if self._collection is None:
            client = chromadb.HttpClient(
                host=self._url.hostname or "localhost",
                port=self._url.port or 8000,
                ssl=self._url.scheme == "https",
            )
            # We embed ourselves, so no embedding function. Cosine, so distance = 1 - similarity.
            self._collection = client.get_or_create_collection(
                self._name, metadata={"hnsw:space": "cosine"}, embedding_function=None
            )
        return self._collection

    def upsert(self, chunks: Sequence[Chunk], vectors: Sequence[Sequence[float]]) -> None:
        self._get().upsert(
            ids=[c.id for c in chunks],
            documents=[c.text for c in chunks],
            embeddings=[list(v) for v in vectors],
            metadatas=[{"source": c.source} for c in chunks],
        )

    def query(self, vector: Sequence[float], k: int) -> list[Hit]:
        res = self._get().query(
            query_embeddings=[list(vector)], n_results=k, include=["documents", "metadatas", "distances"]
        )
        # One query vector in, so read row [0] of each column.
        return [
            Hit(id_, doc, str(meta["source"]), 1.0 - dist)
            for id_, doc, meta, dist in zip(
                res["ids"][0], res["documents"][0], res["metadatas"][0], res["distances"][0]
            )
        ]


def index_from_env(settings: Settings) -> VectorIndex:
    """Pick the store from VECTOR_STORE. Unknown values fail loudly, like LLM_BACKEND."""
    if settings.vector_store == "memory":
        return InMemoryIndex()
    if settings.vector_store == "chroma":
        return ChromaIndex(settings.chroma_url, settings.chroma_collection)
    raise ValueError(
        f"unknown VECTOR_STORE {settings.vector_store!r} (expected one of: {' | '.join(VECTOR_STORES)})"
    )
```

Three details matter:

- **Ties break by id.** Two chunks can score the same, and dict order isn't a contract. Sorting on `(-score, id)` makes the order deterministic, and C# sorts the same way, so the two sides return the same ids. The score is rounded to 6 places for the sort, because numpy and .NET's SIMD sum floats in different orders and differ in the last bits.
- **Chroma connects on first use.** The service starts, and `/health` answers, before Chroma is up. `embedding_function=None` because this service embeds its own text, so Chroma never needs a model.
- **The in-memory index is what module 12 deploys** ([ADR-003](adr/003-module-12-deploys-real-rag.md)). There, the image build computes the corpus embeddings, and startup calls `upsert` with them instead of re-embedding. `upsert` already takes precomputed vectors, so that's a loader, not a new index.

### The embedder seam

```python
# app/embeddings.py
from __future__ import annotations

import re
from collections.abc import Sequence
from typing import TYPE_CHECKING, Protocol

from app.config import Settings

if TYPE_CHECKING:
    from sentence_transformers import SentenceTransformer

EMBED_BACKENDS = ("sentence-transformers", "hashing")


class Embedder(Protocol):
    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...


class SentenceTransformerEmbedder:
    """EMBED_BACKEND=sentence-transformers: a real embedding model, in-process on CPU.
    Loaded on first use, because importing torch and loading the model takes seconds."""

    def __init__(self, model_name: str) -> None:
        self._name = model_name
        self._model: SentenceTransformer | None = None

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(self._name)   # downloads once, into the HF cache
        return self._model.encode(list(texts), convert_to_numpy=True).tolist()


class HashingEmbedder:
    """EMBED_BACKEND=hashing: each word is hashed into one of `dimensions` buckets.
    Lexical, not semantic, but deterministic, offline and instant: what the tests and
    the stub cross-check use. FNV-1a, not hash(), which Python salts per process."""

    def __init__(self, dimensions: int = 256) -> None:
        self._dims = dimensions

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [self._one(t) for t in texts]

    def _one(self, text: str) -> list[float]:
        v = [0.0] * self._dims
        for word in re.findall(r"[a-z0-9]+", text.lower()):
            v[fnv1a(word) % self._dims] += 1.0
        return v


def fnv1a(word: str) -> int:
    """32-bit FNV-1a over the UTF-8 bytes: the same number in every process, and in C#."""
    h = 0x811C9DC5
    for b in word.encode("utf-8"):
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def embedder_from_env(settings: Settings) -> Embedder:
    """Pick the embedder from EMBED_BACKEND. Index and query must use the same one."""
    if settings.embed_backend == "sentence-transformers":
        return SentenceTransformerEmbedder(settings.embed_model)
    if settings.embed_backend == "hashing":
        return HashingEmbedder()
    raise ValueError(
        f"unknown EMBED_BACKEND {settings.embed_backend!r} (expected one of: {' | '.join(EMBED_BACKENDS)})"
    )
```

`HashingEmbedder` is a bag of words: each word adds 1 to one of 256 buckets. Two texts that share words point roughly the same way, which is enough to test retrieval plumbing, but it knows nothing about meaning ("rollback" and "revert" never meet). Its job is determinism. Python's `hash()` is salted per process, and so is .NET's `string.GetHashCode()`, so both sides use FNV-1a, a tiny hash with published test values, to land every word in the same bucket in both languages.

### The chunker and ingest

Structure-aware-ish: split on blank lines into paragraphs, then pack paragraphs up to a word budget with overlap. Kept deliberately simple and readable.

```python
# app/ingest.py
from __future__ import annotations

from pathlib import Path

from app.embeddings import Embedder
from app.store import Chunk, VectorIndex


def chunk_text(text: str, source: str, max_words: int = 180, overlap: int = 30) -> list[Chunk]:
    """Pack paragraphs into ~max_words chunks with word overlap.

    Word counts stand in for tokens here to keep the dependency surface small;
    for production, count real tokens with the model's tokenizer.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")   # a CRLF file splits like an LF one
    paras = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks: list[Chunk] = []
    buf: list[str] = []
    for para in paras:
        words = para.split()
        if len(buf) + len(words) > max_words and buf:
            # Deterministic id (same scheme as C#): re-ingest overwrites instead of duplicating.
            chunks.append(Chunk(id=f"{source}#{len(chunks)}", text=" ".join(buf), source=source))
            # Carry the tail forward as overlap. buf[-0:] would be the WHOLE list, hence the guard.
            buf = buf[-overlap:] if overlap else []
        buf.extend(words)
    if buf:
        chunks.append(Chunk(id=f"{source}#{len(chunks)}", text=" ".join(buf), source=source))
    return chunks


def ingest_folder(folder: Path, embedder: Embedder, index: VectorIndex) -> int:
    """Load every .md under folder, chunk, embed, and upsert. Returns the chunk count."""
    total = 0
    # Sorted, with forward slashes on every OS, so sources and ids match the C# side.
    for path in sorted(folder.rglob("*.md"), key=lambda p: p.relative_to(folder).as_posix()):
        source = path.relative_to(folder).as_posix()
        chunks = chunk_text(path.read_text(encoding="utf-8"), source)
        if not chunks:
            continue
        index.upsert(chunks, embedder.embed([c.text for c in chunks]))
        total += len(chunks)
    return total
```

### The retriever

```python
# app/retriever.py
from app.embeddings import Embedder
from app.store import Hit, VectorIndex


def retrieve(query: str, k: int, embedder: Embedder, index: VectorIndex) -> list[Hit]:
    """Embed the query with the SAME embedder used at ingest, then top-k search.
    Metadata filters, a keyword pass and a reranker would all go here."""
    return index.query(embedder.embed([query])[0], k)
```

A production `retrieve` would add metadata filters (`collection.query(where={"source": ...})`), a hybrid keyword pass and a rerank step. They're left as an extension point so the core loop stays legible. Add them once the eval tells you retrieval is the bottleneck.

### Assemble and generate

```python
# app/rag.py
from __future__ import annotations

import asyncio
from collections.abc import Sequence
from dataclasses import dataclass

from llm_client.types import LlmClient, Message
from pydantic import BaseModel

from app.embeddings import Embedder
from app.retriever import retrieve
from app.store import Hit, VectorIndex

SYSTEM = (
    "Answer the question using ONLY the context below. "
    "Cite the source tag (e.g. [S1]) after each claim it supports. "
    "If the context does not contain the answer, reply exactly: "
    '"I don\'t know based on the provided documents."'
)


class Citation(BaseModel):
    tag: str        # "S1": what the answer cites
    source: str     # "oncall.md": the file
    chunk_id: str   # "oncall.md#0": the exact chunk


class Answer(BaseModel):
    answer: str
    citations: list[Citation]


def build_prompt(question: str, hits: Sequence[Hit]) -> str:
    lines = ["Context:"]
    for i, h in enumerate(hits, start=1):
        lines.append(f"[S{i}] ({h.source}) {h.text}")
    lines.append(f"\nQuestion: {question}")
    return "\n".join(lines)


@dataclass(frozen=True)
class Rag:
    """The query pipeline: retrieve, then generate. Each part is a seam chosen from the environment."""

    embedder: Embedder
    index: VectorIndex
    llm: LlmClient   # module 04's client: stub, ollama or hosted, picked by LLM_BACKEND

    async def answer(self, question: str, k: int = 4) -> Answer:
        # The embedder and the Chroma client block: run them off the event loop.
        hits = await asyncio.to_thread(retrieve, question, k, self.embedder, self.index)
        messages = [Message("system", SYSTEM), Message("user", build_prompt(question, hits))]
        reply = await self.llm.complete(messages)
        return Answer(
            answer=reply.text,
            citations=[Citation(tag=f"S{i}", source=h.source, chunk_id=h.id) for i, h in enumerate(hits, 1)],
        )
```

The model call is module 04's `LlmClient`, so `LLM_BACKEND=stub` answers offline and `ollama` or `hosted` answer for real, with the cost log line on every call. `asyncio.to_thread` keeps the blocking parts (the embedding model and the Chroma client) off the event loop, so one slow request doesn't stall the others.

### FastAPI surface

```python
# app/main.py
from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import FastAPI, HTTPException
from llm_client.factory import client_from_env
from pydantic import BaseModel, Field

from app.config import Settings
from app.embeddings import embedder_from_env
from app.ingest import ingest_folder
from app.rag import Answer, Rag
from app.store import index_from_env


@lru_cache
def settings() -> Settings:
    return Settings()


@lru_cache
def rag() -> Rag:
    s = settings()
    return Rag(embedder=embedder_from_env(s), index=index_from_env(s), llm=client_from_env())


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    rag()   # build it at startup: a bad LLM_BACKEND, EMBED_BACKEND or VECTOR_STORE fails now
    yield


app = FastAPI(title="rag-service", lifespan=lifespan)


class AskRequest(BaseModel):
    question: str = Field(min_length=1)   # missing, null or "" -> 422
    k: int = Field(default=4, ge=1, le=20)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ingest")
def ingest(folder: str = ".") -> dict[str, int]:
    # folder comes from the caller, so it's untrusted: resolve it under the corpus root.
    root = (settings().fixtures_dir / "corpus").resolve()
    target = (root / folder).resolve()
    if not target.is_relative_to(root) or not target.is_dir():
        raise HTTPException(400, "folder must be an existing directory under the corpus root")
    r = rag()
    return {"chunks_indexed": ingest_folder(target, r.embedder, r.index)}


@app.post("/ask")
async def ask(req: AskRequest) -> Answer:
    return await rag().answer(req.question, req.k)
```

The `lru_cache` functions build the settings and the pipeline once, on first use, like a singleton registration. The `lifespan` hook calls `rag()` at startup, so a bad `VECTOR_STORE` stops the service from starting instead of failing the first request. `Field(min_length=1)` makes a missing, null or empty `question` a 422, and `ge`/`le` bound `k`.

The `/ingest` check matters because `?folder=` lets the caller pick a path on the server: passed straight to `rglob`, `folder=../..` or `/etc` would index whatever it reaches. That's path traversal, the "untrusted input at a boundary" from module 06.

### The tiny retrieval eval

This is the seed of module 09. A few `question → expected source` pairs, and `recall@k`: of the questions, what fraction had the correct source somewhere in the top-k? The script indexes the corpus into whichever store is configured first, so it works on the in-memory index too.

```python
# eval/recall_at_k.py
"""recall@k over fixtures/qa.jsonl. From python/: uv run python -m eval.recall_at_k 4"""
from __future__ import annotations

import json
import sys
from collections.abc import Callable, Sequence
from pathlib import Path

from app.config import Settings
from app.embeddings import embedder_from_env
from app.ingest import ingest_folder
from app.retriever import retrieve
from app.store import Hit, index_from_env


def load_jsonl(path: Path) -> list[dict[str, str]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def recall_at_k(
    rows: Sequence[dict[str, str]], retrieve_fn: Callable[[str, int], list[Hit]], k: int
) -> float:
    """Of the questions, what fraction had the expected source somewhere in the top-k?"""
    if not rows:
        return 0.0
    found = sum(row["expected_source"] in {h.source for h in retrieve_fn(row["question"], k)} for row in rows)
    return found / len(rows)


def main() -> None:
    k = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    s = Settings()
    embedder, index = embedder_from_env(s), index_from_env(s)
    # Index the corpus first. The ids are deterministic, so on Chroma this just overwrites.
    ingest_folder(s.fixtures_dir / "corpus", embedder, index)
    rows = load_jsonl(s.fixtures_dir / "qa.jsonl")
    score = recall_at_k(rows, lambda q, n: retrieve(q, n, embedder, index), k)
    print(f"recall@{k} = {score:.2f}")


if __name__ == "__main__":
    main()
```

Now "did my chunking change help?" is a number, not an argument. Change `max_words`, re-run, and see whether `recall@4` went up. That reflex is the entire point of the exercise.

### Tests

The tests run the real app with the three offline seams. The stub replies `stub: <last user message>`, and the last user message is the assembled prompt, so the API test can see exactly what the model was given.

```python
# tests/conftest.py
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import main

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"   # tests/ -> python/ -> the project root


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES


@pytest.fixture
def offline_app(monkeypatch: pytest.MonkeyPatch) -> Iterator[FastAPI]:
    """The real app, with every seam on its offline backend: stub model, hashing embeddings,
    in-memory index. The app caches its settings and pipeline, so clear them around each test."""
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.delenv("LLM_STUB_REPLY", raising=False)
    monkeypatch.setenv("EMBED_BACKEND", "hashing")
    monkeypatch.setenv("VECTOR_STORE", "memory")
    monkeypatch.setenv("FIXTURES_DIR", str(FIXTURES))
    main.settings.cache_clear()
    main.rag.cache_clear()
    yield main.app
    main.settings.cache_clear()
    main.rag.cache_clear()


@pytest.fixture
def api(offline_app: FastAPI) -> Iterator[TestClient]:
    with TestClient(offline_app) as client:   # `with` runs the lifespan, so the startup checks run too
        yield client
```

```python
# tests/test_chunker.py
import pytest

from app.ingest import chunk_text


def words(n: int, prefix: str) -> str:
    return " ".join(f"{prefix}{i}" for i in range(n))


def test_small_doc_is_one_chunk():
    assert [c.text for c in chunk_text("one two\n\nthree", "a.md")] == ["one two three"]


def test_packs_paragraphs_and_carries_overlap():
    chunks = chunk_text(f"{words(100, 'a')}\n\n{words(100, 'b')}", "a.md", max_words=180, overlap=30)
    assert len(chunks) == 2
    assert len(chunks[0].text.split()) == 100
    assert len(chunks[1].text.split()) == 130   # 30 carried + 100 new
    assert chunks[1].text.startswith("a70 ")


def test_overlap_zero_carries_nothing():
    # buf[-0:] is the whole list: without the guard, chunk 2 would repeat all of chunk 1.
    chunks = chunk_text(f"{words(100, 'a')}\n\n{words(100, 'b')}", "a.md", max_words=180, overlap=0)
    assert [len(c.text.split()) for c in chunks] == [100, 100]
    assert chunks[1].text.startswith("b0 ")


@pytest.mark.parametrize("sep", ["\n\n", "\r\n\r\n"])
def test_paragraph_breaks_work_with_any_line_ending(sep):
    assert len(chunk_text(f"{words(100, 'a')}{sep}{words(100, 'b')}", "a.md")) == 2


def test_corpus_chunks_match_the_csharp_side(fixtures_dir):
    # ChunkerTests.cs pins the same ids and word counts: the cheapest exact cross-check there is.
    chunks = [
        c
        for path in sorted((fixtures_dir / "corpus").glob("*.md"))
        for c in chunk_text(path.read_text(encoding="utf-8"), path.name)
    ]
    assert [(c.id, len(c.text.split())) for c in chunks] == [
        ("billing.md#0", 105),
        ("oncall.md#0", 155),
        ("oncall.md#1", 74),
    ]
```

```python
# tests/test_prompt.py
from app.rag import build_prompt
from app.store import Hit


def test_prompt_matches_the_csharp_format():
    hits = [
        Hit("oncall.md#0", "To roll back, run deploy --revert.", "oncall.md", 0.9),
        Hit("oncall.md#1", "Rollbacks are safe within 24h.", "oncall.md", 0.8),
    ]
    # Byte for byte the string PromptTests.cs expects.
    assert build_prompt("How do I roll back?", hits) == (
        "Context:\n"
        "[S1] (oncall.md) To roll back, run deploy --revert.\n"
        "[S2] (oncall.md) Rollbacks are safe within 24h.\n"
        "\nQuestion: How do I roll back?"
    )
```

```python
# tests/test_retrieval.py
import pytest

from app.embeddings import HashingEmbedder, fnv1a
from app.ingest import ingest_folder
from app.retriever import retrieve
from app.store import Chunk, Hit, InMemoryIndex
from eval.recall_at_k import recall_at_k


def test_fnv1a_matches_the_reference_values():
    assert fnv1a("a") == 0xE40C292C
    assert fnv1a("hello") == 0x4F9F2CAB


def test_in_memory_index_ranks_by_cosine_and_breaks_ties_by_id():
    index = InMemoryIndex()
    chunks = [Chunk("b", "", "b.md"), Chunk("a", "", "a.md"), Chunk("c", "", "c.md")]
    index.upsert(chunks, [[1.0, 0.0], [2.0, 0.0], [0.0, 1.0]])   # a and b point the same way
    assert [h.id for h in index.query([1.0, 0.0], k=2)] == ["a", "b"]


@pytest.mark.parametrize(
    ("question", "expected_ids"),
    [
        ("How do I roll back a deploy?", ["oncall.md#0", "oncall.md#1", "billing.md#0"]),
        ("How are customers billed for overages?", ["billing.md#0", "oncall.md#1", "oncall.md#0"]),
    ],
)
def test_hashing_retrieval_matches_the_csharp_side(fixtures_dir, question, expected_ids):
    # RetrievalTests.cs pins the same ids: same corpus, chunker, hash and tie-break.
    embedder, index = HashingEmbedder(), InMemoryIndex()
    ingest_folder(fixtures_dir / "corpus", embedder, index)
    assert [h.id for h in retrieve(question, 3, embedder, index)] == expected_ids


def test_recall_at_k_counts_questions_whose_source_is_in_the_top_k():
    rows = [
        {"question": "q1", "expected_source": "a.md"},
        {"question": "q2", "expected_source": "b.md"},
        {"question": "q3", "expected_source": "c.md"},
    ]
    top = {"q1": "a.md", "q2": "b.md", "q3": "z.md"}
    assert recall_at_k(rows, lambda q, k: [Hit("id", "text", top[q], 1.0)], k=4) == pytest.approx(2 / 3)
```

```python
# tests/test_api.py
import pytest
from fastapi.testclient import TestClient


def test_health(api):
    assert api.get("/health").json() == {"status": "ok"}


def test_ingest_then_ask_returns_a_cited_answer(api):
    assert api.post("/ingest").json() == {"chunks_indexed": 3}

    res = api.post("/ask", json={"question": "How do I roll back a deploy?", "k": 2})

    assert res.status_code == 200
    body = res.json()
    # The stub replies "stub: <last user message>", so the answer shows the prompt the model got.
    assert body["answer"].startswith("stub: Context:\n[S1] (oncall.md) # On-call runbook")
    assert body["answer"].endswith("\nQuestion: How do I roll back a deploy?")
    assert body["citations"] == [
        {"tag": "S1", "source": "oncall.md", "chunk_id": "oncall.md#0"},
        {"tag": "S2", "source": "oncall.md", "chunk_id": "oncall.md#1"},
    ]


@pytest.mark.parametrize(
    "body", [{}, {"question": None}, {"question": ""}, {"question": "q", "k": 0}, {"question": "q", "k": 21}]
)
def test_ask_rejects_a_bad_request_with_422(api, body):
    assert api.post("/ask", json=body).status_code == 422


@pytest.mark.parametrize("folder", ["..", "/etc"])
def test_ingest_rejects_folders_outside_the_root(api, folder):
    assert api.post("/ingest", params={"folder": folder}).status_code == 400


def test_unknown_vector_store_fails_at_startup(offline_app, monkeypatch):
    monkeypatch.setenv("VECTOR_STORE", "pinecone")
    with pytest.raises(ValueError, match="chroma | memory"), TestClient(offline_app):
        pass
```

The pinned lists (chunk ids and word counts, hashing retrieval ids, the prompt) appear in the C# tests too. They're the exact half of the cross-check, run on every `pytest` and `dotnet test`.

### Configuration

```bash
# projects/07-rag-service/python/.env.example
# Copy to .env (git-ignored). Names: docs/conventions.md#environment-variables
# compose reads this file; a bare `uv run` doesn't, so set variables in your shell there.
# The C# stack reads the same names: copy it to csharp/.env too.

# Generation, through module 04's client: stub | ollama | hosted
LLM_BACKEND=ollama
# ollama: the server root, without /v1. Leave it commented: compose then uses
# http://host.docker.internal:11434 (or the ollama profile's service), and local runs
# default to http://localhost:11434. A localhost value here would point the container at itself.
# OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.2
# hosted: LLM_BASE_URL (with /v1), LLM_API_KEY, LLM_MODEL and the Rates__* pair, as in module 04

# Embeddings. Python: sentence-transformers | hashing. C#: ollama | hashing.
# EMBED_BACKEND=sentence-transformers
EMBED_MODEL=sentence-transformers/all-MiniLM-L6-v2
OLLAMA_EMBED_MODEL=all-minilm

# Store: chroma | memory
VECTOR_STORE=chroma
# CHROMA_URL=http://localhost:8003       # Python's default; C#'s is http://localhost:8002
# CHROMA_COLLECTION=docs                 # Python's default; C#'s is docs-cs

# The defaults work from python/ and csharp/; the Dockerfiles set the container path.
# FIXTURES_DIR=../fixtures
```

The lines that differ between the languages are commented out, so each side falls back to its own default.

Run locally:

```powershell
uv run pytest                                    # offline: stub, hashing, in-memory

# The whole service, offline. No model, no Chroma, no embedding download.
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'
uv run --no-sync uvicorn app.main:app --port 8000
```

In a second terminal:

```powershell
Invoke-RestMethod -Method Post http://localhost:8000/ingest
Invoke-RestMethod -Method Post http://localhost:8000/ask -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?","k":2}' | ConvertTo-Json -Depth 5
$env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'; uv run python -m eval.recall_at_k 1
```

On the hashing embedder `recall@1` is 0.80: "Who has to approve a refund?" shares more filler words with `oncall.md` than with `billing.md`. Now the real thing. Start Chroma and Ollama from the compose file, clear the offline settings, and run again:

```powershell
docker compose up -d chroma                      # Chroma on localhost:8003
ollama pull llama3.2                             # native Ollama; or: docker compose --profile ollama up -d ollama
Remove-Item Env:LLM_BACKEND, Env:EMBED_BACKEND, Env:VECTOR_STORE -ErrorAction SilentlyContinue
uv run python -m eval.recall_at_k 1              # first run downloads all-MiniLM-L6-v2 (~90 MB)
uv run --no-sync uvicorn app.main:app --port 8000
```

With all-MiniLM-L6-v2, `recall@1` on this set is 1.00. Same chunks, same questions; the only change is embeddings that know "refund" belongs with billing.

### Running the Python version in Docker

The image needs project 04 as well as `fixtures/`, so the build context is `projects/` and the image keeps the repo's folder layout. The `../../04-llm-client/python` path dependency and the `../fixtures` default then resolve unchanged, as in [module 05](05-prompt-engineering-as-engineering.md).

```dockerfile
# projects/07-rag-service/python/Dockerfile — build context: projects/
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
# Project 04 first: the path dependency must exist before uv can install anything.
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 07-rag-service/python/pyproject.toml 07-rag-service/python/uv.lock 07-rag-service/python/
WORKDIR /src/07-rag-service/python
# Service shape: install the locked dependencies (04 and CPU-only torch included). The code is copied, never installed.
RUN uv sync --frozen --no-install-project
COPY 07-rag-service/python/ ./
COPY 07-rag-service/fixtures/ /src/07-rag-service/fixtures/
ENV PATH="/src/07-rag-service/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/07-rag-service/fixtures
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

A context as wide as `projects/` needs a filter, or every venv in the repo gets sent to the build. BuildKit reads `Dockerfile.dockerignore` from beside the Dockerfile whatever the context, and the scaffold's version already uses `**/` patterns that match at any depth:

```text
**/.venv/
**/__pycache__/
**/.pytest_cache/
**/.ruff_cache/
**/.mypy_cache/
**/.vscode/
**/outputs/
**/runs/
**/bin/
**/obj/
```

`compose.yaml` runs Chroma as its own service and the app next to it, mirroring the prod split of "app talks to a managed vector store over the network":

```yaml
# projects/07-rag-service/python/compose.yaml
name: rag-service-py   # otherwise the project is named after the folder: "python"
services:
  chroma:
    image: chromadb/chroma:1.5.9   # pinned to the chromadb-client minor version in pyproject.toml
    ports: ["8003:8000"]           # 8001 is the C# service, 8002 the C# stack's Chroma
    volumes: ["chroma-data:/data"]

  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: { context: ../.., dockerfile: 07-rag-service/python/Dockerfile }   # projects/: 04 and fixtures/ must be inside
    ports: ["8000:8000"]
    env_file:
      - path: .env   # hosted keys and overrides; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      EMBED_BACKEND: ${EMBED_BACKEND:-sentence-transformers}
      VECTOR_STORE: ${VECTOR_STORE:-chroma}
      CHROMA_URL: http://chroma:8000          # the compose service, not localhost:8003
    extra_hosts: ["host.docker.internal:host-gateway"]   # Linux hosts; harmless on Docker Desktop
    volumes: ["hf-cache:/root/.cache/huggingface"]      # the embedding model downloads once
    depends_on: [chroma]

volumes:
  chroma-data:
  hf-cache:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

With [native Ollama](conventions.md#ollama) running, `docker compose up` is all you need: the app reaches it at `host.docker.internal:11434`. To run Ollama in the stack instead, add `--profile ollama`, as below.

```powershell
cd projects/07-rag-service/python
docker compose --profile ollama up --build -d
docker compose exec ollama ollama pull llama3.2
Invoke-RestMethod -Method Post http://localhost:8000/ingest      # first call downloads the embedding model
Invoke-RestMethod -Method Post http://localhost:8000/ask -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?","k":4}' | ConvertTo-Json -Depth 5
docker compose exec app python -m eval.recall_at_k 4
docker compose run --rm --no-deps app pytest -q                  # offline: the tests pick their own seams
# Without compose (from the repo root): docker build -f projects/07-rag-service/python/Dockerfile -t rag-service-py projects
```

Then **break it on purpose** (module 00's advice): ask something that isn't in the corpus and confirm you get "I don't know," not a fabrication. Set `k` to 1 and watch recall drop. This is the muscle you're building.

The image is large (CPU PyTorch is several hundred MB) and the model downloads on first use into the `hf-cache` volume, so it survives `docker compose down`. Module 12 revisits both when it bakes the index into the image.

## C# implementation

Work in `projects/07-rag-service/csharp/`. Same endpoints, same JSON, same corpus, same chunking rules, same environment variables. What's different:

- **FastAPI → ASP.NET Core minimal API.** `app.MapPost("/ask", ...)` is the same idea as `@app.post("/ask")`: a handler bound to a route, with the request body bound to a record. The response JSON is configured to snake_case so it matches the Python service field for field.
- **The model comes from module 04.** `AddLlmClient` registers `IChatClient` for `LLM_BACKEND`, with cost logging, exactly as in 04. This project never constructs a chat client itself.
- **Embeddings go through an interface, not a library call.** Python calls `SentenceTransformer(...).encode()` in-process. C# depends on `IEmbeddingGenerator<string, Embedding<float>>` from `Microsoft.Extensions.AI`. Locally that's Ollama's `all-minilm`, the same base model (all-MiniLM-L6-v2) the Python side uses. (Module 03's ONNX `MiniLmEmbedder` would also work behind this interface. If you go that way, add truncation at 256 word-pieces to match `sentence-transformers`.)
- **The vector store is honest HTTP.** Chroma's first-class client is Python. In .NET you have three options, and none of them is as polished:
  1. **Chroma's REST API through a small typed `HttpClient`.** This doc does that. It's about 60 lines, and you see exactly what goes over the wire. The cost: you track Chroma's API versions yourself, which is why the compose file pins the server image.
  2. **`Microsoft.Extensions.VectorData`** (MEVD), the provider-neutral vector-store abstraction that pairs with `Microsoft.Extensions.AI`. You annotate a record with key/data/vector attributes and get upsert and vector search over any connector. At the time of writing, Chroma's .NET connector is a Semantic Kernel alpha package that predates MEVD. Qdrant, Postgres/pgvector, Redis, Azure AI Search and an in-memory store have more mature MEVD connectors. Check the current connector list before you choose.
  3. **A community Chroma client from NuGet.** Fine for experiments. Check how recently it was updated against Chroma's API.
- **The chunker and the hashing embedder are hand-written on both sides, on purpose.** Same input, same chunk boundaries, same vectors, and that's a cross-check you can assert. `Microsoft.SemanticKernel.Text.TextChunker` (marked experimental) is the off-the-shelf .NET option, but it splits differently, so you'd lose the parity check.

### Scaffold

From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 07-rag-service -Template webapi -Name RagService
cd projects/07-rag-service/csharp
Remove-Item src/RagService/RagService.http, tests/RagService.Tests/SmokeTests.cs
dotnet remove src/RagService package Microsoft.AspNetCore.OpenApi
dotnet add src/RagService reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add src/RagService package System.Numerics.Tensors
dotnet add tests/RagService.Tests package Microsoft.AspNetCore.Mvc.Testing
```

`Microsoft.Extensions.AI` and OllamaSharp come in through the `LlmClient` reference, at the versions module 04 pinned. This doc was built against those (MEAI 10.10, OllamaSharp 5.5), System.Numerics.Tensors 10.0 and Microsoft.AspNetCore.Mvc.Testing 10.0. Replace the template's `Program.cs` with the one below, and keep its `appsettings.json` and `launchSettings.json` as they are.

### `src/RagService/RagOptions.cs`

The `pydantic-settings` equivalent is a class bound from configuration. `[ConfigurationKeyName]` maps each property to the flat environment-variable name the Python side reads, so there's one set of names, not `Rag__ChromaUrl` on one side and `CHROMA_URL` on the other.

```csharp
// src/RagService/RagOptions.cs
using Microsoft.Extensions.Configuration;

namespace RagService;

/// <summary>
/// The service's own settings, read from the same environment variables as the Python Settings class.
/// [ConfigurationKeyName] maps each property to its flat name. The chat model isn't here:
/// LLM_BACKEND and OLLAMA_MODEL belong to module 04's AddLlmClient.
/// </summary>
public sealed class RagOptions
{
    public static readonly string[] VectorStores = ["chroma", "memory"];
    public static readonly string[] EmbedBackends = ["ollama", "hashing"];

    [ConfigurationKeyName("VECTOR_STORE")]
    public string VectorStore { get; set; } = "chroma";

    [ConfigurationKeyName("CHROMA_URL")]
    public string ChromaUrl { get; set; } = "http://localhost:8002";       // where compose.yaml publishes Chroma

    [ConfigurationKeyName("CHROMA_COLLECTION")]
    public string ChromaCollection { get; set; } = "docs-cs";              // Python's is "docs": see the cross-check

    [ConfigurationKeyName("EMBED_BACKEND")]
    public string EmbedBackend { get; set; } = "ollama";

    [ConfigurationKeyName("OLLAMA_BASE_URL")]
    public string OllamaBaseUrl { get; set; } = "http://localhost:11434";  // the server root, no /v1

    [ConfigurationKeyName("OLLAMA_EMBED_MODEL")]
    public string OllamaEmbedModel { get; set; } = "all-minilm";           // all-MiniLM-L6-v2, as in Python

    // `dotnet run` starts a web project in its own folder (src/RagService), so the default climbs three levels.
    [ConfigurationKeyName("FIXTURES_DIR")]
    public string FixturesDir { get; set; } = "../../../fixtures";

    /// <summary>/ingest may only read below this folder.</summary>
    public string CorpusRoot => Path.Combine(Path.GetFullPath(FixturesDir), "corpus");

    /// <summary>Unknown values fail at startup with the valid list, like LLM_BACKEND.</summary>
    public RagOptions Validate()
    {
        Check("VECTOR_STORE", VectorStore, VectorStores);
        Check("EMBED_BACKEND", EmbedBackend, EmbedBackends);
        return this;
    }

    private static void Check(string name, string value, string[] allowed)
    {
        if (!allowed.Contains(value))
            throw new InvalidOperationException(
                $"unknown {name} '{value}' (expected one of: {string.Join(" | ", allowed)})");
    }
}
```

The `FIXTURES_DIR` default is the one real difference. `dotnet run` starts a web project in the project's own folder (the Web SDK sets the working directory there, so `appsettings.json` is found), not in `csharp/` where you typed the command. So `../fixtures` would point at `src/fixtures`. The Dockerfile and the tests set `FIXTURES_DIR` explicitly, so only local runs use the default.

### `src/RagService/Chunker.cs`

```csharp
// src/RagService/Chunker.cs
namespace RagService;

public sealed record Chunk(string Id, string Text, string Source);

public static class Chunker
{
    /// <summary>Pack paragraphs into ~maxWords chunks with word overlap. Mirrors chunk_text in Python,
    /// so the same file gives the same chunk boundaries on both sides.</summary>
    public static IReadOnlyList<Chunk> ChunkText(string text, string source, int maxWords = 180, int overlap = 30)
    {
        // The same normalization as Python, so a CRLF file splits like an LF one.
        IEnumerable<string> paras = text.Replace("\r\n", "\n").Replace('\r', '\n')
            .Split("\n\n")
            .Select(p => p.Trim())
            .Where(p => p.Length > 0);

        List<Chunk> chunks = [];
        List<string> buf = [];
        foreach (string para in paras)
        {
            // Split(null, RemoveEmptyEntries) is Python's str.split(): any whitespace run, no empties.
            string[] words = para.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (buf.Count + words.Length > maxWords && buf.Count > 0)
            {
                chunks.Add(Make(buf, source, chunks.Count));
                buf = [.. buf.TakeLast(overlap)];   // carry the tail forward; TakeLast(0) is empty
            }
            buf.AddRange(words);
        }
        if (buf.Count > 0)
            chunks.Add(Make(buf, source, chunks.Count));
        return chunks;
    }

    // Deterministic id: re-ingesting a file overwrites its chunks instead of duplicating them.
    private static Chunk Make(List<string> words, string source, int index) =>
        new($"{source}#{index}", string.Join(' ', words), source);
}
```

The Python version tracks the buffer the same way, and here `buf.Count` is the word count. The ids use the same `source#index` scheme, so a re-ingest overwrites instead of duplicating, and the same file gives the same ids on both sides. (A file that *shrinks* still leaves its old tail chunks behind. A production ingest deletes by `source` first.)

### `src/RagService/VectorIndex.cs`

```csharp
// src/RagService/VectorIndex.cs
using System.Collections.Concurrent;
using System.Numerics.Tensors;

namespace RagService;

public sealed record Hit(string Id, string Text, string Source, double Score);

/// <summary>The store seam. Chroma locally, in memory for tests, something managed in prod.</summary>
public interface IVectorIndex
{
    Task UpsertAsync(IReadOnlyList<Chunk> chunks, IReadOnlyList<ReadOnlyMemory<float>> vectors, CancellationToken ct = default);
    Task<IReadOnlyList<Hit>> QueryAsync(ReadOnlyMemory<float> vector, int k, CancellationToken ct = default);
}

/// <summary>VECTOR_STORE=memory: a brute-force cosine scan. Exact, and plenty fast for a few thousand chunks.</summary>
public sealed class InMemoryVectorIndex : IVectorIndex
{
    private readonly ConcurrentDictionary<string, (Chunk Chunk, float[] Vector)> _rows = new();

    public Task UpsertAsync(IReadOnlyList<Chunk> chunks, IReadOnlyList<ReadOnlyMemory<float>> vectors, CancellationToken ct = default)
    {
        for (int i = 0; i < chunks.Count; i++)
            _rows[chunks[i].Id] = (chunks[i], vectors[i].ToArray());
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<Hit>> QueryAsync(ReadOnlyMemory<float> vector, int k, CancellationToken ct = default)
    {
        IReadOnlyList<Hit> hits =
        [
            .. _rows.Values
                .Select(r => new Hit(r.Chunk.Id, r.Chunk.Text, r.Chunk.Source, Cosine(vector.Span, r.Vector)))
                // Best first, ties broken by id, so both languages return the same order. Rounding
                // absorbs the last-bit noise of different float summation orders (SIMD vs numpy).
                .OrderByDescending(h => Math.Round(h.Score, 6))
                .ThenBy(h => h.Id, StringComparer.Ordinal)
                .Take(k),
        ];
        return Task.FromResult(hits);
    }

    private static double Cosine(ReadOnlySpan<float> a, ReadOnlySpan<float> b)
    {
        double norms = (double)TensorPrimitives.Norm(a) * TensorPrimitives.Norm(b);
        return norms == 0 ? 0 : TensorPrimitives.Dot(a, b) / norms;   // an empty text has no direction: score 0
    }
}
```

This is the "at small scale that's a brute-force scan" from the Store section, in about 30 lines. Chroma's HNSW index gives the same top-k on a corpus this size; the difference only shows up at scale.

### `src/RagService/ChromaVectorIndex.cs`

```csharp
// src/RagService/ChromaVectorIndex.cs
using System.Net.Http.Json;
using System.Text.Json;

namespace RagService;

/// <summary>
/// VECTOR_STORE=chroma: a small typed client over Chroma's REST API. The same server the
/// Python side uses, reached over HTTP instead of through the chromadb package.
/// </summary>
public sealed class ChromaVectorIndex(HttpClient http, RagOptions options) : IVectorIndex
{
    // Chroma's v2 API, as served by the image tag pinned in compose.yaml. Check the server's /docs if these 404.
    private const string Db = "api/v2/tenants/default_tenant/databases/default_database";

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    public async Task UpsertAsync(IReadOnlyList<Chunk> chunks, IReadOnlyList<ReadOnlyMemory<float>> vectors, CancellationToken ct = default)
    {
        string id = await CollectionIdAsync(ct);
        var body = new UpsertRequest(
            Ids: [.. chunks.Select(c => c.Id)],
            Embeddings: [.. vectors.Select(v => v.ToArray())],
            Documents: [.. chunks.Select(c => c.Text)],
            Metadatas: [.. chunks.Select(c => new Dictionary<string, string> { ["source"] = c.Source })]);
        using HttpResponseMessage res = await http.PostAsJsonAsync($"{Db}/collections/{id}/upsert", body, Json, ct);
        await EnsureOkAsync(res, ct);
    }

    public async Task<IReadOnlyList<Hit>> QueryAsync(ReadOnlyMemory<float> vector, int k, CancellationToken ct = default)
    {
        string id = await CollectionIdAsync(ct);
        var body = new QueryRequest([vector.ToArray()], k, ["documents", "metadatas", "distances"]);
        using HttpResponseMessage res = await http.PostAsJsonAsync($"{Db}/collections/{id}/query", body, Json, ct);
        await EnsureOkAsync(res, ct);
        QueryResponse q = (await res.Content.ReadFromJsonAsync<QueryResponse>(Json, ct))!;

        // One query vector in, so read row [0] of each column: res["documents"][0] in Python.
        List<Hit> hits = [];
        for (int i = 0; i < q.Ids[0].Length; i++)
        {
            string source = q.Metadatas[0][i]?.GetValueOrDefault("source") ?? "";
            // Chroma returns cosine *distance*; similarity = 1 - distance.
            hits.Add(new Hit(q.Ids[0][i], q.Documents[0][i] ?? "", source, 1.0 - q.Distances[0][i]));
        }
        return hits;
    }

    private async Task<string> CollectionIdAsync(CancellationToken ct)
    {
        // get_or_create, like the Python side. "hnsw:space": "cosine" makes distances cosine distances.
        var body = new
        {
            name = options.ChromaCollection,
            metadata = new Dictionary<string, string> { ["hnsw:space"] = "cosine" },
            get_or_create = true,
        };
        using HttpResponseMessage res = await http.PostAsJsonAsync($"{Db}/collections", body, Json, ct);
        await EnsureOkAsync(res, ct);
        return (await res.Content.ReadFromJsonAsync<CollectionInfo>(Json, ct))!.Id;
    }

    private static async Task EnsureOkAsync(HttpResponseMessage res, CancellationToken ct)
    {
        // Chroma explains a failure in the body ("expecting embedding with dimension of 384, got 256").
        // EnsureSuccessStatusCode() would throw that away and keep only "400 (Bad Request)".
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"Chroma {(int)res.StatusCode}: {await res.Content.ReadAsStringAsync(ct)}", null, res.StatusCode);
    }

    private sealed record CollectionInfo(string Id, string Name);
    private sealed record UpsertRequest(string[] Ids, float[][] Embeddings, string[] Documents, Dictionary<string, string>[] Metadatas);
    private sealed record QueryRequest(float[][] QueryEmbeddings, int NResults, string[] Include);
    private sealed record QueryResponse(string[][] Ids, string?[][] Documents, Dictionary<string, string>?[][] Metadatas, double[][] Distances);
}
```

Everything the `chromadb` package hid is visible here: tenants and databases, the collection id lookup, the column-oriented response (one row per query vector), and distance vs similarity. The snake_case naming policy turns `QueryEmbeddings` into `query_embeddings` and `NResults` into `n_results`. The paths and bodies were checked against the `chromadb/chroma:1.5.9` server the compose files pin. Chroma's HTTP API has changed between major versions (v1 → v2), so if you move the image tag, check the server's `/docs` page. It looks up the collection on every call to stay stateless; caching the id is an easy optimization once it works. `EnsureOkAsync` keeps Chroma's error body in the exception. `EnsureSuccessStatusCode()` would throw it away, and you'd be debugging the experiment in the cross-check from "400 (Bad Request)" alone.

### `src/RagService/HashingEmbeddingGenerator.cs`

```csharp
// src/RagService/HashingEmbeddingGenerator.cs
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;

namespace RagService;

/// <summary>
/// EMBED_BACKEND=hashing: the HashingEmbedder twin, rule for rule. Each word is hashed into one of
/// <paramref name="dimensions"/> buckets. Lexical, not semantic, but deterministic, offline and instant.
/// FNV-1a over UTF-8, never string.GetHashCode(), which .NET randomizes per process.
/// </summary>
public sealed partial class HashingEmbeddingGenerator(int dimensions = 256) : IEmbeddingGenerator<string, Embedding<float>>
{
    public Task<GeneratedEmbeddings<Embedding<float>>> GenerateAsync(
        IEnumerable<string> values, EmbeddingGenerationOptions? options = null, CancellationToken cancellationToken = default) =>
        Task.FromResult(new GeneratedEmbeddings<Embedding<float>>(values.Select(v => new Embedding<float>(Embed(v)))));

    private float[] Embed(string text)
    {
        var v = new float[dimensions];
        foreach (Match word in Word().Matches(text.ToLowerInvariant()))
            v[Fnv1a(word.Value) % (uint)dimensions] += 1f;
        return v;
    }

    /// <summary>32-bit FNV-1a over the UTF-8 bytes: the same number in every process, and in Python.</summary>
    public static uint Fnv1a(string word)
    {
        uint h = 0x811C9DC5;
        foreach (byte b in Encoding.UTF8.GetBytes(word))
            h = unchecked((h ^ b) * 0x01000193);
        return h;
    }

    [GeneratedRegex("[a-z0-9]+")]
    private static partial Regex Word();

    public object? GetService(Type serviceType, object? serviceKey = null) =>
        serviceKey is null && serviceType.IsInstanceOfType(this) ? this : null;

    public void Dispose() { }
}
```

It lives in `src/`, not in the tests, because `EMBED_BACKEND=hashing` is a real runtime option: it's what the offline cross-check runs on. `[GeneratedRegex]` compiles the pattern at build time, and `unchecked` makes the 32-bit wraparound that Python gets from `& 0xFFFFFFFF` explicit.

### `src/RagService/Ingestor.cs` and `Retriever.cs`

```csharp
// src/RagService/Ingestor.cs
using System.Diagnostics.CodeAnalysis;
using Microsoft.Extensions.AI;

namespace RagService;

public sealed class Ingestor(
    IEmbeddingGenerator<string, Embedding<float>> embedder,
    IVectorIndex index,
    RagOptions options,
    ILogger<Ingestor> logger)
{
    /// <summary>The folder comes from the caller, so it's untrusted: only allow existing folders under CorpusRoot.</summary>
    public bool TryResolve(string folder, [NotNullWhen(true)] out string? fullPath)
    {
        string root = options.CorpusRoot;
        string candidate = Path.GetFullPath(folder, root);
        bool inside = candidate == root || candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal);
        fullPath = inside && Directory.Exists(candidate) ? candidate : null;
        return fullPath is not null;
    }

    /// <summary>Load every .md under folder, chunk, embed, and upsert. Returns the chunk count.</summary>
    public async Task<int> IngestFolderAsync(string folder, CancellationToken ct = default)
    {
        int total = 0;
        // Sorted, with forward slashes on every OS, so sources and ids match the Python side.
        var files = Directory.EnumerateFiles(folder, "*.md", SearchOption.AllDirectories)
            .Select(path => (Path: path, Source: Path.GetRelativePath(folder, path).Replace('\\', '/')))
            .OrderBy(f => f.Source, StringComparer.Ordinal);
        foreach (var (path, source) in files)
        {
            IReadOnlyList<Chunk> chunks = Chunker.ChunkText(await File.ReadAllTextAsync(path, ct), source);
            if (chunks.Count == 0) continue;

            GeneratedEmbeddings<Embedding<float>> embeddings =
                await embedder.GenerateAsync(chunks.Select(c => c.Text), cancellationToken: ct);
            await index.UpsertAsync(chunks, [.. embeddings.Select(e => e.Vector)], ct);
            total += chunks.Count;
            logger.LogInformation("Indexed {Count} chunks from {Source}", chunks.Count, source);
        }
        return total;
    }
}
```

```csharp
// src/RagService/Retriever.cs
using Microsoft.Extensions.AI;

namespace RagService;

public sealed class Retriever(IEmbeddingGenerator<string, Embedding<float>> embedder, IVectorIndex index)
{
    /// <summary>Embed the query with the SAME embedder used at ingest, then top-k search.
    /// Metadata filters, a keyword pass and a reranker would all go here.</summary>
    public async Task<IReadOnlyList<Hit>> RetrieveAsync(string query, int k = 4, CancellationToken ct = default)
    {
        GeneratedEmbeddings<Embedding<float>> embedding = await embedder.GenerateAsync([query], cancellationToken: ct);
        return await index.QueryAsync(embedding[0].Vector, k, ct);
    }
}
```

`TryResolve` is the same check as the Python `/ingest` handler: resolve the folder under the corpus root, and reject anything that lands outside it. `Path.GetFullPath` plus `StartsWith` is the .NET spelling of `Path.resolve()` plus `is_relative_to`.

### `src/RagService/RagAnswerer.cs`

```csharp
// src/RagService/RagAnswerer.cs
using Microsoft.Extensions.AI;

namespace RagService;

/// <summary>The /ask body. Question is nullable because JSON can leave it out; Errors() rejects that.</summary>
public sealed record AskRequest(string? Question, int K = 4)
{
    /// <summary>The checks FastAPI's AskRequest model makes: question present and non-empty, 1 &lt;= k &lt;= 20.</summary>
    public Dictionary<string, string[]>? Errors()
    {
        Dictionary<string, string[]> errors = [];
        if (string.IsNullOrEmpty(Question)) errors["question"] = ["question is required"];
        if (K is < 1 or > 20) errors["k"] = ["k must be between 1 and 20"];
        return errors.Count > 0 ? errors : null;
    }
}

public sealed record Citation(string Tag, string Source, string ChunkId);
public sealed record AskResponse(string Answer, IReadOnlyList<Citation> Citations);

public sealed class RagAnswerer(Retriever retriever, IChatClient chat)
{
    public const string SystemPrompt =
        "Answer the question using ONLY the context below. " +
        "Cite the source tag (e.g. [S1]) after each claim it supports. " +
        "If the context does not contain the answer, reply exactly: " +
        "\"I don't know based on the provided documents.\"";

    /// <summary>Byte-for-byte the same prompt as build_prompt in Python. A golden test pins it.</summary>
    public static string BuildPrompt(string question, IReadOnlyList<Hit> hits)
    {
        List<string> lines = ["Context:"];
        lines.AddRange(hits.Select((h, i) => $"[S{i + 1}] ({h.Source}) {h.Text}"));
        lines.Add($"\nQuestion: {question}");
        return string.Join("\n", lines);
    }

    public async Task<AskResponse> AnswerAsync(string question, int k = 4, CancellationToken ct = default)
    {
        IReadOnlyList<Hit> hits = await retriever.RetrieveAsync(question, k, ct);
        List<ChatMessage> messages =
        [
            new(ChatRole.System, SystemPrompt),
            new(ChatRole.User, BuildPrompt(question, hits)),
        ];
        ChatResponse reply = await chat.GetResponseAsync(messages, cancellationToken: ct);
        return new AskResponse(reply.Text, [.. hits.Select((h, i) => new Citation($"S{i + 1}", h.Source, h.Id))]);
    }
}
```

The model is just an injected `IChatClient`: the stub in tests, Ollama locally, Bedrock in module 12, and the code here never changes. `Question` is `string?` on purpose. System.Text.Json binds a missing property to `null` even when the type says it can't be, so the honest type plus an explicit check is what gets you FastAPI's 422.

### `src/RagService/RecallAtK.cs`

The metric is a pure function, so it gets unit-tested like any other code. The retriever comes in as a delegate.

```csharp
// src/RagService/RecallAtK.cs
using System.Text.Json;

namespace RagService;

public sealed record QaRow(string Question, string ExpectedSource);

public static class RecallAtK
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    public static IReadOnlyList<QaRow> LoadJsonl(string path) =>
        [.. File.ReadLines(path).Where(l => l.Trim().Length > 0).Select(l => JsonSerializer.Deserialize<QaRow>(l, Json)!)];

    /// <summary>Of the questions, what fraction had the expected source somewhere in the top-k?</summary>
    public static async Task<double> ComputeAsync(
        IReadOnlyList<QaRow> rows,
        Func<string, int, CancellationToken, Task<IReadOnlyList<Hit>>> retrieve,
        int k = 4,
        CancellationToken ct = default)
    {
        if (rows.Count == 0) return 0.0;
        int found = 0;
        foreach (QaRow row in rows)
        {
            IReadOnlyList<Hit> hits = await retrieve(row.Question, k, ct);
            if (hits.Any(h => h.Source == row.ExpectedSource)) found++;
        }
        return (double)found / rows.Count;
    }
}
```

### `src/RagService/Program.cs`

```csharp
// src/RagService/Program.cs
using System.Text.Json;
using LlmClient;
using Microsoft.Extensions.AI;
using OllamaSharp;
using RagService;

var builder = WebApplication.CreateBuilder(args);

// Same env-var names as the Python service. Read once, here, because they decide what gets registered.
RagOptions rag = (builder.Configuration.Get<RagOptions>() ?? new()).Validate();
builder.Services.AddSingleton(rag);

// snake_case on the wire, so requests and responses match the Python service field for field.
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);

// Chat model: module 04's library picks stub | ollama | hosted from LLM_BACKEND, with cost logging.
builder.Services.AddLlmClient(builder.Configuration);

// Embeddings: the same model at ingest and query, whatever it is.
builder.Services.AddSingleton<IEmbeddingGenerator<string, Embedding<float>>>(rag.EmbedBackend == "hashing"
    ? new HashingEmbeddingGenerator()
    : new OllamaApiClient(new Uri(rag.OllamaBaseUrl), rag.OllamaEmbedModel));

// Store seam.
if (rag.VectorStore == "memory")
    builder.Services.AddSingleton<IVectorIndex, InMemoryVectorIndex>();
else
    builder.Services.AddHttpClient<IVectorIndex, ChromaVectorIndex>(c => c.BaseAddress = new Uri(rag.ChromaUrl));

builder.Services.AddTransient<Ingestor>();
builder.Services.AddTransient<Retriever>();
builder.Services.AddTransient<RagAnswerer>();

var app = builder.Build();

app.MapGet("/health", () => new { Status = "ok" });

app.MapPost("/ingest", async (Ingestor ingestor, CancellationToken ct, string folder = ".") =>
    ingestor.TryResolve(folder, out string? dir)
        ? Results.Ok(new { ChunksIndexed = await ingestor.IngestFolderAsync(dir, ct) })
        // { "detail": ... }, the same body FastAPI's HTTPException returns.
        : Results.BadRequest(new { Detail = "folder must be an existing directory under the corpus root" }));

app.MapPost("/ask", async (AskRequest req, RagAnswerer answerer, CancellationToken ct) =>
    req.Errors() is { } errors
        ? Results.ValidationProblem(errors, statusCode: StatusCodes.Status422UnprocessableEntity)   // FastAPI's status
        : Results.Ok(await answerer.AnswerAsync(req.Question!, req.K, ct)));

app.Run();
```

`RagOptions` is read once, up front, because its values decide which services get registered. `WebApplicationFactory` applies a test's `UseSetting` values before this code runs, so the tests can pick the offline seams through configuration, the way the Python tests use env vars. `Results.ValidationProblem(..., 422)` returns a `ProblemDetails` body, not FastAPI's shape, but the status code matches. (.NET 10 also has built-in minimal-API validation, `AddValidation()` with data annotations. It answers 400, so it wouldn't match here.)

`WebApplicationFactory<Program>` needs `Program` to be public. With .NET 10, top-level-statement apps get that generated for you.

### Tests

Unit and API tests never call a model or Chroma. The API tests run the real app on the stub model, the hashing embedder and the in-memory index, chosen through configuration. That's the same seam switch the Python `conftest.py` makes with env vars, and the stub is module 04's `StubChatClient`, not a fake written here.

`dotnet test` runs from `bin/Debug/net10.0`, so a relative path doesn't reach the shared folder. `TestPaths` uses `FIXTURES_DIR` when it's set (the Docker test stage sets it) and otherwise walks up until it finds `fixtures/corpus`:

```csharp
// tests/RagService.Tests/TestPaths.cs
namespace RagService.Tests;

public static class TestPaths
{
    public static string Fixtures { get; } =
        Environment.GetEnvironmentVariable("FIXTURES_DIR") is { } dir ? Path.GetFullPath(dir) : FindUp();

    private static string FindUp()
    {
        for (DirectoryInfo? d = new(AppContext.BaseDirectory); d is not null; d = d.Parent)
        {
            string candidate = Path.Combine(d.FullName, "fixtures");
            if (Directory.Exists(Path.Combine(candidate, "corpus"))) return candidate;
        }
        throw new DirectoryNotFoundException($"no fixtures/corpus above {AppContext.BaseDirectory}");
    }
}
```

```csharp
// tests/RagService.Tests/ChunkerTests.cs
namespace RagService.Tests;

public class ChunkerTests
{
    private static string Words(int n, string prefix) =>
        string.Join(' ', Enumerable.Range(0, n).Select(i => $"{prefix}{i}"));

    [Test]
    public void Small_doc_is_one_chunk() =>
        Assert.That(Chunker.ChunkText("one two\n\nthree", "a.md").Select(c => c.Text), Is.EqualTo(new[] { "one two three" }));

    [Test]
    public void Packs_paragraphs_and_carries_overlap()
    {
        var chunks = Chunker.ChunkText($"{Words(100, "a")}\n\n{Words(100, "b")}", "a.md", maxWords: 180, overlap: 30);

        Assert.That(chunks, Has.Count.EqualTo(2));
        Assert.That(chunks[0].Text.Split(' '), Has.Length.EqualTo(100));
        Assert.That(chunks[1].Text.Split(' '), Has.Length.EqualTo(130));   // 30 carried + 100 new
        Assert.That(chunks[1].Text, Does.StartWith("a70 "));
    }

    [Test]
    public void Overlap_zero_carries_nothing()
    {
        var chunks = Chunker.ChunkText($"{Words(100, "a")}\n\n{Words(100, "b")}", "a.md", maxWords: 180, overlap: 0);

        Assert.That(chunks.Select(c => c.Text.Split(' ').Length), Is.EqualTo(new[] { 100, 100 }));
        Assert.That(chunks[1].Text, Does.StartWith("b0 "));
    }

    [TestCase("\n\n")]
    [TestCase("\r\n\r\n")]   // fails without the normalization: the two paragraphs merge into one
    public void Paragraph_breaks_work_with_any_line_ending(string sep) =>
        Assert.That(Chunker.ChunkText($"{Words(100, "a")}{sep}{Words(100, "b")}", "a.md"), Has.Count.EqualTo(2));

    [Test]
    public void Corpus_chunks_match_the_python_side()
    {
        // test_chunker.py pins the same ids and word counts: the cheapest exact cross-check there is.
        var chunks = Directory.GetFiles(Path.Combine(TestPaths.Fixtures, "corpus"), "*.md")
            .Order(StringComparer.Ordinal)
            .SelectMany(path => Chunker.ChunkText(File.ReadAllText(path), Path.GetFileName(path)));

        Assert.That(chunks.Select(c => (c.Id, c.Text.Split(' ').Length)), Is.EqualTo(new[]
        {
            ("billing.md#0", 105),
            ("oncall.md#0", 155),
            ("oncall.md#1", 74),
        }));
    }
}
```

```csharp
// tests/RagService.Tests/PromptTests.cs
namespace RagService.Tests;

public class PromptTests
{
    [Test]
    public void Prompt_matches_the_python_format()
    {
        Hit[] hits =
        [
            new("oncall.md#0", "To roll back, run deploy --revert.", "oncall.md", 0.9),
            new("oncall.md#1", "Rollbacks are safe within 24h.", "oncall.md", 0.8),
        ];
        // Byte for byte the string test_prompt.py expects.
        Assert.That(RagAnswerer.BuildPrompt("How do I roll back?", hits), Is.EqualTo(
            "Context:\n" +
            "[S1] (oncall.md) To roll back, run deploy --revert.\n" +
            "[S2] (oncall.md) Rollbacks are safe within 24h.\n" +
            "\nQuestion: How do I roll back?"));
    }
}
```

```csharp
// tests/RagService.Tests/RetrievalTests.cs
using Microsoft.Extensions.Logging.Abstractions;

namespace RagService.Tests;

public class RetrievalTests
{
    [Test]
    public void Fnv1a_matches_the_reference_values()
    {
        Assert.That(HashingEmbeddingGenerator.Fnv1a("a"), Is.EqualTo(0xE40C292Cu));
        Assert.That(HashingEmbeddingGenerator.Fnv1a("hello"), Is.EqualTo(0x4F9F2CABu));
    }

    [Test]
    public async Task In_memory_index_ranks_by_cosine_and_breaks_ties_by_id()
    {
        var index = new InMemoryVectorIndex();
        Chunk[] chunks = [new("b", "", "b.md"), new("a", "", "a.md"), new("c", "", "c.md")];
        await index.UpsertAsync(chunks, [new float[] { 1, 0 }, new float[] { 2, 0 }, new float[] { 0, 1 }]);   // a and b point the same way

        IReadOnlyList<Hit> hits = await index.QueryAsync(new float[] { 1, 0 }, k: 2);

        Assert.That(hits.Select(h => h.Id), Is.EqualTo(new[] { "a", "b" }));
    }

    [TestCase("How do I roll back a deploy?", new[] { "oncall.md#0", "oncall.md#1", "billing.md#0" })]
    [TestCase("How are customers billed for overages?", new[] { "billing.md#0", "oncall.md#1", "oncall.md#0" })]
    public async Task Hashing_retrieval_matches_the_python_side(string question, string[] expectedIds)
    {
        // test_retrieval.py pins the same ids: same corpus, chunker, hash and tie-break.
        using var embedder = new HashingEmbeddingGenerator();
        var index = new InMemoryVectorIndex();
        var options = new RagOptions { FixturesDir = TestPaths.Fixtures };
        await new Ingestor(embedder, index, options, NullLogger<Ingestor>.Instance).IngestFolderAsync(options.CorpusRoot);

        IReadOnlyList<Hit> hits = await new Retriever(embedder, index).RetrieveAsync(question, k: 3);

        Assert.That(hits.Select(h => h.Id), Is.EqualTo(expectedIds));
    }
}
```

```csharp
// tests/RagService.Tests/RecallAtKTests.cs
namespace RagService.Tests;

public class RecallAtKTests
{
    [Test]
    public async Task Counts_questions_whose_expected_source_is_in_the_top_k()
    {
        QaRow[] rows = [new("q1", "a.md"), new("q2", "b.md"), new("q3", "c.md")];
        var top = new Dictionary<string, string> { ["q1"] = "a.md", ["q2"] = "b.md", ["q3"] = "z.md" };

        Task<IReadOnlyList<Hit>> Retrieve(string q, int k, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<Hit>>([new Hit("id", "text", top[q], 1.0)]);

        Assert.That(await RecallAtK.ComputeAsync(rows, Retrieve, k: 4), Is.EqualTo(2.0 / 3).Within(1e-9));
    }
}
```

```csharp
// tests/RagService.Tests/ApiTests.cs
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;

namespace RagService.Tests;

public class ApiTests
{
    private WebApplicationFactory<Program> _factory = null!;

    /// <summary>The real app, with every seam on its offline backend, chosen by the same settings the Python
    /// tests set as env vars: stub model, hashing embeddings, in-memory index.</summary>
    private static WebApplicationFactory<Program> Offline(string vectorStore = "memory") =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(b => b
            .UseSetting("LLM_BACKEND", "stub")
            .UseSetting("EMBED_BACKEND", "hashing")
            .UseSetting("VECTOR_STORE", vectorStore)
            .UseSetting("FIXTURES_DIR", TestPaths.Fixtures));

    [SetUp]
    public void SetUp() => _factory = Offline();

    [TearDown]
    public void TearDown() => _factory.Dispose();

    [Test]
    public async Task Health_is_ok()
    {
        using HttpClient client = _factory.CreateClient();
        Assert.That(await client.GetStringAsync("/health"), Is.EqualTo("""{"status":"ok"}"""));
    }

    [Test]
    public async Task Ingest_then_ask_returns_a_cited_answer()
    {
        using HttpClient client = _factory.CreateClient();

        using HttpResponseMessage ingest = await client.PostAsync("/ingest", content: null);
        Assert.That(await ingest.Content.ReadAsStringAsync(), Is.EqualTo("""{"chunks_indexed":3}"""));

        using HttpResponseMessage ask = await client.PostAsJsonAsync("/ask", new { question = "How do I roll back a deploy?", k = 2 });

        Assert.That(ask.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        using JsonDocument body = JsonDocument.Parse(await ask.Content.ReadAsStringAsync());
        // The stub replies "stub: <last user message>", so the answer shows the prompt the model got.
        string answer = body.RootElement.GetProperty("answer").GetString()!;
        Assert.That(answer, Does.StartWith("stub: Context:\n[S1] (oncall.md) # On-call runbook"));
        Assert.That(answer, Does.EndWith("\nQuestion: How do I roll back a deploy?"));
        Assert.That(body.RootElement.GetProperty("citations").GetRawText(), Is.EqualTo(
            """[{"tag":"S1","source":"oncall.md","chunk_id":"oncall.md#0"},{"tag":"S2","source":"oncall.md","chunk_id":"oncall.md#1"}]"""));
    }

    [TestCase("{}")]
    [TestCase("""{"question":null}""")]
    [TestCase("""{"question":""}""")]
    [TestCase("""{"question":"q","k":0}""")]
    [TestCase("""{"question":"q","k":21}""")]
    public async Task Ask_rejects_a_bad_request_with_422(string json)
    {
        using HttpClient client = _factory.CreateClient();
        using var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
        using HttpResponseMessage res = await client.PostAsync("/ask", content);
        Assert.That(res.StatusCode, Is.EqualTo(HttpStatusCode.UnprocessableEntity));
    }

    [TestCase("..")]
    [TestCase("/etc")]
    public async Task Ingest_rejects_folders_outside_the_root(string folder)
    {
        using HttpClient client = _factory.CreateClient();
        using HttpResponseMessage res = await client.PostAsync($"/ingest?folder={Uri.EscapeDataString(folder)}", content: null);
        Assert.That(res.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public void Unknown_vector_store_fails_at_startup()
    {
        using WebApplicationFactory<Program> factory = Offline(vectorStore: "pinecone");
        var ex = Assert.Throws<InvalidOperationException>(() => factory.CreateClient());
        Assert.That(ex!.Message, Does.Contain("chroma | memory"));
    }
}
```

The retrieval eval is the one test that needs real embeddings, because recall with hashing embeddings measures the hash, not your pipeline. It's tagged `Eval` and skips itself unless `OLLAMA_BASE_URL` is set:

```csharp
// tests/RagService.Tests/RecallEvalTests.cs
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using OllamaSharp;

namespace RagService.Tests;

[Category("Eval")]
public class RecallEvalTests
{
    // Set from your measured baseline. The eval fails when a change makes retrieval worse.
    private const double MinRecallAt4 = 0.8;

    [Test]
    public async Task Recall_at_k_on_the_sample_corpus()
    {
        if (Environment.GetEnvironmentVariable("OLLAMA_BASE_URL") is not { } ollama)
        {
            Assert.Ignore("set OLLAMA_BASE_URL to run the retrieval eval against real embeddings");
            return;
        }

        var options = new RagOptions
        {
            FixturesDir = TestPaths.Fixtures,
            OllamaEmbedModel = Environment.GetEnvironmentVariable("OLLAMA_EMBED_MODEL") ?? "all-minilm",
        };
        using IEmbeddingGenerator<string, Embedding<float>> embedder = new OllamaApiClient(new Uri(ollama), options.OllamaEmbedModel);
        var index = new InMemoryVectorIndex();
        await new Ingestor(embedder, index, options, NullLogger<Ingestor>.Instance).IngestFolderAsync(options.CorpusRoot);

        var retriever = new Retriever(embedder, index);
        IReadOnlyList<QaRow> rows = RecallAtK.LoadJsonl(Path.Combine(TestPaths.Fixtures, "qa.jsonl"));
        foreach (int k in new[] { 1, 2, 4 })
            TestContext.Out.WriteLine($"recall@{k} = {await RecallAtK.ComputeAsync(rows, retriever.RetrieveAsync, k):F2}");

        Assert.That(await RecallAtK.ComputeAsync(rows, retriever.RetrieveAsync, 4), Is.GreaterThanOrEqualTo(MinRecallAt4));
    }
}
```

It uses the in-memory index rather than Chroma. Recall depends on the embeddings, the chunks and k. At this corpus size an exact scan and HNSW return the same top-k, so the eval doesn't need Chroma running.

Run locally:

```powershell
dotnet test                                      # offline; the Eval test skips itself
dotnet test --filter "FullyQualifiedName~ChunkerTests"

# The whole service, offline, on the C# port
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'
dotnet run --project src/RagService -- --urls http://localhost:8001
```

With Chroma and Ollama running (the C# compose file below, or the Python one), clear the offline settings and use the real seams:

```powershell
Remove-Item Env:LLM_BACKEND, Env:EMBED_BACKEND, Env:VECTOR_STORE -ErrorAction SilentlyContinue
$env:OLLAMA_BASE_URL = 'http://localhost:11434'
dotnet test --filter "TestCategory=Eval" --logger "console;verbosity=detailed"
dotnet run --project src/RagService -- --urls http://localhost:8001   # Chroma on localhost:8002
```

### Running the C# version in Docker

The `ProjectReference` to project 04 means the build context must contain both projects, so it's `projects/`. The restore layer copies 04's `Directory.Build.props` as well as its `.csproj`, because MSBuild applies the nearest `Directory.Build.props` above each project. The scaffold's `Dockerfile.dockerignore`, next to the Dockerfile, keeps every `bin/`, `obj/` and `.venv/` in the repo out of that wide context.

```dockerfile
# projects/07-rag-service/csharp/Dockerfile — build context: projects/
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer. 04's Directory.Build.props too: MSBuild applies the nearest one above each project.
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 07-rag-service/csharp/RagService.slnx 07-rag-service/csharp/Directory.Build.props 07-rag-service/csharp/
COPY 07-rag-service/csharp/src/RagService/RagService.csproj 07-rag-service/csharp/src/RagService/
COPY 07-rag-service/csharp/tests/RagService.Tests/RagService.Tests.csproj 07-rag-service/csharp/tests/RagService.Tests/
WORKDIR /src/07-rag-service/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 07-rag-service/csharp/ 07-rag-service/csharp/
WORKDIR /src/07-rag-service/csharp
RUN dotnet publish src/RagService -c Release -o /app --no-restore

FROM build AS test
COPY 07-rag-service/fixtures/ /src/07-rag-service/fixtures/
ENV FIXTURES_DIR=/src/07-rag-service/fixtures
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 07-rag-service/fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "RagService.dll"]
```

The compose file adds an `eval` service that runs the `Eval` tests against real embeddings, and a `test` service for the offline suite.

```yaml
# projects/07-rag-service/csharp/compose.yaml
name: rag-service-cs
services:
  chroma:
    image: chromadb/chroma:1.5.9   # same server version as the Python stack; ChromaVectorIndex speaks its v2 API
    ports: ["8002:8000"]
    volumes: ["chroma-data:/data"]

  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

  app:
    build: { context: ../.., dockerfile: 07-rag-service/csharp/Dockerfile, target: final }   # projects/: 04 must be inside
    ports: ["8001:8080"]   # listens on 8080 in the container, published on 8001
    env_file:
      - path: .env   # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-all-minilm}
      EMBED_BACKEND: ${EMBED_BACKEND:-ollama}
      VECTOR_STORE: ${VECTOR_STORE:-chroma}
      CHROMA_URL: http://chroma:8000
    extra_hosts: ["host.docker.internal:host-gateway"]
    depends_on: [chroma]

  test:
    build: { context: ../.., dockerfile: 07-rag-service/csharp/Dockerfile, target: test }
    profiles: [test]   # only runs when asked for by name

  eval:
    build: { context: ../.., dockerfile: 07-rag-service/csharp/Dockerfile, target: test }
    command: ["--filter", "TestCategory=Eval", "--logger", "console;verbosity=detailed"]
    environment:
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
      OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-all-minilm}
    extra_hosts: ["host.docker.internal:host-gateway"]
    profiles: [eval]

volumes:
  chroma-data:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

```powershell
cd projects/07-rag-service/csharp
docker compose --profile ollama up --build -d     # drop --profile ollama if Ollama runs natively
docker compose exec ollama ollama pull llama3.2
docker compose exec ollama ollama pull all-minilm
Invoke-RestMethod -Method Post http://localhost:8001/ingest
Invoke-RestMethod -Method Post http://localhost:8001/ask -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?","k":4}' | ConvertTo-Json -Depth 5
docker compose run --rm eval                     # recall@1/2/4 with real embeddings
docker compose run --rm test                     # unit + API tests, no network
# Without compose (from the repo root): docker build -f projects/07-rag-service/csharp/Dockerfile --target test -t rag-service-cs-test projects
```

With `--profile ollama`, both stacks publish Ollama on 11434, so run one stack's Ollama at a time (`docker compose down` in the other folder), or use native Ollama for both. The shared `ai-learn-ollama` volume means a model pulled in one is there in the other. The cross-checks below run the services locally, so they don't need either stack except for Chroma.

Break it on purpose here too. Ask something that isn't in the corpus. Then `POST /ingest?folder=..` and confirm you get a 400, not an index of your container's filesystem.

## Cross-check the two

Both sides read the same `fixtures/` files, so identical inputs are true by construction. Some stages are deterministic and some aren't. Check each one at the right strength.

**Exact, offline.** Run both services with the three offline seams, ingest, and ask the same question. The stub's answer contains the whole prompt, so equal responses mean the chunking, the hashing, the ranking, the prompt and the citations all agree. Start both from `projects/07-rag-service`, each in its own terminal:

```powershell
# Terminal 1
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'
cd python; uv run --no-sync uvicorn app.main:app --port 8000

# Terminal 2
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'memory'
cd csharp; dotnet run --project src/RagService -- --urls http://localhost:8001
```

Then, in a third:

```powershell
$body = '{"question":"How do I roll back a deploy?","k":2}'
$ask = foreach ($port in 8000, 8001) {
    Invoke-RestMethod -Method Post "http://localhost:$port/ingest" | Out-Null
    Invoke-RestMethod -Method Post "http://localhost:$port/ask" -ContentType 'application/json' -Body $body |
        ConvertTo-Json -Depth 5
}
$ask[0] -ceq $ask[1]    # True: same answer, same citations, same chunk ids
```

It compares parsed JSON, not raw bytes, because the serializers escape differently: System.Text.Json writes `<sha>` as `<sha>`, FastAPI doesn't. The same exact checks also run on every build, without servers: both test suites pin the corpus chunk ids and word counts, the hashing retrieval ids for two questions, and the golden prompt. When one side's test fails and the other's passes, you've found the drift. The usual culprits:

- **Line endings.** Both chunkers turn `\r\n` and `\r` into `\n` first. Without that, a CRLF file has no `\n\n`, and its paragraphs merge into one.
- **`overlap=0`.** In Python, `xs[-0:]` is the *whole* list, so without the guard every word carries forward. `TakeLast(0)` returns nothing. The `overlap=0` test is the one that catches a version without the guard.
- **Path separators and order.** Both sides build sources with forward slashes and sort files by that relative path, so ids and ingest order match on Windows and Linux.
- **Hashing.** Any per-process hash (`hash()`, `GetHashCode()`) breaks determinism even within one language. FNV-1a's published values are pinned in both suites.

**What differs, on purpose.** Validation status codes match (422 for a missing, null or empty `question` or an out-of-range `k`), but the bodies don't: FastAPI's `{"detail": [...]}` vs ASP.NET Core's `ProblemDetails`. A body that's missing entirely or isn't valid JSON is a 422 from FastAPI and a 400 from ASP.NET Core, which rejects it while binding, before the handler runs. Callers should branch on the status, not the body. Each stack has its own Chroma (8003 for Python, 8002 for C#) and its own collection (`docs`, `docs-cs`).

**Approximate, on real models.** Both sides use all-MiniLM-L6-v2, but through different runtimes (`sentence-transformers` on PyTorch vs Ollama's build of the model, which may be stored at lower precision; check the model tag). Expect the same top sources for most questions, similarity scores within a couple of hundredths, and the same `recall@k` on this tiny set (Python measured 1.00 at k=1). A large gap means the models aren't actually the same. Compare dimensions first: 384 for MiniLM. Answers don't compare as strings at all: different runs, and sampling. Compare what's checkable, the citations, and whether an out-of-corpus question gets the exact "I don't know" sentence on both sides.

**The shared-Chroma experiment.** Point the C# service at the *Python* stack's Chroma and collection, and query vectors that Python wrote. With the Python stack up and ingested (Chroma on localhost:8003, collection `docs`, Ollama on 11434), from `projects/07-rag-service/csharp`:

```powershell
$env:CHROMA_URL = 'http://localhost:8003'; $env:CHROMA_COLLECTION = 'docs'
dotnet run --project src/RagService -- --urls http://localhost:8081
# In another terminal:
Invoke-RestMethod -Method Post http://localhost:8081/ask -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?"}' | ConvertTo-Json -Depth 5
```

It works, roughly, because both sides embed with the same model. Now stop it, set `$env:EMBED_BACKEND = 'hashing'`, start it again and ask again. You get a 500, and the log shows Chroma's reason: `Collection expecting embedding with dimension of 384, got 256`. That's the *lucky* version of the embedding-model trap, because it fails loudly. Two different models with the same dimension would return confident nonsense with no error at all. Now you've seen why "same model at ingest and query" is a rule. (Don't `/ingest` from C# into Python's collection: the ids match, so C#'s vectors would silently overwrite Python's.)

| Concern | Python | C# / .NET |
|---|---|---|
| HTTP API | FastAPI (`@app.post`) | ASP.NET Core minimal API (`app.MapPost`) |
| Settings | `pydantic-settings` | `RagOptions` with `[ConfigurationKeyName]`, same env-var names |
| JSON field names | snake_case by default | camelCase by default → `SnakeCaseLower` configured |
| Request validation | `Field(min_length=1)`, `ge`/`le`: 422 | `AskRequest.Errors()` + `Results.ValidationProblem(..., 422)` |
| Chat model | module 04's `client_from_env()` | module 04's `AddLlmClient` → `IChatClient` |
| Embeddings | `Embedder` protocol: `sentence-transformers` in-process, or hashing | `IEmbeddingGenerator<string, Embedding<float>>`: Ollama `all-minilm`, or hashing |
| Vector store client | `chromadb-client` | typed `HttpClient` over Chroma REST (or an MEVD connector) |
| Store seam | `VectorIndex` protocol | `IVectorIndex` |
| Seam selection | `*_from_env()` functions | `Program.cs` registrations |
| Chunk ids | `source#index` (re-ingest overwrites) | `source#index`, same ids as Python |
| Datasets | `FIXTURES_DIR` (`../fixtures`) | `FIXTURES_DIR` (`../../../fixtures` under `dotnet run`) |
| Vector math | `numpy` | `System.Numerics.Tensors` (`TensorPrimitives`) |
| Retrieval eval | `eval/recall_at_k.py` script | `RecallAtK` + NUnit `[Category("Eval")]` |
| API tests | FastAPI `TestClient` + env vars | `WebApplicationFactory<Program>` + `UseSetting` |

## Moving to AWS

The pipeline maps cleanly onto managed pieces — same shapes, someone else's operational burden:

- **Source docs → S3.** Your corpus lives in a bucket; ingest reads from it. This is the durable system of record.
- **Vector store.** Three common paths: **Bedrock Knowledge Bases** (managed RAG — point it at an S3 bucket, it chunks, embeds, and indexes for you, and exposes a retrieve API; least code, least control), **OpenSearch Service** (vector + keyword, so hybrid search in one place), or **`pgvector` on RDS Postgres** (vectors beside relational data — nice when you already run Postgres). Swapping Chroma for any of these means one new `VectorIndex` implementation; the rest of the service doesn't move.
- **Embeddings & generation → Bedrock.** Call a hosted embedding model and a hosted LLM instead of local `sentence-transformers`. Watch that the embedding model is identical between ingest and query.
- **Ingest as a job.** Run it as a scheduled ECS task or Lambda triggered by S3 uploads, so new documents re-index automatically.

Where each version changes:

- **Python:** the seams are the `VectorIndex` and `Embedder` protocols and module 04's client. The store gets a new class in `app/store.py` (OpenSearch or `pgvector`) and a new `VECTOR_STORE` value. The embedder gets a Bedrock class in `app/embeddings.py` (a `boto3` `bedrock-runtime` call) and a new `EMBED_BACKEND` value. Generation needs nothing here: module 12 adds `LLM_BACKEND=bedrock` to module 04's library, and this service picks it up.
- **Module 12's version** is smaller still ([ADR-003](adr/003-module-12-deploys-real-rag.md)): it keeps `InMemoryIndex`, computes the corpus embeddings when the image is built, and loads them at startup with `upsert`, so only the query is embedded at runtime. Index and query must use the same embedding model, so if the query side moves to Bedrock Titan, the baked index does too.
- **C#:** the seams are the three interfaces registered in `Program.cs`. `IVectorIndex` gets a new implementation: a `pgvector` or OpenSearch one, written by hand like `ChromaVectorIndex` or on a `Microsoft.Extensions.VectorData` connector, where the Postgres one is more mature than Chroma's. `IChatClient` switches when module 12 adds `bedrock` to `AddLlmClient`. `IEmbeddingGenerator` gets a Bedrock-backed implementation behind a new `EMBED_BACKEND` value (`AWSSDK.Extensions.Bedrock.MEAI` adapts the `AWSSDK.BedrockRuntime` client to both interfaces; check its docs for the current method names). For Bedrock Knowledge Bases, the retrieve call lives in the `AWSSDK.BedrockAgentRuntime` package, and it replaces `Retriever` and `IVectorIndex` together. `Chunker`, `RagAnswerer`, the endpoints and the unit tests don't change. `RecallAtK` only needs a retrieve function, so you can point it at the new stack and compare recall before and after the move.

Don't reach for the managed option until the do-it-yourself version has taught you where the knobs are. A managed Knowledge Base that returns bad answers is a black box you can't debug if you've never built the pipeline by hand. As always: the specific API shapes and console flows change — check current AWS docs when you wire it up; the architecture above won't.

## How experts think / common pitfalls

- **RAG quality is retrieval quality.** If the right chunk isn't in the context, no prompt can save you. Debug retrieval *first* — dump the top-k and look at it before you touch the generation prompt.
- **Chunking is the highest-leverage knob, and it's a tuning problem, not a setting.** Experts run a retrieval eval across chunk sizes rather than picking one and moving on.
- **Always instruct "say I don't know."** The most dangerous RAG bug is a confident answer with no supporting document. Make abstention a first-class behavior and test for it.
- **Hybrid + rerank is the standard production recipe.** Pure vector search alone underperforms on exact terms; the pros almost always add keyword and a reranker.
- **Citations aren't a nice-to-have; they're a debugging tool and often the spec.** They let you (and the user) verify the answer against the source instantly.
- **Watch the embedding-model trap.** Embedding queries and documents with different models, or silently changing the embedding model without re-indexing, produces confidently wrong results with no error.
- **Cost and latency are real.** Reranking 50 candidates and sending 8 chunks per query adds up. Measure tokens and milliseconds from day one (03/04 habits carry forward).
- **A second implementation is a test oracle.** Two easy chunker bugs slip past single-language tests and fail a cross-check at once: a naive version with `uuid4` ids would make every re-ingest duplicate everything, and one without the `overlap` guard would carry the whole buffer when `overlap=0`. When a pipeline stage is deterministic, a second implementation that must agree with the first is a cheap, strong test.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Watch for:** tests with hard-coded retrieval results (`special-casing`), and a `recall@k` eval that's gameable because its questions were written by copying phrases out of the chunks.
- **C#-specific watch:** vector-store code is where .NET agents hallucinate most. Chroma "clients" with invented method names, Semantic Kernel's old `IMemoryStore` / `ISemanticTextMemory` APIs mixed with the newer `Microsoft.Extensions.VectorData` attributes (whose names changed before GA), Chroma v1 REST paths used against a v2 server, and `IEmbeddingGenerator` calls from preview releases (`GenerateEmbeddingVectorAsync` vs `GenerateVectorAsync`). Check every one against the package docs and the server's `/docs` page. The code in this doc included. Two quieter ones: configuration read through a `Section__Key` name (`Rag__ChromaBaseUrl`) when the Python side reads `CHROMA_URL`, which silently runs on the default, and a hashing or test embedder built on `string.GetHashCode()`, which changes every process.
- **Comparison of the week:** have two agents (or one agent twice) implement the chunker, then write an [A-vs-B comparison](R-reviewing-ai-written-code.md#review-templates) with concrete inputs that separate them (headings, code blocks, very long paragraphs).

## Checkpoint

You're ready for 08 if you can, without looking back:

- Explain when RAG beats fine-tuning and when it beats stuffing everything in the prompt.
- Draw the ingest and query pipelines and name every stage.
- Explain, in one paragraph, what an embedding is and why cosine similarity is the right comparison.
- Say why chunk size and overlap matter, and how you'd *decide* on them (hint: not by feel).
- Name four RAG failure modes and how you'd tell them apart.
- Explain top-k, metadata filtering, hybrid search, and reranking, and why hybrid+rerank is the usual production setup.
- Compute `recall@k` for a small labeled set (`python -m eval.recall_at_k`) and use it to compare two chunking configs, and the hashing embedder against a real one.
- Run the `07-rag-service` project in Docker, get a cited answer, and make it correctly say "I don't know."
- Run both services offline (`stub`, `hashing`, `memory`) and show their `/ask` responses match exactly.
- Run both versions over the same corpus and say which stages must match exactly (chunk boundaries, ids, the prompt), which only approximately (scores, top-k on real embeddings), and why.
- State the service contract (`/health`, `/ingest`, `/ask` with `question` and `k`, citations back) that modules 08, 09, 11 and 12 call through `RAG_URL`.
- Explain what happened in the shared-Chroma experiment when the C# side switched embedding models, and why the same mistake with matching dimensions would be worse.

If "is my RAG better now?" is still a feeling rather than a number, that's exactly the gap module 09 closes — don't paper over it.

## Going deeper

- The original RAG paper (Lewis et al.) for where the term comes from and the retrieve-then-generate framing.
- "Lost in the Middle" (Liu et al.) — the empirical basis for context ordering.
- Reciprocal rank fusion for combining keyword and vector rankings in hybrid search.
- Chroma, FAISS, `pgvector`, and OpenSearch docs — read at least two to see how the same "index + query" contract is exposed differently.
- Cross-encoder rerankers (the `sentence-transformers` cross-encoder docs) for how joint scoring differs from bi-encoder retrieval.
- "Microsoft.Extensions.VectorData" and its connector list: the .NET vector-store abstraction, and which stores have mature connectors right now.
- "Chroma HTTP API v2" (or your server's `/docs` page): the REST surface the C# client talks to.
- "ASP.NET Core integration tests WebApplicationFactory" and "Microsoft.Extensions.AI IEmbeddingGenerator": testing minimal APIs with swapped services, and the embedding abstraction.

*Last verified: 2026-10-05. Built: Python (pytest 22 passed, pyright clean) and C# (dotnet test 22 passed, 1 Eval test skipped without Ollama) in a throwaway build against module 04's built library. Run: both services on `stub`/`hashing`/`memory` with the exact `/ask` cross-check (identical); both `VECTOR_STORE=chroma` paths against a local `chromadb` 1.5.9 server, including the 384-vs-256 dimension error; the Python eval with real all-MiniLM-L6-v2 embeddings (recall@1/2/4 = 1.00; hashing recall@1 = 0.80). Read-only: Docker images (compose files validated with `docker compose config`), Ollama embeddings and generation in both languages, and the C# Eval test.*

**Verify on first build:**

- That the `chromadb/chroma:1.5.9` image serves the same v2 paths as the `chroma run` server this was checked against (`http://localhost:8003/docs`), and keeps its data under `/data`.
- That Ollama's `all-minilm` returns 384-dimension vectors, and the C# `Eval` test reaches the recall the Python script reports.
- The Python image size and first-request time with CPU PyTorch; module 12 depends on both.

Next: [08 — Agents & orchestration](08-agents-and-orchestration.md), where this RAG service becomes one tool an agent can call.
