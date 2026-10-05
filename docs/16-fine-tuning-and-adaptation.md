# 16 — Fine-tuning & adaptation

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer, without a deep math background. Fine-tuning has a reputation as the scary, expensive, research-y end of the field. It isn't — not anymore, and not for what you'll actually do. This module gives you the *decision framework* (when to fine-tune vs the four cheaper things you already know) and one end-to-end **LoRA fine-tune** you can run and evaluate yourself. The heavy math from module 15 stays where it was: autograd still does the calculus, the training loop is still the training loop. What's new is *what you train on* and the discipline that fine-tuning without evaluation is malpractice. You do not need to understand the math of low-rank matrix decomposition to run a great LoRA fine-tune — you need to know what it buys you and how to prove it worked.

The most important thing in this entire module is a single confusion to unlearn: **fine-tuning is not how you teach a model new facts.** It changes *behavior, format, style, and tone* — not primarily *knowledge*. Getting this wrong wastes weeks and money. RAG (module 07) is for knowledge; fine-tuning is for behavior. Keep saying it until it's reflex.

## Where this fits

**Prerequisites:** modules 01–15. You need prompting (05), structured outputs (06), RAG (07), and — non-negotiably — the evaluation harness from module 09, because this module *uses* it to prove a fine-tune helped. You need module 15's training-loop intuition to understand what LoRA is actually doing, and module 10's local serving to serve the result.

**After this module you can:**

- Run the decision framework — prompting vs RAG vs fine-tuning vs classical ML — and pick correctly.
- Explain full fine-tuning vs parameter-efficient (LoRA/QLoRA) in one breath, and why LoRA is cheap.
- Format a dataset for instruction/chat fine-tuning and split it for honest evaluation.
- Run a LoRA fine-tune of a small open model end to end.
- **Evaluate** the tuned model against the base model with the module-09 harness — proving improvement *and* checking for regressions.
- Serve a fine-tuned/adapter model, and know when fine-tuning is *not* worth it.
- Do the .NET half of the workflow: consume the tuned model from C# through `IChatClient`, and reproduce the Python scorecard exactly from the same saved model outputs.

## The decision framework — read this before you fine-tune anything

When a model isn't doing what you want, you have four levers, cheapest and fastest first. **Exhaust the top before reaching for the bottom.** Fine-tuning is powerful and it's also the most expensive, slowest-to-iterate, and easiest-to-get-wrong option — treat it as a considered choice, not a first move.

1. **Prompting (module 05)** — change the instructions. Free, instant to iterate, no infrastructure. *Always try this first.* A shocking amount of "we need to fine-tune" turns out to be "we needed a better prompt and two examples."
2. **RAG (module 07)** — the model lacks *knowledge* (your docs, current data, private facts). Retrieve the right context and put it in the prompt. **This is the answer whenever the gap is information the model doesn't have.**
3. **Fine-tuning (this module)** — the model needs to *behave differently*: a consistent output format, a specific tone/style, a domain's phrasing, shorter latency by baking in behavior you'd otherwise prompt for at length. You have examples of the desired input→output behavior and prompting can't reliably get you there.
4. **Classical ML (module 14)** — it's really a structured prediction/classification task in disguise. Don't use any LLM.

The decisive question: **"Is the gap knowledge, or behavior?"**

- Knowledge ("it doesn't know our product catalog / this happened last week / our internal policy") → **RAG.** Fine-tuning facts in is unreliable, hard to update, and prone to hallucination; you'd have to retrain to change one fact. RAG updates by editing a document.
- Behavior ("it won't consistently output our JSON shape / match our brand voice / stay terse / follow our house format") → **fine-tuning** is a legitimate tool, *after* you've confirmed prompting alone can't do it.

Write this confusion on a sticky note: **RAG for what it knows, fine-tuning for how it acts.** The number-one fine-tuning failure in industry is teams trying to fine-tune knowledge into a model when they wanted RAG.

## Full fine-tuning vs parameter-efficient (LoRA/QLoRA)

**Full fine-tuning** updates *every* weight in the model using the exact training loop from module 15, just continuing to train a pretrained model on your data. For a modern model that's billions of weights — enormous GPU memory, long training, and a full copy of all weights per fine-tune to store and serve. Rarely the right choice for an application engineer.

**LoRA (Low-Rank Adaptation)** is the trick that made fine-tuning accessible. Intuition, no math: instead of updating the giant weight matrices, you **freeze them** and train a **tiny pair of small "adapter" matrices** alongside each one; at inference their effect is added to the frozen weights. You're training maybe 0.1–1% as many parameters. The heavy math you're allowed to skip: the weight update is approximated by a *low-rank* matrix product — the one-sentence version is "a big change can often be captured by two small matrices multiplied together." Name it, don't derive it.

Why LoRA is the default for people like us:

- **Cheap** — trains on a single modest GPU (sometimes free-tier cloud GPUs), in minutes-to-hours, not a cluster.
- **Small artifacts** — the adapter is a few megabytes, not a multi-gigabyte model copy. You can keep *many* adapters for one base model and swap them.
- **Swappable/composable** — load the base once, attach whichever adapter you need. Great for serving several fine-tuned behaviors cheaply.

**QLoRA** = LoRA on top of a **quantized** (compressed to 4-bit) base model (quantization is from module 10). It shrinks the memory needed for the frozen base so you can fine-tune larger models on smaller/cheaper GPUs. Same LoRA idea, less memory. The .NET analogy for the whole thing: rather than recompiling and redeploying an entire framework to change one behavior, you ship a small **plugin/adapter** that layers on top of the untouched base — smaller, faster, reversible, and you can have several.

## Data: quality over quantity, and formatting

Your dataset is the fine-tune. Two rules dominate:

- **Quality beats quantity, by a lot.** A few hundred *clean, consistent, correct* examples usually beat tens of thousands of noisy ones. The model learns the pattern in your examples faithfully — including their mistakes and inconsistencies. Curate ruthlessly. This is unintuitive coming from "big data" instincts: for behavior fine-tuning, small and pristine wins.
- **Format matters and must match how you'll serve.** Fine-tuning data is a list of examples in a **chat/instruction format** — the same message structure (system/user/assistant) you send at inference. If you'll serve with a system prompt, train with one. A mismatch between training and serving format quietly wrecks results.

A typical instruction/chat example is one JSON object per line (JSONL), e.g. conceptually:

```json
{"messages": [
  {"role": "system", "content": "You extract the order into strict JSON."},
  {"role": "user", "content": "I want 3 red mugs and a blue kettle"},
  {"role": "assistant", "content": "{\"items\":[{\"qty\":3,\"item\":\"red mug\"},{\"qty\":1,\"item\":\"blue kettle\"}]}"}
]}
```

(Exact field names vary by trainer/library — check current docs; the *shape* is the durable part.) And — because module 09 lives in your bones now — you **split off a validation/held-out set before training** so you can prove the fine-tune generalizes instead of memorizing.

## The fine-tune workflow

The end-to-end shape, which the project below follows:

1. **Pick a base model** — a small open model you can run locally (this module) or a hosted base a provider lets you fine-tune.
2. **Build the dataset** — curated, consistent, correctly formatted, split into train/validation.
3. **Train the adapter** — run LoRA. It's the module-15 loop with the base frozen and only the adapter's parameters updating.
4. **Evaluate against the module-09 harness** — the whole point. Run your eval set through *base* and *tuned* and compare numbers.
5. **Serve** — attach the adapter to the base and expose it (module 10 patterns).

In a .NET shop, steps 1–3 run in Python, because that's where the training stack is (PyTorch, `transformers`, PEFT, TRL). .NET has TorchSharp for tensors and autograd, but nothing like PEFT or TRL on top of it. Steps 4–5 are where .NET earns its place: once the tuned model is exported, it's just another model behind `IChatClient`, and the eval harness is ordinary test code. The build project splits the work exactly that way.

## Evaluation is mandatory — and checks two things

This is the module-09 skill applied with teeth. A fine-tune is a *change to your system's behavior*, and you would never ship a behavior change without a test. Two questions, both required:

- **Did it improve on the target task?** Run your held-out eval set through base and tuned; the tuned model must win on the metric you care about (format-compliance rate, style-match score, an LLM-as-judge rubric from 09). If it doesn't beat base, you don't ship it — and you learned it cheaply.
- **Did it regress anything else?** Fine-tuning can cause **catastrophic forgetting** — the model gets better at your task but *worse* at general capability (it forgets how to do things outside your narrow dataset). Keep a small "general capability" eval alongside your task eval and check the tuned model didn't fall off a cliff there. This is the fine-tuning equivalent of running the *full* regression suite after a targeted change, not just the new test.

"It looks better in the three prompts I tried" is not evaluation. A scorecard comparing base vs tuned on a held-out set is. If you take one habit from this module, take this one.

## Serving a fine-tuned / adapter model

Two shapes:

- **Adapter-based (LoRA):** ship the small adapter and load it on top of the base at serve time. Many inference stacks support attaching LoRA adapters, and some can hot-swap between several adapters over one loaded base — cheap multi-behavior serving. Locally, tools in the module-10 family (e.g. Ollama with a merged model, or a server that loads base + adapter) serve it.
- **Merged:** fold the adapter's effect into the base weights to produce a single standalone model, then serve it like any other model (module 10). Simpler to deploy, but you lose the swappability and it's a full-size artifact again.

Either way, it's just a model behind the same serving patterns you built in module 10 — no new infrastructure category.

From .NET, a served fine-tune is just a different model name. Through `Microsoft.Extensions.AI` and OllamaSharp, base vs tuned is two clients that differ by one string. (The build project gets them from module 04's `AddLlmClient`, in `Backends.cs`, but underneath it's this.)

```csharp
using Microsoft.Extensions.AI;
using OllamaSharp;

var ollama = new Uri("http://localhost:11434");
IChatClient baseModel  = new OllamaApiClient(ollama, "ft-base");
IChatClient tunedModel = new OllamaApiClient(ollama, "ft-tuned");   // same calling code, different weights
```

If you'd rather run the model in-process than behind a server, `Microsoft.ML.OnnxRuntimeGenAI` (ONNX export) and LLamaSharp (GGUF) both load a merged model inside a .NET process. Their APIs change often, so check current docs before you commit to either.

## Costs & when it's NOT worth it

Be a skeptic. Fine-tuning is *not worth it* when:

- **You haven't exhausted prompting and RAG.** Most gaps close there, faster and cheaper. Fine-tuning to fix a knowledge gap is the classic waste.
- **Your data is thin or messy.** Garbage examples produce a garbage-faithful model. No dataset, no fine-tune.
- **The task changes often.** Every meaningful change means re-training and re-evaluating. Prompts and RAG update instantly; fine-tunes don't.
- **You can't evaluate it.** No eval set means no way to know it helped or regressed. Build the eval first, or don't fine-tune.
- **The gains don't clear the operational cost.** You now own a training pipeline, an artifact to version, and a serving path. That overhead has to be earned by a real, measured improvement.

