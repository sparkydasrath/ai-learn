# 07 — Retrieval-augmented generation (RAG)

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. This series assumes you're excellent at software engineering and won't re-teach it; it teaches the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default, and improving your Python is part of the point.

By now you can call a model, get structured output, and let it call your tools (04–06). But the model only knows what it was trained on — frozen at some cutoff, with no access to your wiki, your tickets, or last Tuesday's incident. RAG fixes that by fetching relevant text at query time and putting it in the prompt. This module builds a real, **measurable** RAG pipeline.

## Where this fits

You've finished Phase 2:

- **04** — you can call hosted and local models with retries, timeouts, and cost accounting.
- **05** — you treat prompts as versioned, tested artifacts.
- **06** — you can get reliable JSON out and let the model call your code.

RAG is the first "system" module: you're no longer sending one prompt, you're building a pipeline with an offline part (ingest and index) and an online part (retrieve and generate). Everything here feeds forward: **08** wraps a RAG service as a tool an agent can call, and **09** is where you learn to actually measure whether your retrieval and answers are any good. You will hit the ceiling of "tune by feel" fast in this module — that's the setup for 09.

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

(`a @ b` is the dot product — NumPy's `@` operator. A Pythonism worth knowing: operator overloading like this is idiomatic in the numeric stack, unlike in most C# you write.)

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

**`projects/07-rag-service/`** — ingest a folder of markdown, chunk, embed, store in Chroma, and answer questions **with citations** over a FastAPI endpoint. Includes a tiny `recall@k` retrieval eval. Runs locally in Docker via `docker-compose` (app + Chroma).

### Layout

```
projects/07-rag-service/
├── app/
│   ├── __init__.py
│   ├── config.py           # settings from env
│   ├── ingest.py           # load → chunk → embed → store
│   ├── retriever.py        # embed query → search → (optional) rerank
│   ├── rag.py              # assemble context → generate → cite
│   └── main.py             # FastAPI: /ingest, /ask, /health
├── data/                   # sample markdown corpus
│   ├── oncall.md
│   └── billing.md
├── eval/
│   ├── qa.jsonl            # question → expected source id
│   └── recall_at_k.py      # computes recall@k
├── tests/
│   └── test_retriever.py
├── .env.example
├── pyproject.toml
├── Dockerfile
└── docker-compose.yml
```

### The chunker

Structure-aware-ish: split on blank lines into paragraphs, then pack paragraphs up to a token budget with overlap. Kept deliberately simple and readable.

```python
# app/ingest.py
from __future__ import annotations

import glob
import os
import uuid
from dataclasses import dataclass

import chromadb
from sentence_transformers import SentenceTransformer

from app.config import settings

_model: SentenceTransformer | None = None


def embedder() -> SentenceTransformer:
    """Lazily load the embedding model once (it's a few hundred MB)."""
    global _model
    if _model is None:
        _model = SentenceTransformer(settings.embed_model)
    return _model


@dataclass
class Chunk:
    id: str
    text: str
    source: str


def chunk_text(text: str, source: str, max_words: int = 180, overlap: int = 30) -> list[Chunk]:
    """Pack paragraphs into ~max_words chunks with word overlap.

    Word counts stand in for tokens here to keep the dependency surface small;
    for production, count real tokens with the model's tokenizer.
    """
    paras = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks: list[Chunk] = []
    buf: list[str] = []
    count = 0
    for para in paras:
        words = para.split()
        if count + len(words) > max_words and buf:
            body = " ".join(buf)
            chunks.append(Chunk(id=str(uuid.uuid4()), text=body, source=source))
            # carry the tail forward as overlap
            tail = body.split()[-overlap:]
            buf = tail.copy()
            count = len(tail)
        buf.extend(words)
        count += len(words)
    if buf:
        chunks.append(Chunk(id=str(uuid.uuid4()), text=" ".join(buf), source=source))
    return chunks


def get_collection() -> chromadb.api.models.Collection.Collection:
    client = chromadb.HttpClient(host=settings.chroma_host, port=settings.chroma_port)
    return client.get_or_create_collection("docs", metadata={"hnsw:space": "cosine"})


def ingest_folder(folder: str) -> int:
    """Load every .md under folder, chunk, embed, and upsert into Chroma."""
    collection = get_collection()
    model = embedder()
    total = 0
    for path in glob.glob(os.path.join(folder, "**", "*.md"), recursive=True):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        source = os.path.relpath(path, folder)
        chunks = chunk_text(text, source=source)
        if not chunks:
            continue
        embeddings = model.encode([c.text for c in chunks]).tolist()
        collection.upsert(
            ids=[c.id for c in chunks],
            documents=[c.text for c in chunks],
            embeddings=embeddings,
            metadatas=[{"source": c.source} for c in chunks],
        )
        total += len(chunks)
    return total
```

### The retriever

```python
# app/retriever.py
from __future__ import annotations

from dataclasses import dataclass

from app.ingest import embedder, get_collection


@dataclass
class Hit:
    text: str
    source: str
    score: float


def retrieve(query: str, k: int = 4) -> list[Hit]:
    """Embed the query with the SAME model used at ingest, then top-k search."""
    collection = get_collection()
    query_vec = embedder().encode([query]).tolist()
    res = collection.query(query_embeddings=query_vec, n_results=k)
    hits: list[Hit] = []
    for doc, meta, dist in zip(
        res["documents"][0], res["metadatas"][0], res["distances"][0]
    ):
        # Chroma returns cosine *distance*; similarity = 1 - distance.
        hits.append(Hit(text=doc, source=str(meta["source"]), score=1.0 - dist))
    return hits
```

A production `retrieve` would add metadata filters (`collection.query(where={"source": ...})`), a hybrid keyword pass, and a rerank step. We're leaving those as marked extension points so the core loop stays legible — add them once the eval tells you retrieval is the bottleneck.

### Assemble and generate

```python
# app/rag.py
from __future__ import annotations

from app.retriever import Hit, retrieve

SYSTEM = (
    "Answer the question using ONLY the context below. "
    "Cite the source tag (e.g. [S1]) after each claim it supports. "
    "If the context does not contain the answer, reply exactly: "
    '"I don\'t know based on the provided documents."'
)


def build_prompt(question: str, hits: list[Hit]) -> str:
    lines = ["Context:"]
    for i, h in enumerate(hits, start=1):
        lines.append(f"[S{i}] ({h.source}) {h.text}")
    lines.append(f"\nQuestion: {question}")
    return "\n".join(lines)


def answer(question: str, k: int = 4) -> dict:
    hits = retrieve(question, k=k)
    prompt = build_prompt(question, hits)
    reply = call_model(SYSTEM, prompt)  # your module-04 client
    citations = [{"tag": f"S{i}", "source": h.source} for i, h in enumerate(hits, 1)]
    return {"answer": reply, "citations": citations}


def call_model(system: str, user: str) -> str:
    """Wrap your module-04 client here. Placeholder so the file is self-contained."""
    raise NotImplementedError("Plug in your provider client from module 04.")
```

### FastAPI surface

```python
# app/main.py
from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel

from app.ingest import ingest_folder
from app.rag import answer

app = FastAPI(title="rag-service")


class AskRequest(BaseModel):
    question: str
    k: int = 4


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/ingest")
def ingest(folder: str = "data") -> dict:
    return {"chunks_indexed": ingest_folder(folder)}


@app.post("/ask")
def ask(req: AskRequest) -> dict:
    return answer(req.question, k=req.k)
```

### The tiny retrieval eval

This is the seed of module 09. A few `question → expected source` pairs, and `recall@k`: of the questions, what fraction had the correct source somewhere in the top-k?

```python
# eval/recall_at_k.py
from __future__ import annotations

import json
import sys

from app.retriever import retrieve


def recall_at_k(path: str, k: int = 4) -> float:
    hits_correct = 0
    total = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            total += 1
            sources = {h.source for h in retrieve(row["question"], k=k)}
            if row["expected_source"] in sources:
                hits_correct += 1
    return hits_correct / total if total else 0.0


if __name__ == "__main__":
    k = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    score = recall_at_k("eval/qa.jsonl", k=k)
    print(f"recall@{k} = {score:.2f}")
```

```jsonl
{"question": "How do I roll back a deploy?", "expected_source": "oncall.md"}
{"question": "When is a rollback still safe?", "expected_source": "oncall.md"}
{"question": "How are customers billed for overages?", "expected_source": "billing.md"}
```

Now "did my chunking change help?" is a number, not an argument. Change `max_words`, re-ingest, re-run — did `recall@4` go up? That reflex is the entire point of the exercise.

### Run locally in Docker

`docker-compose.yml` runs Chroma as its own service and the app next to it — mirroring the prod split of "app talks to a managed vector store over the network."

```dockerfile
# Dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
COPY pyproject.toml .
RUN pip install --no-cache-dir \
    fastapi uvicorn chromadb sentence-transformers numpy pydantic-settings
COPY app ./app
COPY data ./data
COPY eval ./eval
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

```yaml
# docker-compose.yml
services:
  chroma:
    image: chromadb/chroma:latest
    ports:
      - "8001:8000"
    volumes:
      - chroma-data:/data

  app:
    build: .
    ports:
      - "8000:8000"
    environment:
      CHROMA_HOST: chroma
      CHROMA_PORT: "8000"
      EMBED_MODEL: sentence-transformers/all-MiniLM-L6-v2
      MODEL_API_KEY: ${MODEL_API_KEY}
    depends_on:
      - chroma

volumes:
  chroma-data:
```

```python
# app/config.py
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    chroma_host: str = "localhost"
    chroma_port: int = 8000
    embed_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    model_api_key: str = ""


settings = Settings()
```

Bring it up, index the corpus, ask a question, then measure:

```bash
docker compose up --build -d
curl -X POST "http://localhost:8000/ingest?folder=data"
curl -X POST http://localhost:8000/ask \
  -H 'content-type: application/json' \
  -d '{"question":"How do I roll back a deploy?","k":4}'
docker compose exec app python eval/recall_at_k.py 4
```

Then **break it on purpose** (module 00's advice): ask something not in the corpus and confirm you get "I don't know," not a fabrication. Set `k=1` and watch recall drop. This is the muscle you're building.

### Moving to AWS

The pipeline maps cleanly onto managed pieces — same shapes, someone else's operational burden:

- **Source docs → S3.** Your corpus lives in a bucket; ingest reads from it. This is the durable system of record.
- **Vector store.** Three common paths: **Bedrock Knowledge Bases** (managed RAG — point it at an S3 bucket, it chunks, embeds, and indexes for you, and exposes a retrieve API; least code, least control), **OpenSearch Service** (vector + keyword, so hybrid search in one place), or **`pgvector` on RDS Postgres** (vectors beside relational data — nice when you already run Postgres). Swapping Chroma for any of these means changing only `app/ingest.py` and `app/retriever.py`; the rest of the service doesn't move.
- **Embeddings & generation → Bedrock.** Call a hosted embedding model and a hosted LLM instead of local `sentence-transformers`. Watch that the embedding model is identical between ingest and query.
- **Ingest as a job.** Run it as a scheduled ECS task or Lambda triggered by S3 uploads, so new documents re-index automatically.

Don't reach for the managed option until the do-it-yourself version has taught you where the knobs are. A managed Knowledge Base that returns bad answers is a black box you can't debug if you've never built the pipeline by hand. As always: the specific API shapes and console flows change — check current AWS docs when you wire it up; the architecture above won't.

## How experts think / common pitfalls

- **RAG quality is retrieval quality.** If the right chunk isn't in the context, no prompt can save you. Debug retrieval *first* — dump the top-k and look at it before you touch the generation prompt.
- **Chunking is the highest-leverage knob, and it's a tuning problem, not a setting.** Experts run a retrieval eval across chunk sizes rather than picking one and moving on.
- **Always instruct "say I don't know."** The most dangerous RAG bug is a confident answer with no supporting document. Make abstention a first-class behavior and test for it.
- **Hybrid + rerank is the standard production recipe.** Pure vector search alone underperforms on exact terms; the pros almost always add keyword and a reranker.
- **Citations aren't a nice-to-have; they're a debugging tool and often the spec.** They let you (and the user) verify the answer against the source instantly.
- **Watch the embedding-model trap.** Embedding queries and documents with different models, or silently changing the embedding model without re-indexing, produces confidently wrong results with no error.
- **Cost and latency are real.** Reranking 50 candidates and sending 8 chunks per query adds up. Measure tokens and milliseconds from day one (03/04 habits carry forward).

## Checkpoint

You're ready for 08 if you can, without looking back:

- Explain when RAG beats fine-tuning and when it beats stuffing everything in the prompt.
- Draw the ingest and query pipelines and name every stage.
- Explain, in one paragraph, what an embedding is and why cosine similarity is the right comparison.
- Say why chunk size and overlap matter, and how you'd *decide* on them (hint: not by feel).
- Name four RAG failure modes and how you'd tell them apart.
- Explain top-k, metadata filtering, hybrid search, and reranking, and why hybrid+rerank is the usual production setup.
- Compute `recall@k` for a small labeled set and use it to compare two chunking configs.
- Run the `07-rag-service` project in Docker, get a cited answer, and make it correctly say "I don't know."

If "is my RAG better now?" is still a feeling rather than a number, that's exactly the gap module 09 closes — don't paper over it.

## Going deeper

- The original RAG paper (Lewis et al.) for where the term comes from and the retrieve-then-generate framing.
- "Lost in the Middle" (Liu et al.) — the empirical basis for context ordering.
- Reciprocal rank fusion for combining keyword and vector rankings in hybrid search.
- Chroma, FAISS, `pgvector`, and OpenSearch docs — read at least two to see how the same "index + query" contract is exposed differently.
- Cross-encoder rerankers (the `sentence-transformers` cross-encoder docs) for how joint scoring differs from bi-encoder retrieval.

Next: [08 — Agents & orchestration](08-agents-and-orchestration.md), where this RAG service becomes one tool an agent can call.
