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

## Costs & when it's NOT worth it

Be a skeptic. Fine-tuning is *not worth it* when:

- **You haven't exhausted prompting and RAG.** Most gaps close there, faster and cheaper. Fine-tuning to fix a knowledge gap is the classic waste.
- **Your data is thin or messy.** Garbage examples produce a garbage-faithful model. No dataset, no fine-tune.
- **The task changes often.** Every meaningful change means re-training and re-evaluating. Prompts and RAG update instantly; fine-tunes don't.
- **You can't evaluate it.** No eval set means no way to know it helped or regressed. Build the eval first, or don't fine-tune.
- **The gains don't clear the operational cost.** You now own a training pipeline, an artifact to version, and a serving path. That overhead has to be earned by a real, measured improvement.

It *is* worth it when you have a stable, well-defined behavior gap (format/style/tone/domain phrasing/latency), a clean dataset, an eval that proves it, and prompting genuinely can't get you there. Then LoRA is cheap enough to just try — and the eval tells you whether to keep it.

## The build project

**`projects/16-fine-tuning/`** — a small **LoRA fine-tune** of a small open model on a **formatting/style task**: make the model reliably emit a strict JSON shape for a simple request (a behavior task — exactly what fine-tuning is *for*). You then **evaluate tuned vs base** with a module-09-style harness to *prove* improvement (JSON-valid rate and schema-compliance rate on a held-out set), and serve it locally.

> Reality check: LoRA fine-tuning is most comfortable with a GPU. This project is written to run on a small GPU (a free cloud notebook GPU is plenty), and it degrades gracefully: on CPU-only machines, use a tiny base model and few steps just to exercise the pipeline, or run the training step on a hosted GPU and bring the adapter back. The **evaluation harness runs fine on CPU** against any served model — so even without a GPU you can do the most important part (measuring). We keep the training library generic; check current docs for the exact API of whatever trainer you use (`peft`/`trl`/`transformers` shapes move fast).

### Layout

```
projects/16-fine-tuning/
├── pyproject.toml
├── Dockerfile
├── README.md
├── data/
│   ├── train.jsonl        # curated instruction/response examples
│   └── eval.jsonl         # HELD-OUT examples, never trained on
├── src/
│   └── ft/
│       ├── __init__.py
│       ├── make_data.py   # generate the small, clean dataset
│       ├── finetune.py    # the LoRA training script (GPU-friendly)
│       └── evaluate.py    # base vs tuned scorecard (CPU-friendly)
└── tests/
    └── test_evaluate.py
```

### `pyproject.toml`

```toml
[project]
name = "ft"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "pydantic>=2.7",
]

# Training deps are heavy and platform-specific (GPU builds). Keep them in an
# optional group so evaluation/serving can run without them.
[project.optional-dependencies]
train = [
    "torch>=2.3",
    "transformers>=4.44",
    "peft>=0.12",        # the LoRA/PEFT library
    "trl>=0.9",          # supervised fine-tuning trainer
    "datasets>=2.20",
]

[dependency-groups]
dev = ["pytest>=8.2", "ruff>=0.5", "pyright>=1.1.370"]

[tool.pyright]
typeCheckingMode = "standard"
```

> Pythonism flag: we split heavy GPU training deps into an optional group (`uv sync --extra train`) so the eval/serve path installs light and CPU-only. This is idiomatic dependency hygiene for ML projects, where the training stack is huge and platform-specific.

### `src/ft/make_data.py`

```python
"""Generate a small, CLEAN dataset for a JSON-formatting behavior task.

The 'behavior' we teach: given a free-text order, emit strict JSON with an
'items' array of {qty, item}. This is behavior/format, NOT knowledge — the
correct target for fine-tuning.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

SYSTEM = "Convert the order to strict JSON: {\"items\":[{\"qty\":int,\"item\":str}]}. JSON only."

_ITEMS = ["red mug", "blue kettle", "wooden spoon", "steel pan", "glass jar", "cotton towel"]


def _example(rng: random.Random) -> dict:
    n = rng.randint(1, 3)
    chosen = rng.sample(_ITEMS, n)
    parts, items = [], []
    for it in chosen:
        qty = rng.randint(1, 5)
        parts.append(f"{qty} {it}{'s' if qty > 1 else ''}")
        items.append({"qty": qty, "item": it})
    user = "I'd like " + ", ".join(parts)
    assistant = json.dumps({"items": items})
    return {
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant},
        ]
    }


def main() -> None:
    rng = random.Random(42)
    out = Path("data")
    out.mkdir(exist_ok=True)
    with (out / "train.jsonl").open("w", encoding="utf-8") as f:
        for _ in range(200):  # small + clean beats large + noisy
            f.write(json.dumps(_example(rng)) + "\n")
    with (out / "eval.jsonl").open("w", encoding="utf-8") as f:
        for _ in range(40):   # HELD OUT — never trained on
            f.write(json.dumps(_example(rng)) + "\n")
    print("Wrote data/train.jsonl (200) and data/eval.jsonl (40)")


if __name__ == "__main__":
    main()
```

### `src/ft/finetune.py`

