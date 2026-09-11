# 03 — LLM fundamentals for engineers

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. You already own software engineering, so this doc doesn't re-teach it. It teaches just enough about how LLMs actually work — tokens, context windows, sampling, embeddings — to make real design, cost, and debugging decisions. Math stays light and just-in-time: one paragraph of transformer intuition, no attention derivations, no proofs. The bar is "enough to reason at the console and the whiteboard," not "enough to write a paper." Everything concrete here (model names, prices) ages; the mental models don't, and the doc flags which is which.

You don't need to understand internal-combustion thermodynamics to be a great driver, but you do need to know what the fuel gauge, the tachometer, and the temperature light mean. This module is the dashboard. After it, tokens, context, sampling, and embeddings stop being magic words and become quantities you budget, tune, and debug.

## Where this fits

**Prerequisites:** module 01 (Python toolchain, Docker), module 02 (the stack and the "one probabilistic component" model, plus a working Bedrock call).

**After this module you can:**

- Estimate the token count, cost, and rough latency of a request *before* you send it.
- Choose sampling parameters (temperature, top_p, max tokens) deliberately and predict their effect on determinism.
- Explain the system/user/assistant role structure and why it matters.
- Reason about embeddings and cosine similarity well enough to understand why RAG (module 07) works.
- Pick a model from the quality/cost/latency triangle with a rationale.
- Treat hallucination as a designed-around property, not a bug you'll patch.

## What an LLM is, at an engineer's altitude

Here's the whole thing in one paragraph, and it's genuinely enough to build on:

> An LLM is a function that takes a sequence of tokens and predicts the probability of every possible *next* token. That's it. To generate text, you call it, sample one token from that probability distribution, append it to the input, and call it again — a loop, one token at a time, until it emits a "stop" token or hits a limit. The "transformer" is the architecture that computes those next-token probabilities; its key trick, **attention**, lets each position look at every other position in the input to decide what's relevant. You don't need the attention math to build with it — just hold onto: *it's a next-token predictor run in a loop, and it can attend to everything in its context when predicting.*

Consequences that matter to you as an engineer:

- **Generation is sequential and autoregressive.** Output tokens are produced one at a time, each depending on all the ones before. This is why longer outputs are slower and why streaming (module 04) exists — you can show tokens as they're produced.
- **The model has no memory between calls.** Each request is stateless; the "conversation" is just the full history re-sent every time (see roles, below). This is exactly like a stateless HTTP handler where the client resends context — a model you already have.
- **It predicts *plausible*, not *true*.** The training objective is "what token likely comes next," never "what is correct." Truth is correlated with plausibility because true text is common in training data, but they're not the same thing. This is the root of hallucination, covered at the end.

That's the deepest we go into internals here. Phase 5 (modules 14–15) opens the box if you want it; you can build excellent systems without ever doing so.

## Tokens: the unit of everything

A **token** is a chunk of text — roughly a word-piece. Models don't see characters or words; they see token IDs. "tokenization" is the (deterministic, model-specific) step that splits text into these chunks and maps them to integers.

Rough intuition for English: **~4 characters per token, ~0.75 words per token** — so 1,000 tokens ≈ 750 words ≈ a page and a half. But it varies: common words are often one token, rare words and code split into several, and whitespace and punctuation count. Non-English text and code are usually less efficient (more tokens per character).

Why an engineer cares about tokens specifically:

- **Cost is per token.** Providers bill input tokens and output tokens separately, usually at different rates (output is typically pricier). Your bill is `input_tokens × in_price + output_tokens × out_price`, summed over every call.
- **Latency scales with tokens.** More input tokens = more to process; more output tokens = more sequential generation steps. Output length dominates latency because of the one-at-a-time loop.
- **The context window is measured in tokens** (next section). Everything you send *and* the response must fit.

So token count is simultaneously your cost meter, your latency predictor, and your capacity limit. Counting them is a core reflex — the build project does exactly this.

### Counting tokens in practice

You count tokens with the *specific model's* tokenizer, because different model families tokenize differently. OpenAI models use **tiktoken**; other families ship their own. The build project shows the pattern:

```python
import tiktoken

# The encoding is model-specific; using the wrong one gives wrong counts.
enc = tiktoken.get_encoding("cl100k_base")   # example encoding
tokens = enc.encode("Hello, AI engineering!")
print(len(tokens))   # the count you budget against
```

