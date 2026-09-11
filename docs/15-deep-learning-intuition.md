# 15 — Deep learning intuition

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer, without a deep math background — and this is the module people are most afraid of. Relax: you will **not** derive backpropagation, and you never need to. The goal here is narrow and practical: be able to *read and modify a PyTorch training loop* and understand *what training actually does*, well enough to debug it and make decisions. The calculus that scares people (computing gradients) is done *for you*, automatically, by the framework — that's the entire point of these tools. This doc gives intuition and a real, explicit training loop you can run on a CPU. When a concept has heavy math under it, you get the one-sentence version and a pointer, not a derivation. You can be an excellent AI engineer and never once compute a gradient by hand.

Everything you've used so far — the LLMs in modules 03–13, the embeddings, the fine-tuned model coming in 16 — is a **neural network** being trained by a loop like the one in this doc. Understanding that loop demystifies the whole field. Once you've seen the ~15 lines at the heart of training, "deep learning" stops being magic and becomes *code you can read*, and papers and model cards start making sense.

## Where this fits

**Prerequisites:** modules 01–14. You can write typed Python (01), you understand embeddings as vectors (03) and just saw them as features (14), and you have the classical-ML workflow — split, fit, evaluate, overfitting, cross-validation — in your hands (14). Deep learning reuses *all* of those ideas; it just swaps "call `.fit()`" for "write the training loop yourself."

**After this module you can:**

- Read a PyTorch training loop and explain what every line does.
- Explain, in plain language, what training *is*: adjusting numbers to make a loss go down.
- Reason about tensors, devices (CPU/GPU), loss, gradient descent, and learning rate as an engineer, not a mathematician.
- Spot overfitting from train/validation curves and stop training at the right time.
- Understand embeddings as a *learned layer*, connecting back to modules 03 and 07.
- Explain why transformers/LLMs are this same machinery at scale.
- Decide — correctly, almost always "no" — whether to train from scratch or use a pretrained model.

## Neural nets as stacked differentiable functions

Here's the whole idea, no matrix calculus. A neural network is a **pipeline of simple functions stacked on top of each other.** Each layer takes numbers in, multiplies them by some adjustable weights, adds a bias, and passes the result through a simple non-linear squashing function (like `ReLU`, which is just `max(0, x)`). Stack a few of those, and the composition can approximate astonishingly complex input→output mappings.

The .NET analogy: it's a `Func<Tensor, Tensor>` composed of smaller `Func`s — `layer3(layer2(layer1(x)))` — except every function has **tunable parameters** (the weights), and there are millions of them. "Training" is the process of *finding good values for all those knobs* so the composed function produces the outputs you want.

The word that matters is **differentiable**. Because every layer is a smooth mathematical function, you can compute — for any weight — "if I nudge this weight up a hair, does the error get bigger or smaller, and by how much?" That derivative is the **gradient**, and it's the compass that tells training which way to turn every knob. You will never compute one by hand. The framework does it. That's *autograd*, and it's the reason PyTorch exists.

## The training loop, demystified

This is the center of the entire field. Every model — a tiny classifier, GPT-scale LLMs — is trained by some version of this loop. Read it once as pseudocode, then we'll map a real one line by line:

```
for each epoch (full pass over the data):
    for each batch (a small chunk of examples):
        1. FORWARD PASS   — run the batch through the model, get predictions
        2. LOSS           — compute a single number: how wrong were we?
        3. BACKWARD PASS  — autograd computes the gradient of the loss w.r.t. every weight
        4. OPTIMIZER STEP — nudge every weight a little in the direction that reduces loss
        5. ZERO GRADIENTS — clear the gradients before the next batch
```

That's it. That's training. Five steps in a double loop. Let's define the vocabulary through it:

- **Forward pass** — feed inputs through the stacked functions to get outputs. Just calling `model(x)`.
- **Loss** — a single number measuring how wrong the predictions are versus the true answers (cross-entropy for classification, mean-squared-error for regression). Training's only job is to make this number small. It's the objective, the score you're minimizing — the equivalent of a failing-test count you're driving to zero.
- **Backward pass (backpropagation)** — the framework walks the computation backward and computes the gradient (the "which way and how much" nudge) for every weight. **This is the calculus, and autograd does 100% of it.** The heavy math you're allowed to skip forever lives right here. You call `loss.backward()`; PyTorch fills in every gradient.
- **Optimizer step** — the optimizer (e.g. Adam, SGD) takes those gradients and actually updates the weights: `weight = weight − learning_rate × gradient`, roughly. This is **gradient descent** — repeatedly stepping downhill on the loss surface.
- **Learning rate** — how big a step to take each update. **The single most important knob.** Too big and training diverges (loss explodes to NaN); too small and it crawls or gets stuck. Intuition: the step size when walking downhill in fog.
- **Epoch** — one full pass over all the training data. **Batch** — one small chunk processed at a time (you can't fit all data in memory, and small batches train better). **Steps** — one batch = one optimizer update.

Notice how much this rhymes with module 14's workflow: you still split data, still watch a held-out score, still fight overfitting. The only new thing is that *you* write the optimization loop instead of `sklearn` hiding it. Seeing it explicitly, once, is the point of this module.

## Tensors and devices

A **tensor** is the one data structure in deep learning. Mentally: **a NumPy array that also tracks gradients and can live on a GPU.** A scalar is a 0-D tensor, a vector 1-D, a matrix 2-D, a batch of images 4-D. All your data, weights, and intermediate results are tensors.

Two properties that trip up newcomers:

- **`requires_grad`** — if a tensor has this set (weights do), PyTorch records every operation on it so it can compute gradients later. Your input data usually doesn't need it; your model's parameters do (automatically).
- **`device`** — a tensor lives on the **CPU** or a **GPU** (`cuda`). Operations require all tensors on the *same* device — a `RuntimeError: expected all tensors to be on the same device` is the #1 beginner error. You move them with `.to(device)`. GPUs matter because the core operation (big matrix multiplies) is massively parallel; a GPU does in seconds what a CPU does in minutes. For *this* module's tiny model, CPU is fine — you don't need a GPU to learn the loop.

## Overfitting, train/val curves, early stopping

Same enemy as module 14, now visible as two curves you plot every epoch:

- **Training loss** — how wrong the model is on data it's learning from. It (almost) always goes down.
- **Validation loss** — how wrong it is on held-out data it never trains on. This is the one you actually care about.

The story they tell: early on, both fall together (the model is learning real patterns). Then validation loss flattens and starts climbing back up while training loss keeps falling — that gap is **overfitting**: the model is now memorizing training noise instead of generalizing. **Early stopping** is the fix — stop training at the validation-loss minimum, before the curves diverge. It's the deep-learning version of "don't over-tune"; you watch the held-out number and quit while you're ahead. If you learn to read these two curves, you can diagnose most training problems by eye.

## Embeddings as a learned layer

Back in module 03 an embedding was a "meaningful vector for a piece of text," and in modules 07 and 14 you used those vectors for retrieval and as classifier features. Now you can see where they come from: **an embedding is just a layer in a neural net whose weights are learned by the training loop above.** An "embedding layer" is literally a lookup table (token → vector) that starts random and gets nudged, batch by batch, so that tokens used in similar ways end up with similar vectors. Nothing mystical — the same `loss.backward()` / optimizer step that tunes every other weight tunes the embedding table. That's why embeddings *mean* something: training pressured them into it.

## Why transformers/LLMs are this, at scale

An LLM is exactly this machinery — tensors, layers, a loss, a training loop — with two changes: (1) an architecture called the **transformer** whose key trick is **attention** (each token can "look at" the other tokens to decide what's relevant), and (2) *enormous* scale: billions of weights, trained on trillions of tokens across thousands of GPUs, with the loss being "predict the next token." That's the whole recipe. You don't need to derive attention to be a great AI engineer — the one-sentence intuition ("each position weighs how much every other position matters, and that weighting is itself learned") is enough to reason about context windows and cost, which you already did in module 03. The training loop is identical in spirit to the one you're about to run; only the scale and the layer design differ.

## When would you ever train from scratch? (Almost never)

Be clear-eyed: **you will almost never train a large model from scratch.** It costs millions of dollars and requires data and compute you don't have. The overwhelmingly common path is **transfer learning** — take a model someone already trained on massive data, and adapt it:

- **Use it as-is** — most of the time (all of modules 03–13).
- **Feature extraction** — freeze the pretrained model, use its outputs (embeddings) as features for a small classical model (module 14's bridge).
- **Fine-tuning** — nudge the pretrained weights on your smaller dataset (module 16, next).

You'd train from scratch only for a genuinely novel small model on proprietary data where nothing pretrained fits — rare, and a specialist task. The project below shows both: a small net trained from scratch (to *see* the loop), then transfer learning (what you'd actually do).

## The build project

**`projects/15-dl-intuition/`** — a minimal PyTorch training loop, written out **explicitly** (not hidden behind a framework), on a small dataset. You'll train a tiny classifier from scratch on scikit-learn's bundled `digits` dataset (8×8 handwritten digits — MNIST's little sibling, no download, CPU-friendly), log train/validation loss each epoch, and save a loss-curve plot. Then a second script shows **transfer learning**: reuse a pretrained feature extractor and train only a small head. Everything runs on CPU in Docker.

### Layout

```
projects/15-dl-intuition/
├── pyproject.toml
├── Dockerfile
├── README.md
├── src/
│   └── dl/
│       ├── __init__.py
│       ├── data.py          # load digits, split, make tensors + loaders
│       ├── model.py         # a tiny MLP defined explicitly
│       ├── train.py         # the explicit training loop + loss logging + plot
│       └── transfer.py      # transfer-learning demo
└── tests/
    └── test_train.py
```

### `pyproject.toml`

```toml
[project]
name = "dl"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "torch>=2.3",          # CPU build is fine for this module
    "scikit-learn>=1.5",
    "numpy>=2.0",
    "matplotlib>=3.9",
]

[dependency-groups]
dev = ["pytest>=8.2", "ruff>=0.5", "pyright>=1.1.370"]

[tool.pyright]
typeCheckingMode = "standard"
```

> Pythonism flag: `torch` is a large dependency (hundreds of MB even for the CPU build). That's normal for deep learning and part of why images get big. In real projects you pin the exact CPU or CUDA build via PyTorch's index; check current PyTorch install docs for the right index URL for your platform.

### `src/dl/data.py`

```python
"""Load the digits dataset and turn it into PyTorch tensors + loaders."""
from __future__ import annotations

import torch
from sklearn.datasets import load_digits
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from torch.utils.data import DataLoader, TensorDataset

N_FEATURES = 64   # 8x8 pixels
N_CLASSES = 10     # digits 0-9


def make_loaders(batch_size: int = 64) -> tuple[DataLoader, DataLoader]:
    data = load_digits()
    X_train, X_val, y_train, y_val = train_test_split(
        data.data, data.target, test_size=0.2, random_state=42, stratify=data.target
    )

    # Scale using TRAIN statistics only (leakage lesson from module 14).
    scaler = StandardScaler().fit(X_train)
    X_train = scaler.transform(X_train)
    X_val = scaler.transform(X_val)

    # Tensors: float32 features, int64 class labels (what cross-entropy expects).
    train_ds = TensorDataset(
        torch.tensor(X_train, dtype=torch.float32),
        torch.tensor(y_train, dtype=torch.long),
    )
    val_ds = TensorDataset(
        torch.tensor(X_val, dtype=torch.float32),
        torch.tensor(y_val, dtype=torch.long),
    )
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False)
    return train_loader, val_loader
```

### `src/dl/model.py`

```python
"""A tiny multi-layer perceptron, defined explicitly so you can see the stack."""
from __future__ import annotations

import torch
from torch import nn

from dl.data import N_CLASSES, N_FEATURES


class TinyMLP(nn.Module):
    """Three stacked differentiable functions: linear -> relu -> linear."""

    def __init__(self, hidden: int = 64) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(N_FEATURES, hidden),   # layer 1: weights + bias
            nn.ReLU(),                        # non-linear squash: max(0, x)
            nn.Linear(hidden, N_CLASSES),    # layer 2: outputs one score per class
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # This is the "forward pass": data flows through the stacked functions.
        return self.net(x)
```

### `src/dl/train.py`

```python
"""The explicit training loop. Read every line — this is the whole idea."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")  # headless backend so it works in Docker with no display
import matplotlib.pyplot as plt  # noqa: E402
import torch  # noqa: E402
from torch import nn  # noqa: E402

from dl.data import make_loaders  # noqa: E402
from dl.model import TinyMLP  # noqa: E402


def evaluate(model: nn.Module, loader, loss_fn, device: str) -> float:
    """Average loss over a loader, WITHOUT updating weights (no_grad)."""
    model.eval()
    total, n = 0.0, 0
    with torch.no_grad():  # don't track gradients: we're only measuring
        for xb, yb in loader:
            xb, yb = xb.to(device), yb.to(device)
            loss = loss_fn(model(xb), yb)
            total += loss.item() * len(xb)
            n += len(xb)
    return total / n


def train(epochs: int = 30, lr: float = 1e-3) -> tuple[list[float], list[float]]:
    device = "cuda" if torch.cuda.is_available() else "cpu"
    train_loader, val_loader = make_loaders()

    model = TinyMLP().to(device)
    loss_fn = nn.CrossEntropyLoss()                       # the number to minimize
    optimizer = torch.optim.Adam(model.parameters(), lr=lr)  # the weight updater

    train_losses: list[float] = []
    val_losses: list[float] = []

    for epoch in range(epochs):
        model.train()
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)

            optimizer.zero_grad()      # 5. clear last batch's gradients
            preds = model(xb)          # 1. FORWARD pass
            loss = loss_fn(preds, yb)  # 2. LOSS: how wrong were we?
            loss.backward()            # 3. BACKWARD pass: autograd fills gradients
            optimizer.step()           # 4. OPTIMIZER step: nudge the weights

        train_losses.append(evaluate(model, train_loader, loss_fn, device))
        val_losses.append(evaluate(model, val_loader, loss_fn, device))
        print(
            f"epoch {epoch + 1:>2}  "
            f"train_loss={train_losses[-1]:.4f}  val_loss={val_losses[-1]:.4f}"
        )

    return train_losses, val_losses


def main() -> None:
    train_losses, val_losses = train()
    plt.plot(train_losses, label="train")
    plt.plot(val_losses, label="val")
    plt.xlabel("epoch")
    plt.ylabel("loss")
    plt.legend()
    plt.title("Train vs validation loss (watch for the gap = overfitting)")
    plt.savefig("loss_curve.png", bbox_inches="tight")
    print("Wrote loss_curve.png")


if __name__ == "__main__":
    main()
```

### `src/dl/transfer.py`

```python
"""Transfer learning, the pattern you'll ACTUALLY use.

Instead of training a feature extractor from scratch, we treat a pretrained,
frozen component as a fixed feature source and train only a small head on top.
Here we simulate 'pretrained features' with sklearn's PCA to keep the example
tiny and CPU-only; the *pattern* — freeze the big pretrained part, train a
small head — is exactly what you do with a real pretrained network.
"""
from __future__ import annotations

import torch
from sklearn.datasets import load_digits
from sklearn.decomposition import PCA
from sklearn.model_selection import train_test_split
from torch import nn


def main() -> None:
    data = load_digits()

    # "Pretrained feature extractor" (frozen): fit once, then only transform.
    extractor = PCA(n_components=20, random_state=0).fit(data.data)
    features = extractor.transform(data.data)  # frozen: no gradients flow here

    X_train, X_val, y_train, y_val = train_test_split(
        features, data.target, test_size=0.2, random_state=42, stratify=data.target
    )
    xt = torch.tensor(X_train, dtype=torch.float32)
    yt = torch.tensor(y_train, dtype=torch.long)
    xv = torch.tensor(X_val, dtype=torch.float32)
    yv = torch.tensor(y_val, dtype=torch.long)

    # We train ONLY this small head. Far fewer parameters, far faster.
    head = nn.Linear(20, 10)
    loss_fn = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(head.parameters(), lr=1e-2)

    for epoch in range(50):
        head.train()
        optimizer.zero_grad()
        loss = loss_fn(head(xt), yt)
        loss.backward()
        optimizer.step()

    head.eval()
    with torch.no_grad():
        acc = (head(xv).argmax(dim=1) == yv).float().mean().item()
    print(f"Transfer-learning head validation accuracy: {acc:.3f}")


if __name__ == "__main__":
    main()
```

### `tests/test_train.py`

```python
from dl.train import train


def test_training_reduces_loss() -> None:
    # The core promise of the loop: loss should go DOWN over training.
    train_losses, val_losses = train(epochs=5)
    assert train_losses[-1] < train_losses[0]
    # And the model should be learning something real, not just memorizing.
    assert val_losses[-1] < 1.0
```

### Run it locally

```bash
cd projects/15-dl-intuition
uv sync
uv run python -m dl.train        # prints per-epoch losses, writes loss_curve.png
uv run python -m dl.transfer     # prints transfer-learning accuracy
uv run pytest
```

Open `loss_curve.png` and *look at it*. Watch train loss fall smoothly; watch whether validation loss keeps pace or starts pulling away. That gap, drawn, is the whole overfitting lesson made visible.

### `Dockerfile`

```dockerfile
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY src/ ./src/
RUN uv sync --frozen

# Runs the explicit training loop on CPU and writes loss_curve.png.
CMD ["uv", "run", "python", "-m", "dl.train"]
```

```bash
docker build -t dl projects/15-dl-intuition
docker run --rm dl
```

> The image is large because `torch` is large. That's expected for deep learning. For CPU-only serving you can shrink it substantially by installing the CPU-only PyTorch build from PyTorch's dedicated index — check current PyTorch install docs for the exact index URL.

### Moving to AWS

The honest version, which is more reassuring than beginners expect:

- **You rarely need a GPU early.** Everything in this module runs fine on a CPU. Fine-tuning small models (module 16) and full training are where GPUs earn their cost. Don't rent a GPU to learn the loop.
- **When you do need training compute:** GPU EC2 instances (the `g` and `p` families) give you raw machines; **SageMaker Training** gives you managed jobs where you hand it your `train.py` and a data location and it spins up the GPU, runs, saves the artifact to S3, and tears the instance down — so you don't leave an expensive GPU idling (a classic way to burn money). SageMaker also handles distributed multi-GPU training when a model outgrows one card.
- **Serving:** a trained model is just weights. Small models serve on CPU containers exactly like module 14; only large models need GPU inference (SageMaker real-time endpoints or a GPU ECS task). Match the hardware to the model size, not to the word "AI."

The senior habit: **treat GPUs like any expensive, metered resource** — provision them for a job, watch the meter, release them. A forgotten running GPU instance is the deep-learning equivalent of a leaked connection pool, except it costs dollars an hour. (Module 13's cost discipline applies directly. Verify current instance families and SageMaker specifics in AWS docs.)

## How experts think / pitfalls

- **You don't understand a model until you've watched its loss curve.** Print/plot train and val loss every run. Loss not going down → learning rate wrong, data mislabeled, or a bug. It's your `console.log` for training.
- **Learning rate is the first knob to touch.** Loss is NaN or exploding → lower it. Loss barely moves → raise it (or train longer). Most "the model won't learn" problems are learning rate.
- **`optimizer.zero_grad()` is not optional.** PyTorch *accumulates* gradients by default; forget to clear them and each batch is polluted by the last. A silent, classic bug — there's a reason it's step 5 in every loop.
- **`model.train()` vs `model.eval()`.** Some layers (dropout, batch-norm) behave differently in training vs inference. Forgetting `eval()` at inference gives subtly wrong, noisy results. Also wrap evaluation in `torch.no_grad()` — it's faster and makes intent clear.
- **Device mismatches are the top runtime error.** Model and data must be on the same device. Move both with `.to(device)` and define `device` once.
- **Don't train from scratch to feel legitimate.** Reaching for a pretrained model isn't cutting corners; it's the professional default. Training from scratch is the exception you justify, not the norm you prove yourself with.
- **Set seeds, but expect wobble.** `torch.manual_seed(...)` helps reproducibility, but GPU nondeterminism and library versions mean exact numbers vary. Assert quality floors in tests, not exact values (same lesson as module 14).

## Checkpoint

You're ready for module 16 when you can, without looking things up:

- Recite the five steps of a training loop and say what each does — and explain that `loss.backward()` is where the calculus happens and that autograd does it for you.
- Explain what a tensor is versus a NumPy array, and why device placement matters.
- Explain loss, gradient descent, and learning rate in plain language, and say what you'd change if loss exploded or wouldn't move.
- Read a train/validation loss plot and point to where overfitting begins and where you'd early-stop.
- Explain what an embedding layer is and how it connects to modules 03 and 07.
- Explain, in one or two sentences, why an LLM is "the same machinery at scale" without deriving attention.
- Argue why you'd use a pretrained model rather than train from scratch, and name the three transfer-learning options.
- Modify the project's loop: change the learning rate or hidden size and predict the effect on the curves before running.

## Going deeper

Search terms and topics when you want more (verify against current docs):

- "PyTorch 60 Minute Blitz" and "PyTorch tutorials" — the official on-ramp; the autograd tutorial is worth doing once.
- "Andrej Karpathy — Neural Networks: Zero to Hero" — builds autograd and a small language model from scratch; the single best intuition-builder if you want to go one level deeper without heavy math.
- "3Blue1Brown neural networks" — the visual intuition for what gradients and layers do, if you're a visual learner.
- "The Illustrated Transformer" (Jay Alammar) — attention explained with pictures, when you're curious how LLMs differ from the MLP here.
- "PyTorch learning rate scheduler" and "early stopping" — the standard tools for the training-dynamics problems above.
- "cross-entropy loss intuition" — the one bit of loss-function math worth the one-paragraph version.

The math you *could* learn but don't need to ship: backpropagation and the chain rule, the derivation of attention, optimizer internals (Adam's moment estimates). Name them, trust autograd, move on.

Next: [16 — Fine-tuning & adaptation](16-fine-tuning-and-adaptation.md).