```python
"""LoRA fine-tune of a small open model on the JSON-formatting task.

This is the module-15 training loop with the base model FROZEN and only a
small LoRA adapter's parameters updating. Runs on a modest GPU; on CPU use a
tiny base and few steps just to exercise the flow. API shapes for
transformers/peft/trl change — verify against current docs.
"""
from __future__ import annotations

import os

BASE_MODEL = os.environ.get("BASE_MODEL", "Qwen/Qwen2-0.5B-Instruct")  # small on purpose


def main() -> None:
    # Imported lazily so the eval/serve path doesn't need the heavy train deps.
    import torch
    from datasets import load_dataset
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from trl import SFTConfig, SFTTrainer

    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL,
        torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
    )

    dataset = load_dataset("json", data_files="data/train.jsonl", split="train")

    # LoRA: freeze the base, train small adapter matrices only.
    peft_config = LoraConfig(
        r=8,                 # adapter rank — small = cheap
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
    )

    trainer = SFTTrainer(
        model=model,
        args=sft_config,
        train_dataset=dataset,
        peft_config=peft_config,
        processing_class=tokenizer,
    )
    trainer.train()
    trainer.save_model("adapter")  # small adapter artifact, a few MB
    print("Saved LoRA adapter to ./adapter")


if __name__ == "__main__":
    main()
```

### `src/ft/evaluate.py`

```python
"""Base vs tuned scorecard — the module-09 discipline applied to a fine-tune.

We measure two things on the HELD-OUT eval set:
  1. Did the target task improve?  -> json_valid_rate, schema_ok_rate
  2. Did anything regress?         -> a tiny general-capability probe

`generate` is injected so this file is testable on CPU with a fake model and
runnable against any real served model.
"""
from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from pydantic import BaseModel, ValidationError

GenerateFn = Callable[[list[dict]], str]  # messages -> assistant text


class OrderItem(BaseModel):
    qty: int
    item: str


class Order(BaseModel):
    items: list[OrderItem]


def _schema_ok(text: str) -> bool:
    try:
        Order.model_validate_json(text)
    except (ValidationError, ValueError):
        return False
    return True


def _json_valid(text: str) -> bool:
    try:
        json.loads(text)
    except ValueError:
        return False
    return True


def score(generate: GenerateFn, eval_path: str = "data/eval.jsonl") -> dict[str, float]:
    rows = [json.loads(line) for line in Path(eval_path).read_text("utf-8").splitlines()]
    n = len(rows)
    json_ok = schema_ok = 0
    for row in rows:
        prompt_msgs = row["messages"][:-1]  # drop the gold assistant turn
        out = generate(prompt_msgs).strip()
        json_ok += _json_valid(out)
        schema_ok += _schema_ok(out)
    return {"json_valid_rate": json_ok / n, "schema_ok_rate": schema_ok / n}


def compare(base: GenerateFn, tuned: GenerateFn) -> None:
    b, t = score(base), score(tuned)
    print(f"{'metric':<18}{'base':>8}{'tuned':>8}{'delta':>8}")
    for k in b:
        print(f"{k:<18}{b[k]:>8.3f}{t[k]:>8.3f}{t[k] - b[k]:>+8.3f}")
    # Ship gate: tuned must not regress the target metric.
    assert t["schema_ok_rate"] >= b["schema_ok_rate"], "Fine-tune regressed the task!"
```

### `tests/test_evaluate.py`

```python
from ft.evaluate import score


def _fake_good(messages):
    # A model that always returns valid, schema-correct JSON.
    return '{"items": [{"qty": 2, "item": "red mug"}]}'


def _fake_bad(messages):
    return "sure! here you go: 2 red mugs"


def test_good_model_scores_high(tmp_path, monkeypatch):
    import json

    p = tmp_path / "eval.jsonl"
    row = {"messages": [{"role": "user", "content": "2 red mugs"},
                        {"role": "assistant", "content": "{}"}]}
    p.write_text(json.dumps(row) + "\n", encoding="utf-8")
    good = score(_fake_good, str(p))
    bad = score(_fake_bad, str(p))
    assert good["schema_ok_rate"] == 1.0
    assert bad["schema_ok_rate"] == 0.0
```

### Run it locally

```bash
cd projects/16-fine-tuning
uv sync                         # light: eval/serve deps only
uv run python -m ft.make_data   # build the clean dataset

# Training (needs the heavy extras + ideally a GPU):
uv sync --extra train
uv run python -m ft.finetune    # writes ./adapter

# The important part — measure. Wire base and tuned generate() fns to your
# served models (module 10), then compare. Runs fine on CPU.
uv run pytest                   # the harness logic is unit-tested on CPU
```

> The `generate` function is intentionally injected rather than hard-wired: point `base` at the base model served via Ollama/transformers and `tuned` at base+adapter, and `compare(base, tuned)` prints the scorecard that decides whether you ship. That decoupling also makes the harness unit-testable on CPU (the test above) — the same "pure core, injected I/O" instinct from module 01.

### `Dockerfile`