The mental model: **tokenization is deterministic and knowable ahead of time.** You can count before you send, which means you can predict cost and reject over-budget requests *before* spending money — do this at the boundary, like validating a request size.

## The context window as a budget

The **context window** is the maximum number of tokens a model can consider at once — input plus output, together. Call it the model's working-memory limit. Windows have grown enormously (thousands → hundreds of thousands → millions of tokens depending on the model), and that number is a headline spec that ages fast; the *concept* is what's durable.

Treat the window as a **budget you allocate**, not free space to fill:

```
[ system prompt ] + [ retrieved context / history ] + [ user input ] + [ room for the output ]  ≤  context window
```

Engineering implications:

- **Room for the answer must be reserved.** If you fill the window with input, there's no space left to generate output — or the model truncates. `max_tokens` (below) caps output; leave headroom.
- **Bigger context ≠ better answers.** Stuffing more in costs more, is slower, and can *degrade* quality — models attend less reliably to the middle of very long inputs (the "lost in the middle" effect). This is a direct argument for retrieval (module 07): fetch the *relevant* few thousand tokens instead of dumping everything.
- **History grows unbounded if you let it.** In a chat, re-sending the whole transcript every turn (remember: stateless) means token cost grows every turn. Real systems summarize or trim old turns. Think of it as cache eviction for conversation.

The reflex: for any feature, do the token arithmetic. "System prompt 400, retrieved docs ~3,000, user question ~100, expected answer ~500 → ~4,000 tokens/call → at $X/1K tokens → $Y per call → at Z calls/day → daily spend." That back-of-envelope is a load-bearing skill, and it's just arithmetic.

## Sampling: temperature, top_p, max tokens, and determinism

Remember the model outputs a *probability distribution* over next tokens. **Sampling** is how you pick one. The knobs:

- **`temperature`** (typically 0–2, or 0–1 depending on provider) — scales how sharply the model favors high-probability tokens. `temperature=0` ≈ "always take the most likely token" (greedy, as deterministic as the model gets). Higher values flatten the distribution, making rarer tokens more likely — more variety, more "creativity," more risk of nonsense. Low temp for extraction/classification/code; higher temp for brainstorming/creative copy.
- **`top_p`** (nucleus sampling, 0–1) — restricts sampling to the smallest set of tokens whose probabilities sum to `p`. `top_p=0.1` means "only consider the top 10% probability mass." An alternative lever to temperature for controlling diversity. **Don't crank both hard at once**; pick one to tune and leave the other at its default. Common practice: tune temperature, leave top_p at 1.0.
- **`max_tokens`** — hard cap on *output* length. Protects your cost and latency budget and prevents runaway generation. Set it deliberately from your token arithmetic; too low truncates the answer mid-sentence.

**On determinism** — the point that reshapes your testing:

- Even at `temperature=0`, output is **not guaranteed identical** across calls. Greedy decoding is *more* reproducible, but floating-point non-associativity across hardware, batching, and provider-side changes mean you can still see variation. Some providers offer a `seed` parameter that improves but doesn't fully guarantee reproducibility.
- So: **you cannot write `assert response == expected`.** This is the concrete, code-level version of module 02's "one probabilistic component." Testing becomes *evaluation* — scoring outputs against criteria over a set — which is module 09, the core skill. Use `temperature=0` for anything you want to test or that should be consistent (classification, extraction, structured output), precisely to minimize (not eliminate) variance.

Mental model: temperature is a **determinism/creativity dial**, not a quality dial. Turning it up doesn't make the model smarter; it makes it less predictable. Default to low, raise it only when you specifically want variety.

## Roles: system, user, assistant

Chat models take a structured list of messages, each with a **role**:

- **`system`** — instructions and persona that frame the whole interaction ("You are a support-ticket summarizer. Never invent facts."). Set once, applies throughout. Think of it as configuration/policy for the model's behavior — the closest thing to "app settings" for a call.
- **`user`** — input from the human/caller.
- **`assistant`** — the model's own prior responses, included so it "remembers" the conversation.

A multi-turn chat is just this list, resent in full each call (statelessness again):

```python
messages = [
    {"role": "system", "content": "You summarize support tickets in 2 sentences."},
    {"role": "user", "content": "Ticket #1: customer can't log in after reset..."},
    {"role": "assistant", "content": "Customer reports login failure following a password reset..."},
    {"role": "user", "content": "Now list the action items."},
]
```

Why it matters to you:

- **The system prompt is your primary control surface** for behavior and guardrails, and it's trusted differently from user content — a distinction that becomes a *security* issue with prompt injection (module 13), where malicious `user` content tries to override `system` instructions.
- **Never concatenate untrusted input into the system prompt.** Keep user data in `user` messages. This is the LLM version of parameterized queries vs string-concatenated SQL — same instinct, same reason.

## Embeddings and cosine similarity

A separate but essential capability: an **embedding model** turns a piece of text into a fixed-length vector of floats (e.g. 384, 768, 1536 numbers) that captures its *meaning*. Texts with similar meaning land near each other in this high-dimensional space; unrelated texts land far apart.

You measure "nearness" with **cosine similarity** — the cosine of the angle between two vectors, ranging from -1 (opposite) through 0 (unrelated) to 1 (identical direction). The intuition, no proof needed: it asks "do these two vectors point the same way?", ignoring their length. Close to 1 = semantically similar.

```python
import numpy as np

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    # dot product of the two vectors, normalized by their magnitudes.
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))
```

Why this is a fundamental, not a footnote:

- It's how you do **semantic search**: embed a query, embed your documents, return the documents whose vectors are closest to the query's. Keyword search finds "car"; embedding search also finds "automobile" and "vehicle," because they're near each other in vector space.
- This is the engine of **RAG** (module 07): embed your knowledge base, store the vectors in a vector database, and at query time retrieve the nearest chunks to stuff into the context window. Everything you learned about the context-window budget connects here — embeddings are how you decide *which* few thousand tokens are worth spending.
- Embeddings also power clustering, deduplication, and classification. A lot of "AI" that isn't a chatbot is really embeddings plus classical ML (module 14).

Mental model: **an embedding is meaning-as-coordinates; cosine similarity is a meaning-distance.** That's the whole idea, and it's enough to build RAG.

## Model families, sizes, and the quality/cost/latency triangle

Models come in families (from various providers) and, within a family, sizes — often labeled small/medium/large or by parameter count. The durable relationship, which no specific model name will change:

```
            quality
              /\
             /  \
            /    \      pick two-ish; you trade against the third
           /      \
      cost --------  latency
```

- **Bigger models** → generally higher quality, higher cost per token, higher latency.
- **Smaller models** → cheaper, faster, "good enough" for many narrow tasks (classification, extraction, routing), lower ceiling on hard reasoning.

The senior instinct: **don't default to the biggest model.** Match model to task. A small, cheap, fast model for classifying or routing; a large model reserved for the genuinely hard reasoning step. A common production pattern is a **cascade** — a cheap model handles the easy majority and escalates only the hard cases to an expensive one, cutting cost dramatically. You can't make that call without the token arithmetic and the triangle in hand — which is why this module comes before you build anything real.

All the numbers here (which model is best, exact prices, exact latencies) change constantly. The triangle, the cascade pattern, and "match model to task" do not. When a new model drops, you slot it onto the triangle and re-run your evals (module 09); you don't relearn anything.

## Hallucination: a property, not a bug

A **hallucination** is when the model produces fluent, confident text that is factually wrong or unsupported. Reframe it correctly: this is not a defect that a future patch removes. It's a *direct consequence* of what the model is — a plausibility maximizer, not a truth oracle (from the opening paragraph). It will always be able to generate confident-sounding falsehood.

So you engineer around it, exactly as you engineer around any unreliable dependency:

- **Ground it.** Give the model the facts in-context (RAG, module 07) so it's summarizing provided text rather than recalling from parameters. Grounded answers hallucinate far less.
- **Constrain it.** Structured outputs (module 06) and validation reduce the surface for invention.
- **Verify it.** Check outputs against sources; use evals (module 09) to measure hallucination rate as a number and catch regressions.
- **Design the UX for it.** Show sources, express uncertainty, keep a human in the loop for high-stakes decisions. Never wire an unverified model output directly to an irreversible action.

Mental model: **treat every model output as an unverified claim from a fluent, confident, occasionally-wrong intern.** You'd trust that intern for a first draft, not for a wire transfer. That instinct is correct and it scales.

## The build project

**`projects/03-token-lab/`** — a small Python tool that makes these fundamentals tangible. It:

1. Tokenizes text and counts tokens.
2. Estimates cost for a given model's per-token price.
3. Computes cosine similarity between two strings' embeddings.

Embeddings can come from a hosted API *or* a local `sentence-transformers` model. The project shows the local path (no API key, fully offline in Docker) and notes where the hosted call would go — API specifics change, the pattern doesn't.