It *is* worth it when you have a stable, well-defined behavior gap (format/style/tone/domain phrasing/latency), a clean dataset, an eval that proves it, and prompting genuinely can't get you there. Then LoRA is cheap enough to just try — and the eval tells you whether to keep it.

## The build project

**`projects/16-fine-tuning/`** is a small **LoRA fine-tune** of a small open model on a **formatting task**: make the model reliably emit a strict JSON shape for a free-text order. That's behavior, which is exactly what fine-tuning is *for*. You then **score tuned against base** on a held-out set, module-09 style (JSON-valid rate and schema-compliance rate), and serve both through Ollama.

The two languages split by job, not by duplication:

- **Python** builds the dataset, trains the LoRA adapter, and exports base and tuned for Ollama. It also has the scorecard CLI: `score`, `compare` and `record`, calling the models through [module 04's client](04-calling-models-apis-sdks.md).
- **C#** doesn't train. It **consumes** the exported models through module 04's `LlmClient` (`IChatClient`), scores them with a port of the same harness, and **gates** the result with an exit code CI can act on. Same commands, same output, same held-out file.

Either side can `record` a model's outputs to `fixtures/generations/` and `compare` saved outputs with `replay:`. Scored on the same saved outputs, the two harnesses must agree exactly. Scored live, they should agree approximately.

**Backends:** this module supports `LLM_BACKEND=stub` and `ollama`. The tuned model only exists in your local Ollama, so `hosted` fails loudly with the list of supported values. Everything except training and the live scorecard runs on `stub`, with no GPU and no model.

### What training costs

LoRA is most comfortable on an NVIDIA GPU. These are rough numbers for this project's defaults (Qwen2.5-0.5B-Instruct, rank 8, 200 examples, 3 epochs, about 150 steps). Treat them as order-of-magnitude, not a benchmark:

| Where | Memory | Time |
|---|---|---|
| Recent NVIDIA GPU, 6 GB+ VRAM (bf16) | about 3–5 GB VRAM | a few minutes |
| Free Colab T4 (16 GB, fp32, no bf16) | about 5–8 GB VRAM | 5–15 minutes |
| CPU only | 8 GB+ RAM | 30–90 minutes |

A 1.5B base roughly triples the memory. Past about 3B on a consumer card, reach for QLoRA. The **scorecard runs fine on CPU** against any served model, so even without a GPU you can do the most important part, which is measuring.

### Layout

The shared `fixtures/` folder is committed (the repo `.gitignore` re-includes `fixtures/`), and keeping one copy means the two languages can't drift.

```
projects/16-fine-tuning/
├── fixtures/                  # COMMITTED, one copy, read by both languages (FIXTURES_DIR)
│   ├── eval.jsonl             # HELD-OUT orders, never trained on; written by make_data
│   ├── general.jsonl          # exercise: the general-capability probe
│   └── generations/           # written by `record`; not "outputs/", which the repo ignores
│       ├── base.jsonl         # saved model outputs, one line per eval row
│       └── tuned.jsonl
├── python/
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── Dockerfile
│   ├── Dockerfile.dockerignore
│   ├── compose.yaml
│   ├── .env.example
│   ├── README.md
│   ├── data/                  # gitignored; make_data regenerates train.jsonl
│   ├── adapter/               # gitignored; the LoRA output
│   ├── models/                # gitignored; merged HF folders and GGUF exports
│   ├── ollama/
│   │   ├── Modelfile.base
│   │   └── Modelfile.tuned
│   ├── src/ft/
│   │   ├── __init__.py
│   │   ├── make_data.py       # the small, clean dataset, split with no overlap
│   │   ├── finetune.py        # LoRA training (the train extra; GPU-friendly)
│   │   ├── export.py          # merge the adapter, export base + tuned
│   │   ├── evaluate.py        # the scorecard and ship gate (CPU)
│   │   ├── generators.py      # model via module 04, replay, record
│   │   └── cli.py             # score / compare / record
│   └── tests/
│       ├── test_make_data.py
│       ├── test_evaluate.py
│       └── test_cli.py
└── csharp/
    ├── FineTuning.slnx
    ├── Directory.Build.props
    ├── Dockerfile
    ├── Dockerfile.dockerignore
    ├── compose.yaml
    ├── .env.example           # same content as python/.env.example
    ├── .vscode/settings.json
    ├── README.md
    ├── src/FineTuning/
    │   ├── FineTuning.csproj
    │   ├── EvalSet.cs         # load the held-out set, drop the gold turn
    │   ├── OrderSchema.cs     # JSON-valid and schema-ok checks
    │   ├── Backends.cs        # module 04's IChatClient for a named model
    │   ├── Generators.cs      # IChatClient, replay-from-file, record-to-file
    │   ├── Scorer.cs          # the scorecard + ship gate
    │   └── Program.cs         # score / compare / record CLI
    └── tests/FineTuning.Tests/
        ├── FineTuning.Tests.csproj
        ├── OrderSchemaTests.cs
        └── ScorerTests.cs
```

The training set isn't committed: `make_data.py` is seeded, so it regenerates `data/train.jsonl` byte for byte.

Both languages find the fixtures the same way. A `FIXTURES_DIR` environment variable wins, and the default is `../fixtures`, relative to the `python/` or `csharp/` folder you run from. Both Dockerfiles set it.

Both projects reuse module 04, so both Docker builds use `projects/` as the context, with a `Dockerfile.dockerignore` next to each Dockerfile ([conventions](conventions.md#docker)). Start from the scaffold's ignore file and add the training artifacts, which can run to gigabytes:

```text
# projects/16-fine-tuning/python/Dockerfile.dockerignore (the C# one is identical)
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
**/data/
**/adapter/
**/models/
**/*.gguf
**/*.safetensors
```

The C# `Dockerfile.dockerignore` is the same file.

## Python implementation

Work in `projects/16-fine-tuning/python/`. It's a [library](conventions.md#python-project-shapes). The script names the package `fine_tuning`, and this doc uses the shorter `ft`. From the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 16-fine-tuning
cd projects/16-fine-tuning/python
Rename-Item src/fine_tuning ft
Clear-Content src/ft/__init__.py      # drop the scaffold's hello-world main()
Remove-Item tests/test_smoke.py
```

Then replace `pyproject.toml` with the one below, which also drops the scaffold's `[project.scripts]` table, and run `uv sync`.

### `pyproject.toml`

```toml
# projects/16-fine-tuning/python/pyproject.toml
[project]
name = "ft"
version = "0.1.0"
description = "LoRA fine-tune for a JSON-formatting task, and the base-vs-tuned scorecard"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "llm-client",        # module 04's client: the stub and Ollama backends
    "pydantic>=2.7",
]

# Training deps are heavy and platform-specific (GPU builds). They're an extra, so the
# data, scoring and Docker paths install light and never pull torch.
[project.optional-dependencies]
train = [
    "torch>=2.8",        # direct, so the index pin below applies (conventions#pytorch-wheels)
    "transformers>=4.56",
    "peft>=0.17",        # the LoRA library
    "trl>=0.12",         # SFTTrainer; processing_class needs 0.12+
    "datasets>=3.0",
    "accelerate>=1.0",
]

[build-system]
requires = ["uv_build>=0.10.9,<0.11.0"]
build-backend = "uv_build"

[dependency-groups]
dev = [
    "pytest>=9.1.1",
]

[tool.uv.sources]
llm-client = { path = "../../04-llm-client/python", editable = true }
# Windows gets CUDA wheels (your NVIDIA GPU); Linux, WSL2, macOS and Docker get CPU wheels.
torch = [
    { index = "pytorch-cu130", marker = "sys_platform == 'win32'" },
    { index = "pytorch-cpu", marker = "sys_platform != 'win32'" },
]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[[tool.uv.index]]
name = "pytorch-cu130"
url = "https://download.pytorch.org/whl/cu130"
explicit = true
```

Three things in there are worth a closer look:

- **`llm-client` is a path dependency** on module 04, as in every module since. It's what `uv add --editable ../../04-llm-client/python` writes.
- **The train extra keeps torch out of everything else.** `uv sync` installs the light path: data, scoring, tests. `uv run --extra train ...` adds the training stack. The Docker image never installs it.
- **The torch source is per platform** ([conventions](conventions.md#pytorch-wheels)). On Windows it comes from PyTorch's CUDA 13.0 index, so an NVIDIA GPU just works. Everywhere else (Linux, WSL2, macOS) it comes from the CPU index. `uv lock` resolves both, and `uv.lock` records both. This doc resolved torch 2.14.1, transformers 5.18, peft 0.21 and trl 1.14.

Pick the variant that matches your machine:

- **Windows with an NVIDIA GPU:** keep it as shown. `cu130` needs a recent driver (the R580 series or later). On an older driver, use the `cu128` or `cu126` URL that PyTorch's install page lists for it. Check with `uv run --extra train python -c "import torch; print(torch.__version__, torch.cuda.is_available())"`, which should print `2.14.1+cu130 True`.
- **Windows without an NVIDIA GPU:** point the `win32` entry at `pytorch-cpu`. The CUDA wheels would work on CPU, but they're about 3 GB of nothing.
- **WSL2 with an NVIDIA GPU:** WSL2 is Linux, so it gets the CPU wheels. The Windows driver already exposes the GPU inside WSL2, so point the `sys_platform != 'win32'` entry at the CUDA index too. The Docker image is unaffected, because it doesn't install the train extra.
- **No GPU at all:** train on a free Colab GPU and bring the adapter back. `finetune.py` imports nothing from `ft`, so it runs on its own:

```python
# Colab cell, after uploading data/train.jsonl and src/ft/finetune.py
!pip install -q "transformers>=4.56" "peft>=0.17" "trl>=0.12" "datasets>=3.0"
!mkdir -p data && mv train.jsonl data/
!python finetune.py
!zip -qr adapter.zip adapter    # download it, unzip into python/adapter/
```

Colab's torch already has CUDA, which is why it isn't in the install line.

### `src/ft/make_data.py`

```python
# src/ft/make_data.py
"""Generate a small, CLEAN dataset for a JSON-formatting behavior task.

The behavior we teach: given a free-text order, emit strict JSON with an
'items' array of {qty, item}. That's behavior/format, NOT knowledge, which is
the right target for fine-tuning.
"""
from __future__ import annotations

import json
import os
import random
from pathlib import Path

# Shared with C#: one committed copy of the held-out set. Default is relative to python/.
FIXTURES_DIR = Path(os.environ.get("FIXTURES_DIR", "../fixtures"))

SYSTEM = 'Convert the order to strict JSON: {"items":[{"qty":int,"item":str}]}. JSON only.'

_ITEMS = ["red mug", "blue kettle", "wooden spoon", "steel pan", "glass jar", "cotton towel"]

N_TRAIN, N_EVAL = 200, 40

Example = dict[str, list[dict[str, str]]]


def _example(rng: random.Random) -> tuple[frozenset[tuple[str, int]], Example]:
    chosen = rng.sample(_ITEMS, rng.randint(1, 3))
    parts, items = [], []
    for it in chosen:
        qty = rng.randint(1, 5)
        parts.append(f"{qty} {it}{'s' if qty > 1 else ''}")
        items.append({"qty": qty, "item": it})
    example = {
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": "I'd like " + ", ".join(parts)},
            {"role": "assistant", "content": json.dumps({"items": items})},
        ]
    }
    # The order's identity ignores word order: "2 mugs, 1 jar" and "1 jar, 2 mugs" are one order.
    key = frozenset((i["item"], i["qty"]) for i in items)
    return key, example


def user_text(example: Example) -> str:
    return next(m["content"] for m in example["messages"] if m["role"] == "user")


def build_splits(
    seed: int = 42, n_train: int = N_TRAIN, n_eval: int = N_EVAL
) -> tuple[list[Example], list[Example]]:
    """Distinct orders, then split, so no eval order also appears in train.

    Drawing train and eval from one random stream repeats orders, and an eval row
    that sits in the training data measures memory, not generalization.
    """
    rng = random.Random(seed)
    unique: dict[frozenset[tuple[str, int]], Example] = {}
    for _ in range(100 * (n_train + n_eval)):  # bounded: there are ~2,900 distinct orders
        key, example = _example(rng)
        unique.setdefault(key, example)
        if len(unique) == n_train + n_eval:
            examples = list(unique.values())  # insertion order: deterministic for a seed
            return examples[n_eval:], examples[:n_eval]
    raise ValueError(f"couldn't draw {n_train + n_eval} distinct orders")


def _write(path: Path, examples: list[Example]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # newline="\n": the same bytes on Windows and in the Linux image.
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for example in examples:
            f.write(json.dumps(example) + "\n")


def main() -> None:
    train, held_out = build_splits()
    _write(Path("data") / "train.jsonl", train)
    _write(FIXTURES_DIR / "eval.jsonl", held_out)  # HELD OUT: committed, and C# scores it too
    print(f"Wrote data/train.jsonl ({len(train)}) and {FIXTURES_DIR / 'eval.jsonl'} ({len(held_out)})")


if __name__ == "__main__":
    main()
```

The split is the held-out rule from module 09 made mechanical. Drawing train and eval rows from one random stream, with 6 items and small quantities, repeats orders, and a repeated order in the eval set measures memory instead of generalization. So `build_splits` collects *distinct* orders first and only then splits them. "Distinct" ignores word order: "2 mugs, 1 jar" and "1 jar, 2 mugs" are the same order. The test makes the rule permanent:

```python
# tests/test_make_data.py
import json

from ft.make_data import N_EVAL, N_TRAIN, build_splits, user_text


def test_no_eval_order_appears_in_train() -> None:
    train, held_out = build_splits()
    train_texts = {user_text(e) for e in train}
    assert not [t for t in map(user_text, held_out) if t in train_texts]


def test_splits_have_the_documented_sizes_and_no_duplicates() -> None:
    train, held_out = build_splits()
    assert (len(train), len(held_out)) == (N_TRAIN, N_EVAL)
    texts = [user_text(e) for e in train + held_out]
    assert len(set(texts)) == len(texts)


def test_seeded_so_it_regenerates_byte_for_byte() -> None:
    assert json.dumps(build_splits()) == json.dumps(build_splits())
```

### `src/ft/finetune.py`

```python
# src/ft/finetune.py
"""LoRA fine-tune of a small open model on the JSON-formatting task.

This is the module-15 training loop with the base model FROZEN and only a small
LoRA adapter's parameters updating. Runs on a modest GPU; on CPU, use a tiny base
and few steps just to exercise the flow. transformers/peft/trl APIs move fast:
check them against the versions in your uv.lock.
"""
from __future__ import annotations

import os

BASE_MODEL = os.environ.get("BASE_MODEL", "Qwen/Qwen2.5-0.5B-Instruct")  # small on purpose


def main() -> None:
    # Imported here so the scoring path never needs the heavy train extra.
    import torch
    from datasets import load_dataset
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from trl import SFTConfig, SFTTrainer

    # bf16 where the GPU supports it (Ampere and newer); fp32 otherwise. fp16 training
    # needs loss scaling to stay stable, and bf16 doesn't.
    use_bf16 = torch.cuda.is_available() and torch.cuda.is_bf16_supported()

    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL, dtype=torch.bfloat16 if use_bf16 else torch.float32  # `dtype`, not the old `torch_dtype`
    )

    dataset = load_dataset("json", data_files="data/train.jsonl", split="train")

    # LoRA: freeze the base, train small adapter matrices only.
    peft_config = LoraConfig(
        r=8,  # adapter rank: small = cheap
        lora_alpha=16,
        lora_dropout=0.05,
        target_modules=["q_proj", "v_proj"],  # which layers get adapters
        task_type="CAUSAL_LM",
    )

    sft_config = SFTConfig(
        output_dir="adapter",
        num_train_epochs=3,
        per_device_train_batch_size=4,
        learning_rate=2e-4,
        logging_steps=10,
        bf16=use_bf16,  # SFTConfig defaults bf16 to True; set it from the hardware instead
    )

    trainer = SFTTrainer(
        model=model,
        args=sft_config,
        train_dataset=dataset,  # "messages" rows: the trainer applies the chat template
        peft_config=peft_config,
        processing_class=tokenizer,
    )
    trainer.train()
    trainer.save_model("adapter")  # the adapter only: a few MB
    print("Saved LoRA adapter to ./adapter")


if __name__ == "__main__":
    main()
```

Two API details moved recently, and agents still write the old ones. `from_pretrained` takes `dtype`; `torch_dtype` is deprecated and only warns in transformers 5. And `SFTTrainer` takes the tokenizer as `processing_class`, which needs trl 0.12 or later (older code passes `tokenizer=`). The `messages` field in each row is enough for trl to apply the model's chat template, so the training format matches what Ollama sends at serving time.

### `src/ft/evaluate.py`

```python
# src/ft/evaluate.py
"""Base vs tuned scorecard: the module-09 discipline applied to a fine-tune.

On the HELD-OUT eval set this measures whether the target task improved:
json_valid_rate and schema_ok_rate. It doesn't check for regressions outside the
task; that general-capability probe is an exercise (see "Cross-check the two").

`generate` is injected, so the same harness scores a live model, the stub or a
replay file, and the unit tests need no model at all.
"""
from __future__ import annotations

import json
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from llm_client.types import Message, Role
from pydantic import BaseModel, ValidationError

from ft.make_data import FIXTURES_DIR

GenerateFn = Callable[[Sequence[Message]], Awaitable[str]]  # prompt turns -> assistant text


@dataclass(frozen=True)
class EvalRow:
    prompt: list[Message]  # system + user turns
    gold: str  # the expected assistant turn, kept for content checks


@dataclass(frozen=True)
class Scorecard:
    json_valid_rate: float
    schema_ok_rate: float
    n: int


class OrderItem(BaseModel):
    qty: int
    item: str


class Order(BaseModel):
    items: list[OrderItem]


def json_valid(text: str) -> bool:
    try:
        json.loads(text)
    except ValueError:
        return False
    return True


def schema_ok(text: str) -> bool:
    try:
        Order.model_validate_json(text)
    except ValidationError:
        return False
    return True


def load_eval(path: str | Path | None = None) -> list[EvalRow]:
    path = Path(path) if path else FIXTURES_DIR / "eval.jsonl"
    rows = []
    for line in path.read_text("utf-8").splitlines():
        if not line.strip():
            continue  # skip blank lines, like C#
        messages = json.loads(line)["messages"]
        prompt = [Message(cast(Role, m["role"]), m["content"]) for m in messages[:-1]]  # drop the gold turn
        rows.append(EvalRow(prompt, messages[-1]["content"]))
    return rows


async def score(generate: GenerateFn, rows: Sequence[EvalRow]) -> Scorecard:
    if not rows:
        raise ValueError("empty eval set: a scorecard over zero rows means nothing")
    json_ok = schema_ok_count = 0
    for row in rows:
        out = (await generate(row.prompt)).strip()
        json_ok += json_valid(out)
        schema_ok_count += schema_ok(out)
    n = len(rows)
    return Scorecard(json_ok / n, schema_ok_count / n, n)


def passes_ship_gate(base: Scorecard, tuned: Scorecard) -> bool:
    """The tuned model must not regress the target metric."""
    return tuned.schema_ok_rate >= base.schema_ok_rate
```

`score` refuses an empty set instead of dividing by zero. A scorecard over zero rows is a bug upstream, so it should fail loudly. The C# `Scorer` throws on the same condition with the same message.

### `src/ft/generators.py`

```python
# src/ft/generators.py
"""Where outputs come from: a model through module 04's client, a replay file of
saved outputs, and the recorder that writes such a file."""
from __future__ import annotations

import json
import os
from collections.abc import Sequence
from pathlib import Path

from llm_client.factory import client_from_env
from llm_client.ollama import OllamaClient
from llm_client.types import LlmClient, Message

from ft.evaluate import EvalRow, GenerateFn

# The tuned model only exists in your local Ollama, so `hosted` isn't offered here.
BACKENDS = ("stub", "ollama")


def client_for(model: str) -> LlmClient:
    """Module 04's client for one named model. Base and tuned are two Ollama models,
    so the model name comes from the source, not from OLLAMA_MODEL."""
    backend = os.environ.get("LLM_BACKEND", "ollama")
    if backend not in BACKENDS:
        raise ValueError(f"unknown LLM_BACKEND {backend!r} for module 16 (expected one of: {' | '.join(BACKENDS)})")
    if backend == "ollama":
        return OllamaClient(
            base_url=os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434"),  # no /v1
            model=model,
        )
    return client_from_env()  # stub: LLM_STUB_REPLY, else "stub: <last user message>"


def from_client(client: LlmClient) -> GenerateFn:
    async def generate(messages: Sequence[Message]) -> str:
        return (await client.complete(messages)).text

    return generate


def replay(path: str | Path) -> GenerateFn:
    """Play back saved outputs in eval-set order. Deterministic: no model involved."""
    lines = Path(path).read_text("utf-8").splitlines()
    outputs = iter([json.loads(line)["output"] for line in lines if line.strip()])

    async def generate(_messages: Sequence[Message]) -> str:
        try:
            return next(outputs)
        except StopIteration:
            raise ValueError(f"{path} has fewer outputs than the eval set") from None

    return generate


async def record(generate: GenerateFn, rows: Sequence[EvalRow], out_path: str | Path) -> None:
    """Save raw outputs (untrimmed; the scorer trims) so both languages score the same text."""
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)  # fixtures/generations/ doesn't exist on a fresh clone
    with out.open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(json.dumps({"output": await generate(row.prompt)}) + "\n")