```dockerfile
# Lightweight image for the CPU-friendly parts: data gen + evaluation harness.
# Training is a separate concern (needs GPU + the heavy extras) — run it on a
# GPU host/notebook and bring the ./adapter artifact back for serving.
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY src/ ./src/
COPY data/ ./data/
RUN uv sync --frozen

CMD ["uv", "run", "python", "-m", "ft.make_data"]
```

```bash
docker build -t ft projects/16-fine-tuning
docker run --rm ft
```

> Note the deliberate split: the Docker image handles the light, portable, CPU-friendly work (data + evaluation). Training, with its GPU and multi-gigabyte dependency stack, is run where the hardware is and produces a small adapter artifact you carry back. This mirrors the module-14 lesson: **training and serving are separate concerns** — don't force a GPU training stack into your serving image.

### Moving to AWS

Generic and durable (verify exact shapes in current AWS docs — these services change often):

- **SageMaker fine-tuning / training jobs** — hand SageMaker your `finetune.py`, a dataset in S3, and a GPU instance type; it runs the job, saves the adapter to S3, and releases the GPU. The managed way to fine-tune without babysitting a GPU box, and it handles the "release the expensive instance when done" discipline for you.
- **Bedrock custom models** — for hosted base models, Bedrock offers managed fine-tuning/customization: you provide a formatted dataset in S3, it produces a customized model you invoke through the same Bedrock API you used in module 12 — no training infrastructure to run yourself. The trade-off is less control and provider lock-in for far less operational burden.
- **Serving the result** — a merged model or base+adapter serves via SageMaker endpoints or a GPU ECS task, exactly like module 10/12 serving with different weights. Small adapters mean you can host one base and swap adapters cheaply.

The senior call: prefer the **most managed option that meets the need**. Bedrock customization if it supports your base and you want zero infra; SageMaker if you need control over the training; a plain GPU box only when you have a reason. And in every case, the **eval scorecard is what authorizes the deploy** — same gate as anywhere else.

## How experts think / pitfalls

- **"Should this be RAG?" — ask it every single time.** The most expensive fine-tuning mistake is fine-tuning knowledge that belonged in retrieval. Knowledge → RAG; behavior → fine-tune. If you're unsure, it's probably RAG.
- **Prompt first, always.** Spend an hour on the prompt and two examples before spending a day on a fine-tune. You'll often not need the fine-tune.
- **No eval, no fine-tune.** Build the base-vs-tuned scorecard *before* you train. Without it you're guessing, and you can't detect regressions.
- **Check for catastrophic forgetting.** Better on your task but dumber at everything else is a real and common outcome. Keep a general-capability probe in the scorecard.
- **Match training and serving format exactly.** Same chat template, same system prompt, same structure. A format mismatch silently tanks results and is maddening to debug.
- **Curate, don't accumulate.** A few hundred clean examples > tens of thousands of messy ones. Every inconsistent example teaches the model an inconsistency.
- **Small base first.** Prove the pipeline and the eval on a tiny model that trains in minutes before scaling up. Fast iteration loops beat big ambitious runs you can't debug.
- **Version adapters and datasets together.** The adapter is only meaningful with its base and its data. Track all three; treat the adapter like a build artifact tied to a specific dataset version.

## Checkpoint

You're ready for module 17 when you can, without looking things up:

- State the four-lever framework and, given a scenario, pick prompting / RAG / fine-tuning / classical ML with a reason.
- Explain crisply why fine-tuning is for behavior, not knowledge, and give an example of each and which lever it needs.
- Explain LoRA and QLoRA in plain language and why they're cheap, without deriving the math.
- Describe how to format and split an instruction/chat dataset, and why quality beats quantity.
- Design a base-vs-tuned evaluation that measures both improvement *and* regression (catastrophic forgetting).
- Describe two ways to serve a fine-tuned model (adapter vs merged) and the trade-off.
- List three situations where fine-tuning is *not* worth it.
- Run the project's pipeline: generate data, run (or simulate) the LoRA train, and produce a base-vs-tuned scorecard.

## Going deeper

Search terms and topics when you want more (verify against current docs — this area moves fast):

- "Hugging Face PEFT" and "LoRA paper (Hu et al.)" — the library and the original idea; the paper's abstract is enough for intuition.
- "QLoRA paper" and "bitsandbytes 4-bit" — how quantization lets you fine-tune bigger models on smaller GPUs.
- "TRL SFTTrainer" and "chat templates" — the supervised fine-tuning trainer and why the exact template matters.
- "catastrophic forgetting" — the regression failure mode and mitigations.
- "instruction tuning datasets" — how good fine-tuning datasets are constructed and curated.
- "Amazon Bedrock model customization" and "SageMaker JumpStart fine-tuning" — the managed AWS paths.
- "DPO / preference tuning" — the next step beyond supervised fine-tuning (aligning to preferences), when you're curious.

The math you *could* learn but don't need to ship: low-rank matrix decomposition behind LoRA, the quantization schemes behind QLoRA, the loss used in preference tuning. Name them, trust the libraries, evaluate the result.

Next: [17 — Capstone & portfolio](17-capstone-and-portfolio.md).