### Layout

```
projects/03-token-lab/
├── pyproject.toml
├── Dockerfile
├── README.md
├── src/
│   └── token_lab/
│       ├── __init__.py
│       ├── tokens.py
│       ├── cost.py
│       ├── embeddings.py
│       └── cli.py
└── tests/
    └── test_cost.py
```

Dependencies: `uv add tiktoken sentence-transformers numpy` (and `uv add --dev pytest`).

### `src/token_lab/tokens.py`

```python
"""Token counting. Deterministic and knowable before you ever call a model."""
from __future__ import annotations

import tiktoken


def count_tokens(text: str, encoding: str = "cl100k_base") -> int:
    # Encoding is model-family-specific; the wrong one gives wrong counts.
    enc = tiktoken.get_encoding(encoding)
    return len(enc.encode(text))
```

### `src/token_lab/cost.py`

```python
"""Cost estimation. Prices change constantly — pass them in, never hardcode."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ModelPrice:
    """Price in dollars per 1,000 tokens. Look up current values per model."""
    input_per_1k: float
    output_per_1k: float


def estimate_cost(input_tokens: int, output_tokens: int, price: ModelPrice) -> float:
    return (
        input_tokens / 1000 * price.input_per_1k
        + output_tokens / 1000 * price.output_per_1k
    )
```

### `src/token_lab/embeddings.py`

```python
"""Embeddings + cosine similarity. Local model shown; hosted API is the same shape."""
from __future__ import annotations

import numpy as np
from sentence_transformers import SentenceTransformer

# Small, fast, runs on CPU. Loaded once (module load is like a static ctor).
_MODEL = SentenceTransformer("all-MiniLM-L6-v2")


def embed(text: str) -> np.ndarray:
    # A hosted embeddings API (e.g. Bedrock, provider APIs) returns a vector
    # in exactly this shape — swap this line for the API call, keep the rest.
    return _MODEL.encode(text, convert_to_numpy=True)


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0.0:
        return 0.0
    return float(np.dot(a, b) / denom)


def similarity(text_a: str, text_b: str) -> float:
    return cosine_similarity(embed(text_a), embed(text_b))
```

### `src/token_lab/cli.py`

```python
from __future__ import annotations

import argparse

from token_lab.cost import ModelPrice, estimate_cost
from token_lab.embeddings import similarity
from token_lab.tokens import count_tokens


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Token / cost / similarity lab.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_tok = sub.add_parser("count", help="Count tokens in text.")
    p_tok.add_argument("text")

    p_cost = sub.add_parser("cost", help="Estimate cost for token counts.")
    p_cost.add_argument("--in-tokens", type=int, required=True)
    p_cost.add_argument("--out-tokens", type=int, required=True)
    p_cost.add_argument("--in-price", type=float, required=True, help="$ / 1K input tokens")
    p_cost.add_argument("--out-price", type=float, required=True, help="$ / 1K output tokens")

    p_sim = sub.add_parser("sim", help="Cosine similarity of two strings.")
    p_sim.add_argument("a")
    p_sim.add_argument("b")

    args = parser.parse_args(argv)

    if args.cmd == "count":
        print(f"{count_tokens(args.text)} tokens")
    elif args.cmd == "cost":
        price = ModelPrice(args.in_price, args.out_price)
        total = estimate_cost(args.in_tokens, args.out_tokens, price)
        print(f"${total:.6f}")
    elif args.cmd == "sim":
        print(f"cosine similarity: {similarity(args.a, args.b):.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

### `tests/test_cost.py`

Cost math is pure and deterministic, so it's a normal unit test — a good reminder that most of an AI system is testable exactly like any other code; only the model call itself needs evals.

```python
from token_lab.cost import ModelPrice, estimate_cost


def test_estimate_cost_sums_input_and_output() -> None:
    price = ModelPrice(input_per_1k=0.50, output_per_1k=1.50)
    # 2,000 input @ $0.50/1k = $1.00 ; 1,000 output @ $1.50/1k = $1.50
    assert estimate_cost(2000, 1000, price) == 2.50


def test_estimate_cost_zero() -> None:
    assert estimate_cost(0, 0, ModelPrice(1.0, 2.0)) == 0.0