```

`client_for` is the only place this project touches backends, and it's mostly module 04. The one thing it adds is that the model name comes from the command line rather than `OLLAMA_MODEL`, because a comparison needs two models in one run. Module 04's client doesn't send a temperature, so the Modelfiles below pin `temperature 0` on the model itself. That way every client gets the same sampling settings.

### `src/ft/cli.py`

```python
# src/ft/cli.py
"""score / compare / record: the same commands, output and exit codes as the C# CLI.

A source is model:<name> (module 04's client; LLM_BACKEND picks stub or ollama)
or replay:<file> (saved outputs).
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from ft.evaluate import GenerateFn, Scorecard, load_eval, passes_ship_gate, score
from ft.generators import client_for, from_client, record, replay


def source(spec: str) -> GenerateFn:
    kind, _, arg = spec.partition(":")
    if kind == "model" and arg:
        return from_client(client_for(arg))
    if kind == "replay" and arg:
        return replay(arg)
    raise ValueError(f"unknown source {spec!r} (use model:<name> or replay:<file>)")


def scorecard_table(base: Scorecard, tuned: Scorecard) -> str:
    lines = [f"{'metric':<18}{'base':>8}{'tuned':>8}{'delta':>8}"]
    for metric, b, t in [
        ("json_valid_rate", base.json_valid_rate, tuned.json_valid_rate),
        ("schema_ok_rate", base.schema_ok_rate, tuned.schema_ok_rate),
    ]:
        lines.append(f"{metric:<18}{b:>8.3f}{t:>8.3f}{t - b:>+8.3f}")
    return "\n".join(lines)


async def run(args: argparse.Namespace) -> int:
    rows = load_eval(args.eval)
    if args.command == "score":
        s = await score(source(args.source), rows)
        print(f"json_valid_rate {s.json_valid_rate:.3f}  schema_ok_rate {s.schema_ok_rate:.3f}  n {s.n}")
        return 0
    if args.command == "compare":
        b = await score(source(args.base), rows)
        t = await score(source(args.tuned), rows)
        print(scorecard_table(b, t))
        if passes_ship_gate(b, t):
            return 0
        print("Fine-tune regressed the task!", file=sys.stderr)
        return 1
    await record(source(args.source), rows, args.out)
    print(f"Wrote {len(rows)} generations to {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--eval", help="eval set (default: $FIXTURES_DIR/eval.jsonl)")
    parser = argparse.ArgumentParser(prog="ft", epilog="source: model:<name> | replay:<generations.jsonl>")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("score", parents=[common]).add_argument("source")
    p = sub.add_parser("compare", parents=[common])
    p.add_argument("base")
    p.add_argument("tuned")
    p = sub.add_parser("record", parents=[common])
    p.add_argument("source")
    p.add_argument("out")
    return asyncio.run(run(parser.parse_args(argv)))  # argparse exits 2 on bad usage, like C#


if __name__ == "__main__":
    sys.exit(main())
```

The ship gate is an exit code, not an `assert`. `python -O` strips asserts, and a CI step can only act on exit codes. That's the same contract as the C# CLI.

### Tests

The schema table is the contract between the two languages. `OrderSchemaTests.cs` holds the same strings, and if a row disagrees, Python is the spec.

```python
# tests/test_evaluate.py
import asyncio
import json
from collections.abc import Sequence
from pathlib import Path

import pytest
from llm_client.types import Message

from ft.evaluate import EvalRow, Scorecard, json_valid, passes_ship_gate, schema_ok, score
from ft.generators import record, replay

ROWS = [
    EvalRow([Message("user", "2 red mugs")], gold="{}"),
    EvalRow([Message("user", "1 blue kettle")], gold="{}"),
]


def always(text: str):
    async def generate(_messages: Sequence[Message]) -> str:
        return text

    return generate


# The same table as the C# OrderSchemaTests: the contract between the two languages.
@pytest.mark.parametrize(
    ("text", "valid", "ok"),
    [
        ('{"items":[{"qty":3,"item":"red mug"}]}', True, True),
        ('{"items":[]}', True, True),  # valid but empty: see the review track
        ('{"items":[{"qty":3,"item":"red mug","note":"x"}]}', True, True),  # extra field ignored
        ('{"items":[{"qty":"3","item":"red mug"}]}', True, True),  # lax int
        ('{"items":[{"qty":3.0,"item":"red mug"}]}', True, True),
        ('{"items":[{"qty":3.5,"item":"red mug"}]}', True, False),
        ('{"items":[{"qty":3}]}', True, False),  # missing field
        ('{"items":[{"qty":3,"item":7}]}', True, False),  # pydantic won't coerce int -> str
        ('[{"qty":3,"item":"red mug"}]', True, False),  # wrong root
        ('sure! {"items":[]}', False, False),
        ("", False, False),
    ],
)
def test_classifies_output(text: str, valid: bool, ok: bool) -> None:
    assert (json_valid(text), schema_ok(text)) == (valid, ok)


def test_good_model_scores_high_and_bad_model_scores_zero() -> None:
    good = asyncio.run(score(always('{"items": [{"qty": 2, "item": "red mug"}]}'), ROWS))
    bad = asyncio.run(score(always("sure! here you go: 2 red mugs"), ROWS))
    assert good.schema_ok_rate == 1.0
    assert bad.schema_ok_rate == 0.0


def test_empty_eval_set_is_an_error_not_a_zero_division() -> None:
    with pytest.raises(ValueError, match="empty eval set"):
        asyncio.run(score(always("{}"), []))


def test_replay_scores_saved_outputs_in_order(tmp_path: Path) -> None:
    path = tmp_path / "gen.jsonl"
    path.write_text(
        json.dumps({"output": ' {"items":[{"qty":2,"item":"red mug"}]}\n'})  # whitespace is trimmed
        + "\n"
        + json.dumps({"output": "not json"})
        + "\n",
        encoding="utf-8",
    )
    s = asyncio.run(score(replay(path), ROWS))
    assert (s.json_valid_rate, s.schema_ok_rate) == (0.5, 0.5)


def test_replay_with_too_few_outputs_fails_loudly(tmp_path: Path) -> None:
    path = tmp_path / "gen.jsonl"
    path.write_text(json.dumps({"output": "{}"}) + "\n", encoding="utf-8")
    with pytest.raises(ValueError, match="fewer outputs"):
        asyncio.run(score(replay(path), ROWS))


def test_record_creates_the_folder_and_round_trips(tmp_path: Path) -> None:
    out = tmp_path / "generations" / "base.jsonl"
    asyncio.run(record(always(" raw output\n"), ROWS, out))
    s = asyncio.run(score(replay(out), ROWS))
    assert s == Scorecard(0.0, 0.0, 2)
    assert json.loads(out.read_text("utf-8").splitlines()[0]) == {"output": " raw output\n"}  # untrimmed


@pytest.mark.parametrize(("base", "tuned", "passes"), [(0.80, 0.95, True), (0.95, 0.95, True), (0.95, 0.80, False)])
def test_ship_gate_blocks_a_regression(base: float, tuned: float, passes: bool) -> None:
    assert passes_ship_gate(Scorecard(1, base, 40), Scorecard(1, tuned, 40)) is passes
```

The CLI tests run the real commands on module 04's stub, including a record → replay round trip and a gate that fails:

```python
# tests/test_cli.py
import json
from pathlib import Path

import pytest

from ft.cli import main
from ft.make_data import SYSTEM

GOOD = '{"items":[{"qty":2,"item":"red mug"}]}'


@pytest.fixture
def eval_file(tmp_path: Path) -> Path:
    path = tmp_path / "eval.jsonl"
    row = {"messages": [{"role": "system", "content": SYSTEM},
                        {"role": "user", "content": "I'd like 2 red mugs"},
                        {"role": "assistant", "content": GOOD}]}
    path.write_text(json.dumps(row) + "\n" + json.dumps(row) + "\n", encoding="utf-8")
    return path


def test_compare_on_the_stub(eval_file: Path, monkeypatch, capsys) -> None:
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.setenv("LLM_STUB_REPLY", GOOD)
    assert main(["compare", "model:ft-base", "model:ft-tuned", "--eval", str(eval_file)]) == 0
    assert capsys.readouterr().out.splitlines() == [
        "metric                base   tuned   delta",
        "json_valid_rate      1.000   1.000  +0.000",
        "schema_ok_rate       1.000   1.000  +0.000",
    ]


def test_record_then_compare_replay_fails_the_gate(eval_file: Path, tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("LLM_BACKEND", "stub")
    monkeypatch.delenv("LLM_STUB_REPLY", raising=False)  # replies "stub: <last user message>"
    gen = tmp_path / "generations"
    assert main(["record", "model:ft-tuned", str(gen / "tuned.jsonl"), "--eval", str(eval_file)]) == 0
    monkeypatch.setenv("LLM_STUB_REPLY", GOOD)
    assert main(["record", "model:ft-base", str(gen / "base.jsonl"), "--eval", str(eval_file)]) == 0
    code = main(["compare", f"replay:{gen / 'base.jsonl'}", f"replay:{gen / 'tuned.jsonl'}", "--eval", str(eval_file)])
    assert code == 1  # tuned (not JSON) regressed against base (valid JSON)


def test_unsupported_backend_fails_loudly(eval_file: Path, monkeypatch) -> None:
    monkeypatch.setenv("LLM_BACKEND", "hosted")
    with pytest.raises(ValueError, match=r"expected one of: stub \| ollama"):
        main(["score", "model:ft-tuned", "--eval", str(eval_file)])
```

### Configuration

```bash
# projects/16-fine-tuning/python/.env.example
# Copy to .env (git-ignored). compose reads it; a bare `uv run` doesn't, so set variables in your shell there.
# Names: docs/conventions.md#environment-variables

# stub | ollama (hosted isn't supported: the tuned model lives in your Ollama)
LLM_BACKEND=ollama

# ollama: the server root, without /v1. Leave it commented: compose then uses
# http://host.docker.internal:11434 (or the ollama profile's service), and local runs
# default to http://localhost:11434. A localhost value here would point the container at itself.
# OLLAMA_BASE_URL=http://localhost:11434

# stub: a fixed reply instead of "stub: <last user message>"
LLM_STUB_REPLY=

# the Hugging Face base model finetune.py and export.py download
BASE_MODEL=Qwen/Qwen2.5-0.5B-Instruct

# where eval.jsonl lives; default ../fixtures, and the Dockerfiles set it
# FIXTURES_DIR=
```

There's no `OLLAMA_MODEL`: the model names come from the `model:` sources on the command line.

### Run it locally

```powershell
cd projects/16-fine-tuning/python
uv sync                            # light: no torch
uv run pytest
uv run python -m ft.make_data      # data/train.jsonl + ../fixtures/eval.jsonl (commit the second)

# The whole scorecard on the stub: no GPU, no model
$env:LLM_BACKEND = 'stub'
uv run python -m ft.cli score model:ft-base 2> $null      # 0.000: "stub: I'd like ..." isn't JSON
$env:LLM_STUB_REPLY = '{"items":[{"qty":1,"item":"red mug"}]}'
uv run python -m ft.cli compare model:ft-base model:ft-tuned 2> $null
Remove-Item Env:LLM_STUB_REPLY

# Training: the heavy extra, ideally on a GPU
uv run --extra train python -m ft.finetune    # writes ./adapter
```

The `2> $null` hides module 04's `llm_call` log lines, one per call, which go to stderr.

### Export and register with Ollama

`export.py` makes the tuned model loadable outside PEFT. It merges the adapter into the base weights (the "merged" serving shape from earlier) and saves plain Hugging Face folders. It exports the base through the **same pipeline**, so the comparison is like with like.

```python
# src/ft/export.py
"""Merge the LoRA adapter and export base + tuned as plain HF model folders.