```

### Running locally in Docker

```dockerfile
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project
COPY src/ ./src/
COPY tests/ ./tests/
RUN uv sync --frozen
# Warm the sentence-transformers model into the image so first run is offline & fast.
RUN uv run python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"
ENTRYPOINT ["uv", "run", "python", "-m", "token_lab.cli"]
```

```bash
docker build -t token-lab projects/03-token-lab

docker run --rm token-lab count "How many tokens is this sentence?"
docker run --rm token-lab cost --in-tokens 4000 --out-tokens 500 --in-price 0.003 --out-price 0.015
docker run --rm token-lab sim "a cat sat on the mat" "the feline rested on the rug"
docker run --rm --entrypoint uv token-lab run pytest
```

The `sim` command is the one to play with: compare paraphrases (should score high), unrelated sentences (near zero), and contradictions (often *also* high — similarity is about topic/meaning-space, not truth, a subtlety worth feeling directly before you build RAG).

### Moving to AWS

This tool runs fully locally. The one line that would change in production is the embedding call: **AWS Bedrock offers hosted embeddings models** (e.g. the Amazon Titan Embeddings family and others in the catalog — check current Bedrock docs for model IDs and vector dimensions). You'd invoke Bedrock the way module 02's hello-model script did, get back a vector, and feed it into the *same* `cosine_similarity` function — the `embed()` function is the only seam that moves. Hosted embeddings trade the local model's zero-cost/offline nature for higher quality and no local compute; which you want depends on volume and data-sensitivity, the same hosted-vs-open call from module 02. Module 07 wires Bedrock embeddings into a real vector store.

## How experts think / pitfalls

- **Do the token arithmetic before you build.** Cost and latency surprises almost always trace back to nobody counting tokens up front. It's arithmetic; there's no excuse to skip it.
- **`temperature=0` for anything you test or need consistent.** And still don't assume bit-identical output — greedy reduces variance, it doesn't guarantee reproducibility. Design tests as evals, not equality assertions.
- **Longer context is not free and not always better.** More tokens = more cost, more latency, and possible "lost in the middle" quality loss. Retrieval beats stuffing. Reserve output headroom explicitly.
- **Keep untrusted input out of the system prompt.** Roles are a trust boundary; treat them like one. This prevents a class of prompt-injection bugs before you even reach module 13.
- **Similarity measures topic, not truth.** Two contradictory sentences about the same subject can have high cosine similarity. Don't confuse "semantically close" with "says the same thing" — it matters when you evaluate retrieval.
- **Match the model to the task; consider a cascade.** Reflexively reaching for the biggest model is the expensive-and-slow default. Small models plus escalation is often the right production shape.
- **Hallucination is permanent; plan for it.** Ground, constrain, verify, and design the UX around unverified claims. Never let raw output drive an irreversible action.
- **Pin model versions where you can; let evals catch drift.** A hosted model can change under a stable name. Your eval set is the regression suite that turns silent quality loss into a failing check.

## Checkpoint

You're ready for module 04 when you can:

- Estimate the token count of a paragraph within roughly ±25% in your head, and turn that into a per-call cost given a price sheet.
- Explain why output length dominates latency (the autoregressive loop).
- Lay out a context-window budget for a feature (system + context + input + output headroom) and say what happens when it overflows.
- Predict the effect of raising temperature, and state whether it makes the model "better."
- Explain why `temperature=0` still doesn't guarantee identical outputs, and what that means for testing.
- Describe the system/user/assistant roles and why untrusted input stays out of the system prompt.
- Explain, without math, what an embedding is and what cosine similarity measures — and why that sets up RAG.
- Place a new model on the quality/cost/latency triangle and describe a cascade.
- Define hallucination as a property and list the four ways you engineer around it.

## Going deeper

Topics and search terms (verify specifics against current docs — this is the fastest-moving layer):

- "tiktoken" and "how tokenization works / byte-pair encoding" — the mechanics of splitting text into tokens.
- "attention is all you need" — the original transformer paper; skim the abstract and figures for intuition, don't get lost in the math on a first pass.
- "temperature vs top_p sampling" — good practical write-ups on when to tune which.
- "lost in the middle: how language models use long contexts" — the long-context degradation effect, with data.
- "sentence-transformers documentation" and "cosine similarity intuition" — embeddings in practice.
- "AWS Bedrock Titan Embeddings" — current hosted embedding model IDs and dimensions.
- "why do LLMs hallucinate" — several solid explainers frame it as an objective-function property, which is the correct mental model.

Next: [04 — Calling models: APIs & SDKs](04-calling-models-apis-sdks.md).