The hand-off to runtimes that don't speak PEFT: Ollama (via GGUF), ONNX Runtime
GenAI, and therefore .NET. Base goes through the SAME export so base-vs-tuned
measures the fine-tune, not a difference in conversion or quantization.
"""
from __future__ import annotations

from ft.finetune import BASE_MODEL


def main() -> None:
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)

    base = AutoModelForCausalLM.from_pretrained(BASE_MODEL)
    base.save_pretrained("models/base-hf")
    tokenizer.save_pretrained("models/base-hf")

    tuned = PeftModel.from_pretrained(AutoModelForCausalLM.from_pretrained(BASE_MODEL), "adapter")
    merged = tuned.merge_and_unload()  # fold the adapter into the weights -> standalone model
    merged.save_pretrained("models/tuned-hf")
    tokenizer.save_pretrained("models/tuned-hf")
    print("Wrote models/base-hf and models/tuned-hf")


if __name__ == "__main__":
    main()
```

Then convert both folders to GGUF with llama.cpp's converter, at the same precision. The converter is a script in the llama.cpp repo with its own pinned requirements, so give it its own throwaway environment instead of installing them into this project. Clone it once, outside the repo:

```powershell
git clone --depth 1 https://github.com/ggml-org/llama.cpp C:\tools\llama.cpp
```

```powershell
cd projects/16-fine-tuning/python
uv run --extra train python -m ft.export      # models/base-hf, models/tuned-hf

$llama = 'C:\tools\llama.cpp'
$req = "$llama\requirements\requirements-convert_hf_to_gguf.txt"
uv run --no-project --python 3.12 --with-requirements $req python $llama\convert_hf_to_gguf.py models/base-hf --outfile models/base.gguf --outtype q8_0
uv run --no-project --python 3.12 --with-requirements $req python $llama\convert_hf_to_gguf.py models/tuned-hf --outfile models/tuned.gguf --outtype q8_0

ollama create ft-base  -f ollama/Modelfile.base
ollama create ft-tuned -f ollama/Modelfile.tuned
ollama show --modelfile ft-tuned     # check TEMPLATE is the model's chat template
```

`uv run --no-project --with-requirements` builds a cached, isolated environment from llama.cpp's own requirements file. That file pins its own torch (2.11 from the CPU index, at the time of writing), so it must never meet this project's lockfile.

The Modelfiles. Paths are relative to the Modelfile:

```text
# ollama/Modelfile.base
FROM ../models/base.gguf
PARAMETER temperature 0
```

```text
# ollama/Modelfile.tuned
FROM ../models/tuned.gguf
PARAMETER temperature 0
```

There's no `SYSTEM` line on purpose. The eval rows already carry the system prompt, and a second one would break "match training and serving format exactly". Check the chat template too. Ollama usually picks it up from the GGUF metadata, and if it doesn't, the tuned model gets prompted in a format it never trained on. Ollama can also import safetensors folders directly, and it has an `ADAPTER` instruction for LoRA adapters. Both only work for the architectures Ollama lists in its import docs, so check whether your base is on that list before you skip the GGUF step.

### Score the real models

This is the step that decides whether you ship. With Ollama running natively:

```powershell
cd projects/16-fine-tuning/python
$env:LLM_BACKEND = 'ollama'
uv run python -m ft.cli compare model:ft-base model:ft-tuned 2> $null     # exit code 1 = the gate failed

# Save the outputs as fixtures, so both languages (and CI) can score them without a model
uv run python -m ft.cli record model:ft-base  ../fixtures/generations/base.jsonl
uv run python -m ft.cli record model:ft-tuned ../fixtures/generations/tuned.jsonl
uv run python -m ft.cli compare replay:../fixtures/generations/base.jsonl replay:../fixtures/generations/tuned.jsonl
```

Commit `fixtures/generations/`. Those two files, plus `eval.jsonl`, are the evidence for the ship decision, and they're what the exact cross-check scores.

### Running the Python version in Docker

The image holds the light path only: the scorecard and the tests. Training, with its GPU and multi-gigabyte stack, runs where the hardware is and produces a small adapter you carry back. That's the module-14 lesson again: **training and serving are separate concerns**, so don't force a GPU training stack into your serving image.

```dockerfile
# projects/16-fine-tuning/python/Dockerfile — build context: projects/
# The light image: data generation and the scorecard. The train extra isn't installed, so no torch.
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
# Project 04 first: the path dependency must exist before uv can install anything.
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 16-fine-tuning/python/pyproject.toml 16-fine-tuning/python/uv.lock 16-fine-tuning/python/README.md 16-fine-tuning/python/
WORKDIR /src/16-fine-tuning/python
RUN uv sync --frozen --no-install-project
COPY 16-fine-tuning/python/ ./
COPY 16-fine-tuning/fixtures/ /src/16-fine-tuning/fixtures/
RUN uv sync --frozen          # installs ft plus the dev group (pytest); still no train extra
ENV PATH="/src/16-fine-tuning/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/16-fine-tuning/fixtures
CMD ["pytest", "-q"]
```

```yaml
# projects/16-fine-tuning/python/compose.yaml
name: fine-tuning-py   # otherwise the project is named after the folder: "python"
services:
  app:
    build: { context: ../.., dockerfile: 16-fine-tuning/python/Dockerfile }   # projects/: 04 and fixtures/ must be inside
    env_file:
      - path: .env             # optional overrides
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      # ft-base and ft-tuned live in the native Ollama where you ran `ollama create`
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
    extra_hosts: ["host.docker.internal:host-gateway"]
```

There's no `ollama` service: `ft-base` and `ft-tuned` were registered with the native Ollama on your machine, so the container reaches that one through `host.docker.internal`.

```powershell
cd projects/16-fine-tuning/python
docker compose run --rm app                                                   # pytest, no model
docker compose run --rm -e LLM_BACKEND=stub app python -m ft.cli score model:ft-base
docker compose run --rm app python -m ft.cli compare model:ft-base model:ft-tuned   # native Ollama
```

## C# implementation

Work in `projects/16-fine-tuning/csharp/`. This side is deliberately not a port of `finetune.py`. What differs, and why:

- **No training in C#.** LoRA training needs PyTorch, `transformers`, PEFT and TRL. TorchSharp gives .NET tensors and autograd, but none of that ecosystem, and rebuilding it isn't the lesson. Real .NET shops do the same thing: data scientists train in Python, and the product team consumes and evaluates the result. So the C# side starts where Python hands off an exported model.
- **The model is an artifact you load, not a library call.** Once the tuned model is a GGUF in Ollama, it's just another `IChatClient` from module 04's `AddLlmClient`, with the same stub, cost logging and retries as everywhere else. That's the module 03 lesson again: the model is something you download, version and ship.
- **The schema check is explicit.** Pydantic's `model_validate_json` hides a lot of rules. For example, its lax mode accepts `3`, `3.0` and `"3"` for an `int`. Deserializing into a C# record with `System.Text.Json` applies *different* rules: a missing `qty` silently becomes `0`, and `"3"` fails unless you opt in. Either difference makes the scorecards drift. So `OrderSchema` walks a `JsonDocument` and writes pydantic's rules down. (A JSON Schema validator such as `JsonSchema.Net` is the other option. It's stricter than pydantic's lax mode, so you'd need to loosen the schema to match.)
- **`generate` is an async delegate with a `CancellationToken`.** Same injected seam as Python's `GenerateFn`, so the harness is unit-testable with fakes.

### Scaffold

From the repo root:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 16-fine-tuning -Template console -Name FineTuning
cd projects/16-fine-tuning/csharp
Remove-Item tests/FineTuning.Tests/SmokeTests.cs
dotnet add src/FineTuning reference ../../04-llm-client/csharp/src/LlmClient/LlmClient.csproj
dotnet add src/FineTuning package Microsoft.Extensions.Configuration.EnvironmentVariables
dotnet add src/FineTuning package Microsoft.Extensions.Logging.Console
```

`Microsoft.Extensions.AI`, OllamaSharp and the DI and HTTP packages flow in through the `LlmClient` reference. This doc was built against those two packages at 10.0.12, plus module 04's versions. Copy `python/.env.example` to `csharp/.env.example`: both sides read the same variables.

### `src/FineTuning/EvalSet.cs`

```csharp
// src/FineTuning/EvalSet.cs
using System.Text.Json;
using Microsoft.Extensions.AI;

namespace FineTuning;

/// <summary>One held-out row: the prompt turns, plus the gold answer kept for content checks.</summary>
public sealed record EvalRow(IReadOnlyList<ChatMessage> Prompt, string Gold);

public static class EvalSet
{
    private sealed record Line(Msg[] Messages);
    private sealed record Msg(string Role, string Content);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static IReadOnlyList<EvalRow> Load(string path) =>
        File.ReadLines(path)
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .Select(l => JsonSerializer.Deserialize<Line>(l, Json)
                         ?? throw new InvalidDataException($"Bad eval row in {path}: {l}"))
            .Select(line => new EvalRow(
                // Drop the gold assistant turn, exactly like messages[:-1] in Python.
                line.Messages[..^1].Select(m => new ChatMessage(new ChatRole(m.Role), m.Content)).ToList(),
                line.Messages[^1].Content))
            .ToList();
}
```

### `src/FineTuning/OrderSchema.cs`

```csharp
// src/FineTuning/OrderSchema.cs
using System.Globalization;
using System.Text.Json;

namespace FineTuning;

/// <summary>
/// The two target-task checks. Python is the spec: json.loads for validity, and pydantic's
/// lax-mode Order model for the schema. The rules pydantic applies implicitly are written out here.
/// </summary>
public static class OrderSchema
{
    public static bool IsValidJson(string text)
    {
        try
        {
            using var _ = JsonDocument.Parse(text);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static bool IsSchemaOk(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            JsonElement root = doc.RootElement;
            return root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("items", out JsonElement items)   // case-sensitive, like pydantic
                && items.ValueKind == JsonValueKind.Array
                && items.EnumerateArray().All(IsOrderItem);             // extra fields are ignored, like pydantic
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool IsOrderItem(JsonElement e) =>
        e.ValueKind == JsonValueKind.Object
        && e.TryGetProperty("qty", out JsonElement qty) && IsLaxInt(qty)
        && e.TryGetProperty("item", out JsonElement item) && item.ValueKind == JsonValueKind.String;

    // Pydantic's lax mode accepts 3, 3.0 and "3" for an int, and rejects 3.5. Mirror it or the scorecards drift.
    private static bool IsLaxInt(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Number => e.TryGetInt64(out _) || (e.TryGetDouble(out double d) && double.IsInteger(d)),
        JsonValueKind.String => long.TryParse(e.GetString(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _),
        _ => false,
    };
}
```

Two known edges where the parsers still differ. Python's `json.loads` accepts `NaN` and `Infinity`, and `JsonDocument` rejects them. Pydantic's conversion table also has rules for booleans and whitespace-padded strings that this doesn't copy. Pydantic's docs are the spec. If a real model output ever hits one of these edges, the cross-check will show it, and the fix goes on the C# side.

### `src/FineTuning/Backends.cs`

The `client_for` twin. `AddLlmClient` reads the model from `OLLAMA_MODEL`, so this layers the source's model name over the environment and lets module 04 do the rest. It's two lines of configuration, not a second Ollama adapter.

```csharp
// src/FineTuning/Backends.cs
using LlmClient;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace FineTuning;

/// <summary>The client_for twin: module 04's client for one named model.</summary>
public static class Backends
{
    // The tuned model only exists in your local Ollama, so `hosted` isn't offered here.
    public static readonly string[] Supported = ["stub", "ollama"];

    /// <summary>
    /// Base and tuned are two Ollama models, so the model name comes from the source and overrides
    /// OLLAMA_MODEL. Everything else (LLM_BACKEND, the stub, cost logging, retries) is 04's AddLlmClient.
    /// </summary>
    public static IChatClient ClientFor(string model, IConfiguration env)
    {
        string backend = env["LLM_BACKEND"] ?? "ollama";
        if (!Supported.Contains(backend))
            throw new InvalidOperationException(
                $"unknown LLM_BACKEND '{backend}' for module 16 (expected one of: {string.Join(" | ", Supported)})");

        IConfiguration config = new ConfigurationBuilder()
            .AddConfiguration(env)
            .AddInMemoryCollection([new("OLLAMA_MODEL", model)])
            .Build();

        var services = new ServiceCollection()
            // llm_call lines go to stderr, as in Python, so stdout stays the scorecard.
            .AddLogging(b => b.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace));
        services.AddLlmClient(config);
        return services.BuildServiceProvider().GetRequiredService<IChatClient>();
    }
}
```

### `src/FineTuning/Generators.cs`

```csharp
// src/FineTuning/Generators.cs
using System.Text.Json;
using Microsoft.Extensions.AI;

namespace FineTuning;

/// <summary>messages -> assistant text. The same injected seam as Python's GenerateFn.</summary>
public delegate Task<string> GenerateAsync(IReadOnlyList<ChatMessage> messages, CancellationToken ct);

public static class Generators
{
    private sealed record Generation(string Output);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>Any IChatClient: the 04 stub or Ollama today, ONNX Runtime GenAI or Bedrock tomorrow.</summary>
    public static GenerateAsync FromChatClient(IChatClient client) =>
        async (messages, ct) =>
        {
            ChatResponse response = await client.GetResponseAsync(
                messages, new ChatOptions { Temperature = 0f }, ct);
            return response.Text;
        };

    /// <summary>Play back saved outputs in eval-set order. Deterministic: no model involved.</summary>
    public static GenerateAsync Replay(string path)
    {
        var outputs = new Queue<string>(
            File.ReadLines(path)
                .Where(l => !string.IsNullOrWhiteSpace(l))
                .Select(l => JsonSerializer.Deserialize<Generation>(l, Json)?.Output
                             ?? throw new InvalidDataException($"Bad generation line in {path}: {l}")));

        return (_, _) => outputs.TryDequeue(out string? output)
            ? Task.FromResult(output)
            : throw new InvalidOperationException($"{path} has fewer outputs than the eval set");
    }

    /// <summary>Save raw outputs (untrimmed; the scorer trims) so both languages can score the same text.</summary>
    public static async Task RecordAsync(
        GenerateAsync generate, IReadOnlyList<EvalRow> rows, string outPath, CancellationToken ct)
    {
        // fixtures/generations/ doesn't exist on a fresh clone.
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath))!);
        await using var writer = new StreamWriter(outPath) { NewLine = "\n" };   // LF, like Python's file
        foreach (EvalRow row in rows)
        {
            string output = await generate(row.Prompt, ct);
            await writer.WriteLineAsync(JsonSerializer.Serialize(new Generation(output), Json).AsMemory(), ct);
        }
    }
}
```

`Temperature = 0f` is belt and braces: the Modelfile already pins it, but a model registered without that line would otherwise sample.

### `src/FineTuning/Scorer.cs`

```csharp
// src/FineTuning/Scorer.cs
namespace FineTuning;

public sealed record Scorecard(double JsonValidRate, double SchemaOkRate, int N);

/// <summary>Base vs tuned scorecard: the module-09 discipline, ported from evaluate.py.</summary>
public static class Scorer
{
    public static async Task<Scorecard> ScoreAsync(
        GenerateAsync generate, IReadOnlyList<EvalRow> rows, CancellationToken ct = default)
    {
        // Python raises ValueError with the same message: both refuse, neither divides by zero.
        if (rows.Count == 0)
            throw new ArgumentException("empty eval set: a scorecard over zero rows means nothing", nameof(rows));

        int jsonOk = 0, schemaOk = 0;
        foreach (EvalRow row in rows)
        {
            string output = (await generate(row.Prompt, ct)).Trim();   // .strip() in Python
            if (OrderSchema.IsValidJson(output)) jsonOk++;
            if (OrderSchema.IsSchemaOk(output)) schemaOk++;
        }
        return new Scorecard((double)jsonOk / rows.Count, (double)schemaOk / rows.Count, rows.Count);
    }

    /// <summary>Ship gate, as in Python: the tuned model must not regress the target metric.</summary>
    public static bool PassesShipGate(Scorecard @base, Scorecard tuned) =>
        tuned.SchemaOkRate >= @base.SchemaOkRate;
}
```

### `src/FineTuning/Program.cs`

A source is `model:<name>` for a model through module 04's client, or `replay:<file>` for saved outputs. `compare` returns exit code 1 when the gate fails, exactly like `ft.cli`, and that's what a CI step keys off.

```csharp
// src/FineTuning/Program.cs
using System.Globalization;
using FineTuning;
using Microsoft.Extensions.Configuration;

CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;   // "0.950", never "0,950"

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
CancellationToken ct = cts.Token;

// The same env vars as every module: LLM_BACKEND, OLLAMA_BASE_URL, LLM_STUB_REPLY, FIXTURES_DIR.
IConfiguration env = new ConfigurationBuilder().AddEnvironmentVariables().Build();
// Shared with Python: one committed copy. Default is relative to csharp/, where you run dotnet run.
string fixturesDir = env["FIXTURES_DIR"] ?? "../fixtures";

switch (args)
{
    case ["score", var source, ..]:
    {
        Scorecard s = await Scorer.ScoreAsync(Source(source), LoadRows(), ct);
        Console.WriteLine($"json_valid_rate {s.JsonValidRate:F3}  schema_ok_rate {s.SchemaOkRate:F3}  n {s.N}");
        return 0;
    }
    case ["compare", var baseSource, var tunedSource, ..]:
    {
        IReadOnlyList<EvalRow> rows = LoadRows();
        Scorecard b = await Scorer.ScoreAsync(Source(baseSource), rows, ct);
        Scorecard t = await Scorer.ScoreAsync(Source(tunedSource), rows, ct);
        Console.WriteLine($"{"metric",-18}{"base",8}{"tuned",8}{"delta",8}");
        PrintRow("json_valid_rate", b.JsonValidRate, t.JsonValidRate);
        PrintRow("schema_ok_rate", b.SchemaOkRate, t.SchemaOkRate);
        if (Scorer.PassesShipGate(b, t))
            return 0;
        Console.Error.WriteLine("Fine-tune regressed the task!");
        return 1;
    }
    case ["record", var source, var outPath, ..]:
    {
        IReadOnlyList<EvalRow> rows = LoadRows();
        await Generators.RecordAsync(Source(source), rows, outPath, ct);
        Console.WriteLine($"Wrote {rows.Count} generations to {outPath}");
        return 0;
    }
    default:
        Console.Error.WriteLine(
            "usage: ft score   <source>                    [--eval file]\n" +
            "       ft compare <base-source> <tuned-source> [--eval file]\n" +
            "       ft record  <source> <out.jsonl>         [--eval file]\n" +
            "source: model:<name> | replay:<generations.jsonl>");
        return 2;
}

GenerateAsync Source(string spec) => spec.Split(':', 2) switch
{
    ["model", { Length: > 0 } model] => Generators.FromChatClient(Backends.ClientFor(model, env)),
    ["replay", { Length: > 0 } path] => Generators.Replay(path),
    _ => throw new ArgumentException($"unknown source '{spec}' (use model:<name> or replay:<file>)"),
};

IReadOnlyList<EvalRow> LoadRows() =>
    EvalSet.Load(Opt(args, "--eval") ?? Path.Combine(fixturesDir, "eval.jsonl"));

static void PrintRow(string metric, double b, double t) =>
    Console.WriteLine($"{metric,-18}{b,8:F3}{t,8:F3}{t - b,8:+0.000;-0.000;+0.000}");

static string? Opt(string[] args, string name)
{
    int i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}
```

Swapping Ollama for an in-process model is a change to `Source` only. `Microsoft.ML.OnnxRuntimeGenAI` ships an `IChatClient` implementation for models exported with its model builder (`python -m onnxruntime_genai.models.builder` run on `models/tuned-hf`). Both the builder flags and the C# class name have changed between releases, so verify them against current docs.

### `tests/FineTuning.Tests/OrderSchemaTests.cs`

The same table as `test_classifies_output`.

```csharp
// tests/FineTuning.Tests/OrderSchemaTests.cs

namespace FineTuning.Tests;

public class OrderSchemaTests
{
    // The same table as test_classifies_output in tests/test_evaluate.py. If a row disagrees, Python is the spec.
    [TestCase("""{"items":[{"qty":3,"item":"red mug"}]}""", true, true)]
    [TestCase("""{"items":[]}""", true, true)]                              // valid but empty: see the review track
    [TestCase("""{"items":[{"qty":3,"item":"red mug","note":"x"}]}""", true, true)]   // extra field ignored
    [TestCase("""{"items":[{"qty":"3","item":"red mug"}]}""", true, true)]   // lax int, like pydantic
    [TestCase("""{"items":[{"qty":3.0,"item":"red mug"}]}""", true, true)]
    [TestCase("""{"items":[{"qty":3.5,"item":"red mug"}]}""", true, false)]
    [TestCase("""{"items":[{"qty":3}]}""", true, false)]                    // missing field
    [TestCase("""{"items":[{"qty":3,"item":7}]}""", true, false)]           // pydantic won't coerce int -> str
    [TestCase("""[{"qty":3,"item":"red mug"}]""", true, false)]             // wrong root
    [TestCase("""sure! {"items":[]}""", false, false)]
    [TestCase("", false, false)]
    public void Classifies_output(string text, bool validJson, bool schemaOk)
    {
        Assert.That(OrderSchema.IsValidJson(text), Is.EqualTo(validJson));
        Assert.That(OrderSchema.IsSchemaOk(text), Is.EqualTo(schemaOk));
    }
}
```

### `tests/FineTuning.Tests/ScorerTests.cs`

The same cases as `test_evaluate.py` and `test_cli.py`: fake models, replay, record, the gate, and module 04's stub through `Backends`. These tests build their own data, so they never read `fixtures/`. If you add one that does, read `FIXTURES_DIR` and fail with a clear message when it's unset, because NUnit's working directory is the test `bin/` folder, where `../fixtures` points nowhere.

```csharp
// tests/FineTuning.Tests/ScorerTests.cs
using System.Text.Json;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;

namespace FineTuning.Tests;

public class ScorerTests
{
    private const string Good = """{"items":[{"qty":2,"item":"red mug"}]}""";

    private static readonly IReadOnlyList<EvalRow> Rows =
    [
        new([new ChatMessage(ChatRole.User, "2 red mugs")], Gold: "{}"),
        new([new ChatMessage(ChatRole.User, "1 blue kettle")], Gold: "{}"),
    ];

    private static GenerateAsync Always(string text) => (_, _) => Task.FromResult(text);

    private static string TempFile(string name) => Path.Combine(TestContext.CurrentContext.WorkDirectory, name);

    [Test]
    public async Task Good_model_scores_high_and_bad_model_scores_zero()
    {
        Scorecard good = await Scorer.ScoreAsync(Always("""{"items": [{"qty": 2, "item": "red mug"}]}"""), Rows);
        Scorecard bad = await Scorer.ScoreAsync(Always("sure! here you go: 2 red mugs"), Rows);

        Assert.That(good.SchemaOkRate, Is.EqualTo(1.0));
        Assert.That(bad.SchemaOkRate, Is.EqualTo(0.0));
    }

    [Test]
    public void Empty_eval_set_is_an_error_not_a_zero_division() =>
        Assert.ThrowsAsync<ArgumentException>(() => Scorer.ScoreAsync(Always("{}"), []));

    [Test]
    public async Task Replay_scores_saved_outputs_in_order()
    {
        string path = TempFile("gen.jsonl");
        await File.WriteAllLinesAsync(path,
        [
            """{"output":" {\"items\":[{\"qty\":2,\"item\":\"red mug\"}]}\n"}""",   // whitespace is trimmed
            """{"output":"not json"}""",
        ]);

        Scorecard s = await Scorer.ScoreAsync(Generators.Replay(path), Rows);

        Assert.That(s.JsonValidRate, Is.EqualTo(0.5));
        Assert.That(s.SchemaOkRate, Is.EqualTo(0.5));
    }

    [Test]
    public async Task Replay_with_too_few_outputs_fails_loudly()
    {
        string path = TempFile("short.jsonl");
        await File.WriteAllLinesAsync(path, ["""{"output":"{}"}"""]);

        Assert.ThrowsAsync<InvalidOperationException>(() => Scorer.ScoreAsync(Generators.Replay(path), Rows));
    }

    [Test]
    public async Task Record_creates_the_folder_and_round_trips()
    {
        string path = Path.Combine(TempFile($"gen-{Guid.NewGuid():N}"), "generations", "base.jsonl");

        await Generators.RecordAsync(Always(" raw output\n"), Rows, path, CancellationToken.None);
        Scorecard s = await Scorer.ScoreAsync(Generators.Replay(path), Rows);

        Assert.That(s, Is.EqualTo(new Scorecard(0, 0, 2)));
        string first = File.ReadLines(path).First();
        Assert.That(JsonDocument.Parse(first).RootElement.GetProperty("output").GetString(),
            Is.EqualTo(" raw output\n"));   // untrimmed
    }

    [TestCase(0.80, 0.95, true)]
    [TestCase(0.95, 0.95, true)]
    [TestCase(0.95, 0.80, false)]
    public void Ship_gate_blocks_a_regression(double baseRate, double tunedRate, bool passes) =>
        Assert.That(
            Scorer.PassesShipGate(new Scorecard(1, baseRate, 40), new Scorecard(1, tunedRate, 40)),
            Is.EqualTo(passes));

    private static IConfiguration Env(params (string Key, string Value)[] pairs) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(pairs.Select(p => new KeyValuePair<string, string?>(p.Key, p.Value)))
            .Build();

    [Test]
    public async Task Scores_module_04s_stub_through_the_model_source()
    {
        IChatClient client = Backends.ClientFor("ft-tuned", Env(("LLM_BACKEND", "stub"), ("LLM_STUB_REPLY", Good)));

        Scorecard s = await Scorer.ScoreAsync(Generators.FromChatClient(client), Rows);

        Assert.That(s, Is.EqualTo(new Scorecard(1, 1, 2)));
    }

    [Test]
    public void Unsupported_backend_fails_loudly()
    {
        var ex = Assert.Throws<InvalidOperationException>(
            () => Backends.ClientFor("ft-tuned", Env(("LLM_BACKEND", "hosted"))));
        Assert.That(ex!.Message, Does.Contain("expected one of: stub | ollama"));
    }
}
```

Run locally, from `projects/16-fine-tuning/csharp/`:

```powershell
dotnet test
dotnet test --filter "FullyQualifiedName~OrderSchemaTests"

# Offline, on module 04's stub
$env:LLM_BACKEND = 'stub'
dotnet run --project src/FineTuning -- score model:ft-base 2> $null

# Deterministic: score the committed outputs. No model, no GPU.
dotnet run --project src/FineTuning -- compare replay:../fixtures/generations/base.jsonl replay:../fixtures/generations/tuned.jsonl

# Live, against the models you registered with Ollama
$env:LLM_BACKEND = 'ollama'
dotnet run --project src/FineTuning -- compare model:ft-base model:ft-tuned 2> $null

# C# can record too; either language's files score the same
dotnet run --project src/FineTuning -- record model:ft-tuned ../fixtures/generations/tuned.jsonl
```

### Running the C# version in Docker

The same multi-stage shape as module 04, with `projects/` as the context so the build reaches `LlmClient` and the shared `fixtures/`. The image holds the harness and the fixtures; the models stay in Ollama on the host. Rebuild after you record new generations.

```dockerfile
# projects/16-fine-tuning/csharp/Dockerfile — build context: projects/
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Restore on its own layer: every .csproj, plus 04's Directory.Build.props (MSBuild applies the nearest one).
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 16-fine-tuning/csharp/FineTuning.slnx 16-fine-tuning/csharp/Directory.Build.props 16-fine-tuning/csharp/
COPY 16-fine-tuning/csharp/src/FineTuning/FineTuning.csproj 16-fine-tuning/csharp/src/FineTuning/
COPY 16-fine-tuning/csharp/tests/FineTuning.Tests/FineTuning.Tests.csproj 16-fine-tuning/csharp/tests/FineTuning.Tests/
WORKDIR /src/16-fine-tuning/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 16-fine-tuning/csharp/ 16-fine-tuning/csharp/
WORKDIR /src/16-fine-tuning/csharp
RUN dotnet publish src/FineTuning -c Release -o /app --no-restore

FROM build AS test
ENTRYPOINT ["dotnet", "test", "--no-restore"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 16-fine-tuning/fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
USER $APP_UID
ENTRYPOINT ["dotnet", "FineTuning.dll"]
```

```yaml
# projects/16-fine-tuning/csharp/compose.yaml
name: fine-tuning-cs
services:
  app:
    build: { context: ../.., dockerfile: 16-fine-tuning/csharp/Dockerfile, target: final }
    env_file:
      - path: .env             # same variables as the Python .env.example; optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
    extra_hosts: ["host.docker.internal:host-gateway"]

  test:
    build: { context: ../.., dockerfile: 16-fine-tuning/csharp/Dockerfile, target: test }
    profiles: [test]           # only runs when asked for by name
```

```powershell
cd projects/16-fine-tuning/csharp
docker compose run --rm test                              # dotnet test
# The committed generations baked into the image: deterministic, no model
docker compose run --rm app compare replay:/app/fixtures/generations/base.jsonl replay:/app/fixtures/generations/tuned.jsonl
docker compose run --rm app compare model:ft-base model:ft-tuned    # native Ollama on the host
```

## Cross-check the two

Two levels, and they mean different things.

**Exact, on the stub: runnable now.** Record one file from each language on module 04's stub, then have both languages score both files. From `projects/16-fine-tuning`:

```powershell
$env:FIXTURES_DIR = "$PWD/fixtures"
$env:LLM_BACKEND = 'stub'
$gen = "$PWD/outputs/stub-generations"      # outputs/ is git-ignored: these aren't evidence

$env:LLM_STUB_REPLY = '{"items":[{"qty":1,"item":"red mug"}]}'
uv run --directory python python -m ft.cli record model:ft-base $gen/base.jsonl 2> $null
Remove-Item Env:LLM_STUB_REPLY
dotnet run --project csharp/src/FineTuning -- record model:ft-tuned $gen/tuned.jsonl 2> $null

uv run --directory python python -m ft.cli compare replay:$gen/base.jsonl replay:$gen/tuned.jsonl > py.out
dotnet run --project csharp/src/FineTuning -- compare replay:$gen/base.jsonl replay:$gen/tuned.jsonl > cs.out
Compare-Object (Get-Content py.out) (Get-Content cs.out)    # no output = identical
```

Both print the table below and exit 1 (the "tuned" stub never emits JSON, so the gate fails), and `Compare-Object` prints nothing:

```
metric                base   tuned   delta
json_valid_rate      1.000   0.000  -1.000
schema_ok_rate       1.000   0.000  -1.000
```

**Exact, on real generations.** Run the same two `compare replay:...` commands against `fixtures/generations/base.jsonl` and `tuned.jsonl`. The tolerance is zero: both rates must match to the printed precision. They're counts over the same strings, divided by the same `n`, so a mismatch is never noise. It means the two validators disagree about some output. Find the line, add it to both schema tables (`test_classifies_output` and `OrderSchemaTests`), and fix the C# side.

**Approximate, live.** Run `compare model:ft-base model:ft-tuned` from both languages with `LLM_BACKEND=ollama`. Expect close numbers, not identical ones. `temperature 0` reduces variance but doesn't remove it (module 03), and the two clients call different endpoints: module 04's Python client uses Ollama's OpenAI-compatible `/v1/chat/completions`, and OllamaSharp uses the native `/api/chat`. If live numbers differ a lot but replayed numbers match, the difference is in how the model was *called*, not how it was *scored*. Check the system prompt, the template and the options.

**Exercise: the general-capability probe.** Neither side checks the second evaluation question yet: did the fine-tune make the model worse at everything else? Add `fixtures/general.jsonl`, about 20 short prompts outside the task, each with an `expect` substring (`{"prompt": "What is 7 times 6?", "expect": "42"}`). Add a `general_rate` (the share of outputs that contain `expect`) to both scorecards, and extend the gate so the tuned rate may drop at most 0.05 below base. Acceptance test, on both sides: a fake tuned model that answers every prompt with order JSON scores 0 on the probe and fails the gate. Then extend `record` and the cross-check to the probe file, so the catastrophic-forgetting check gets the same exact comparison.

| Concern | Python | C# / .NET |
|---|---|---|
| Training | PEFT + TRL + `transformers` (the `train` extra) | none; consume the exported model |
| Export / hand-off | `merge_and_unload()`, llama.cpp → GGUF | Ollama Modelfile; optionally ONNX Runtime GenAI or LLamaSharp |
| Calling the model | module 04's `LlmClient` behind an async `GenerateFn` | module 04's `IChatClient` behind an async `GenerateAsync` delegate |
| JSON validity | `json.loads` | `JsonDocument.Parse` in try/catch |
| Schema check | pydantic, lax mode, implicit | explicit `JsonDocument` walk written to pydantic's rules |
| Empty eval set | `ValueError` | `ArgumentException`, same message |
| Ship gate | exit code 1 from `compare` | exit code 1 from `compare` |
| Tests | pytest with fake `generate` and the stub | NUnit with fake delegates and the stub |

## Moving to AWS

Generic and durable (verify exact shapes in current AWS docs — these services change often):

- **SageMaker fine-tuning / training jobs** — hand SageMaker your `finetune.py`, a dataset in S3, and a GPU instance type; it runs the job, saves the adapter to S3, and releases the GPU. The managed way to fine-tune without babysitting a GPU box, and it handles the "release the expensive instance when done" discipline for you.
- **Bedrock custom models** — for hosted base models, Bedrock offers managed fine-tuning/customization: you provide a formatted dataset in S3, it produces a customized model you invoke through the same Bedrock API you used in module 12 — no training infrastructure to run yourself. The trade-off is less control and provider lock-in for far less operational burden.
- **Serving the result** — a merged model or base+adapter serves via SageMaker endpoints or a GPU ECS task, exactly like module 10/12 serving with different weights. Small adapters mean you can host one base and swap adapters cheaply.
- **The C# harness in the pipeline** — the `fine-tuning-cs` image runs as a CI step or a short ECS task after training, with `compare` exit code as the deploy gate. For a Bedrock custom model, add `bedrock` to `Backends.Supported` (and to `BACKENDS` in `generators.py`): module 12 adds that backend to module 04's library, so nothing else in the harness changes. Custom models are invoked by ARN rather than a catalog model ID, so check the current Bedrock docs for how to call them.

The senior call: prefer the **most managed option that meets the need**. Bedrock customization if it supports your base and you want zero infra; SageMaker if you need control over the training; a plain GPU box only when you have a reason. And in every case, the **eval scorecard is what authorizes the deploy** — same gate as anywhere else.

## How experts think / pitfalls

- **"Should this be RAG?" — ask it every single time.** The most expensive fine-tuning mistake is fine-tuning knowledge that belonged in retrieval. Knowledge → RAG; behavior → fine-tune. If you're unsure, it's probably RAG.
- **Prompt first, always.** Spend an hour on the prompt and two examples before spending a day on a fine-tune. You'll often not need the fine-tune.
- **No eval, no fine-tune.** Build the base-vs-tuned scorecard *before* you train. Without it you're guessing, and you can't detect regressions.
- **Check for catastrophic forgetting.** Better on your task but dumber at everything else is a real and common outcome. Keep a general-capability probe in the scorecard (this project's is the exercise in the cross-check section).
- **Match training and serving format exactly.** Same chat template, same system prompt, same structure. A format mismatch silently tanks results and is maddening to debug.
- **Curate, don't accumulate.** A few hundred clean examples > tens of thousands of messy ones. Every inconsistent example teaches the model an inconsistency.
- **Small base first.** Prove the pipeline and the eval on a tiny model that trains in minutes before scaling up. Fast iteration loops beat big ambitious runs you can't debug.
- **Version adapters and datasets together.** The adapter is only meaningful with its base and its data. Track all three; treat the adapter like a build artifact tied to a specific dataset version.
- **Compare like with like.** Export base and tuned through the same merge, conversion and quantization. A q4 library base against your q8 tuned model measures quantization as much as fine-tuning.
- **Let each language do its half.** Train in Python, consume and gate in whatever your product runs on. A home-grown .NET training loop is a project of its own, and it won't teach you more about fine-tuning than the Python one does.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Reward hacking, caused by you:** check whether your fine-tune games its own metric. JSON-valid rate is easy to max out with valid but empty or default-filled JSON. Sample outputs by hand and add a content-correctness check next to the schema check.
- **Held-out:** confirm the evaluation set was never in the training data, with a test rather than a glance (`test_no_eval_order_appears_in_train`). That's the same held-out discipline as the track's gameable-tests lab. An agent asked to "make the dataset bigger" will happily draw more rows from the same generator and reintroduce the overlap.
- **C#-specific watch:** agents tend to invent a .NET training path (a "LoRA trainer" in `Microsoft.ML` or TorchSharp that doesn't exist). Reject it and keep training in Python. Watch the schema check too. An agent will happily replace `OrderSchema` with `JsonSerializer.Deserialize<Order>`, which turns a missing `qty` into `0` and quietly inflates the schema-ok rate. The `OrderSchemaTests` table and the replay cross-check are what catch it. Expect it to `new OllamaApiClient(...)` in `Backends` instead of going through `AddLlmClient`, which silently drops the stub, the fail-loud backend check and the cost log. `Microsoft.ML.OnnxRuntimeGenAI` and OllamaSharp have both renamed APIs between releases, so check any generated call against the current package. On the Python side, watch for `torch_dtype=` and `tokenizer=` in training code: both are the pre-2025 spellings.

## Checkpoint

You're ready for module 17 when you can, without looking things up:

- State the four-lever framework and, given a scenario, pick prompting / RAG / fine-tuning / classical ML with a reason.
- Explain crisply why fine-tuning is for behavior, not knowledge, and give an example of each and which lever it needs.
- Explain LoRA and QLoRA in plain language and why they're cheap, without deriving the math.
- Describe how to format and split an instruction/chat dataset, and why quality beats quantity.
- Design a base-vs-tuned evaluation that measures both improvement *and* regression (catastrophic forgetting).
- Describe two ways to serve a fine-tuned model (adapter vs merged) and the trade-off.
- List three situations where fine-tuning is *not* worth it.
- Show that no eval order is in the training data (`uv run pytest tests/test_make_data.py`), and say why a shared generator breaks that by default.
- Run the project's pipeline: `ft.make_data`, the LoRA train (`ft.finetune`, on a GPU, Colab or CPU), and a base-vs-tuned scorecard with `python -m ft.cli compare` (on the stub with no GPU, against `ft-base` / `ft-tuned` once trained).
- Export a tuned model so .NET can call it, register base and tuned with Ollama, and explain why the base goes through the same export.
- Record both models' outputs to `fixtures/generations/` and produce identical scorecards from Python and C# on them (and on the stub cross-check), and explain why live runs only agree approximately.


## Going deeper

Search terms and topics when you want more (verify against current docs — this area moves fast):

- "Hugging Face PEFT" and "LoRA paper (Hu et al.)" — the library and the original idea; the paper's abstract is enough for intuition.
- "QLoRA paper" and "bitsandbytes 4-bit" — how quantization lets you fine-tune bigger models on smaller GPUs.
- "TRL SFTTrainer" and "chat templates" — the supervised fine-tuning trainer and why the exact template matters.
- "catastrophic forgetting" — the regression failure mode and mitigations.
- "instruction tuning datasets" — how good fine-tuning datasets are constructed and curated.
- "Amazon Bedrock model customization" and "SageMaker JumpStart fine-tuning" — the managed AWS paths.
- "DPO / preference tuning" — the next step beyond supervised fine-tuning (aligning to preferences), when you're curious.
- "Ollama import" and "Ollama Modelfile ADAPTER": which architectures Ollama imports from safetensors, and how it attaches LoRA adapters without a merge.
- "ONNX Runtime GenAI C#" and "LLamaSharp": running a merged model in-process in .NET, as ONNX or GGUF. Both APIs move fast.
- "Microsoft.Extensions.AI.Evaluation": Microsoft's evaluation libraries on top of `IChatClient`. Compare them with the hand-rolled harness here.

The math you *could* learn but don't need to ship: low-rank matrix decomposition behind LoRA, the quantization schemes behind QLoRA, the loss used in preference tuning. Name them, trust the libraries, evaluate the result.

*Last verified: 2026-10-05. Built: Python (pytest 25 passed, pyright clean on everything but the train-only imports) and C# (dotnet test 21 passed) in a throwaway build against module 04's client; `uv lock` resolves the train extra with the per-platform torch index (2.14.1+cu130 on Windows, +cpu elsewhere); the stub cross-check (record in each language, compare replays in both) matches exactly; compose files validated with `docker compose config`. Read-only: LoRA training, `export.py`, the llama.cpp conversion, `ollama create` and every live-model run (no GPU training per ADR-004, no live Ollama), and the Docker images. The `dtype` and `processing_class` names were checked against the installed transformers 5.18 and trl 1.14 sources, not run.*

**Verify on first build:** that `finetune.py` trains on your trl version without extra `SFTConfig` settings (trl 1.x defaults `gradient_checkpointing` and `bf16` differently from `TrainingArguments`); llama.cpp's converter script name and `requirements/requirements-convert_hf_to_gguf.txt` path; that `convert_hf_to_gguf.py` supports your base architecture and `--outtype q8_0`; that `ollama show --modelfile ft-tuned` shows the model's chat template; that the `cu130` index has a wheel for your driver (`torch.cuda.is_available()` prints `True`).

Next: [17 — Capstone & portfolio](17-capstone-and-portfolio.md).
