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
- Write the same training loop in C# with TorchSharp, map it line by line to the PyTorch one, and manage native tensor memory with dispose scopes.

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

One more property shows up only in .NET. In **TorchSharp** (the C# binding you'll use in the build), a tensor is a thin handle to native memory owned by libtorch, the same C++ engine under PyTorch. Python frees a tensor the moment its last reference goes away (reference counting). The .NET GC runs when *it* decides to, and it can't see how much native memory each small handle is holding. A loop that creates tensors every batch can run out of memory before the GC notices. TorchSharp's answer is the **dispose scope**: `using var scope = torch.NewDisposeScope();` frees every tensor created inside it when the scope ends. It's `IDisposable` discipline, applied per batch.

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

You build it twice: PyTorch first, then C# with **TorchSharp**. TorchSharp is a .NET binding over libtorch, the same native engine PyTorch runs on, and its API deliberately copies PyTorch's names (`nn.Module`, `zero_grad()`, `backward()`, `step()`). That makes this the module where a line-by-line comparison is the point. Both versions:

1. Train the same tiny MLP on the same digits split, with the same five-step loop, and print train/val loss per epoch.
2. Write the loss curve to disk.
3. Train only a small head on frozen "pretrained" (PCA, fitted on the training rows only) features and print its validation accuracy.

`digits` is bundled with scikit-learn, not with anything in .NET, so the Python side exports the split (and the PCA features) to CSV for the C# side, the same approach as module 14.

### Layout

```
projects/15-dl-intuition/
├── fixtures/                        # committed: written once by the Python exporter (FIXTURES_DIR)
│   ├── digits_train.csv
│   ├── digits_val.csv
│   ├── digits_pca_train.csv
│   └── digits_pca_val.csv
├── python/
│   ├── pyproject.toml
│   ├── uv.lock                     # committed: pins torch to the CPU index
│   ├── Dockerfile                  # build context: python/
│   ├── Dockerfile.dockerignore     # from the scaffold
│   ├── README.md
│   ├── src/
│   │   └── dl/
│   │       ├── __init__.py
│   │       ├── dataset.py          # the split + frozen PCA features (numpy/sklearn, no torch)
│   │       ├── data.py             # tensors + loaders
│   │       ├── model.py            # a tiny MLP defined explicitly
│   │       ├── train.py            # the explicit training loop + loss logging + plot
│   │       ├── transfer.py         # transfer-learning demo
│   │       └── export_fixtures.py  # writes the split + PCA features to ../fixtures/
│   └── tests/
│       ├── test_dataset.py
│       └── test_train.py
└── csharp/
    ├── DlIntuition.slnx
    ├── Directory.Build.props        # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                   # build context: the project root (for fixtures/)
    ├── Dockerfile.dockerignore      # from the scaffold; applies whatever the context
    ├── .vscode/settings.json
    ├── README.md
    ├── src/
    │   └── DlIntuition/
    │       ├── DlIntuition.csproj
    │       ├── Fixtures.cs          # module 14's walker: FIXTURES_DIR, else ../fixtures beside the .slnx
    │       ├── Digits.cs            # CSV -> arrays -> tensors
    │       ├── Standardizer.cs      # StandardScaler, by hand
    │       ├── TinyMlp.cs
    │       ├── Trainer.cs           # the explicit training loop
    │       ├── Transfer.cs
    │       ├── LossCurve.cs         # CSV + PNG
    │       └── Program.cs
    └── tests/
        └── DlIntuition.Tests/
            ├── DlIntuition.Tests.csproj    # NUnit
            ├── SmokeTests.cs               # from the bootstrap script; delete once real tests exist
            ├── StandardizerTests.cs
            └── TrainingTests.cs
```

The four CSVs are committed in the shared `fixtures/` folder (the repo `.gitignore` ignores `*.csv` everywhere else). Both languages find it through `FIXTURES_DIR`: the Python exporter writes there, and the C# side reads from there. Unset, Python uses `../fixtures` relative to `python/`, and C# walks up from its bin folder to the `.slnx` and takes `../fixtures`, the same `Fixtures.cs` as module 14. Inside the C# container it's `/app/fixtures`.

The Python image doesn't read the CSVs (`load_digits()` is bundled), so it builds from `python/`. The C# image builds with the project root as context, so it can copy `fixtures/`. Each Dockerfile has the scaffold's `Dockerfile.dockerignore` beside it, which BuildKit uses whatever the context ([conventions](conventions.md#docker)).

## Python implementation

Work in `projects/15-dl-intuition/python/`. Scaffold it with `pwsh ./scripts/new-python-project.ps1 -ProjectName 15-dl-intuition`. The script names the package `dl_intuition`, and this doc uses the shorter `dl`, so rename `src/dl_intuition/` to `src/dl/`, empty its `__init__.py`, delete `tests/test_smoke.py`, and use the `pyproject.toml` below.

### `pyproject.toml`

```toml
# projects/15-dl-intuition/python/pyproject.toml
[project]
name = "dl"
version = "0.1.0"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "torch>=2.3",          # direct, so the [tool.uv.sources] pin below applies to it
    "scikit-learn>=1.5",
    "numpy>=2.0",
    "matplotlib>=3.9",
]

[dependency-groups]
dev = ["pytest>=8.2", "ruff>=0.5", "pyright>=1.1.370"]

# Keep the scaffold's build system. Without it uv treats the project as virtual and never
# installs `dl`, so `python -m dl.train` and pytest can't import it. Match the range to your uv.
[build-system]
requires = ["uv_build>=0.10.9,<0.11.0"]
build-backend = "uv_build"

# CPU-only torch on every platform. From plain PyPI, Linux gets the CUDA build (GBs of nvidia-*
# packages in the image) and Windows gets CPU anyway. See docs/conventions.md#pytorch-wheels.
[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true    # only packages pinned below come from here; everything else from PyPI

[tool.uv.sources]
torch = [{ index = "pytorch-cpu" }]
```

Two things here are about torch wheels, and they're the [PyTorch-wheels convention](conventions.md#pytorch-wheels) in practice:

- **The CPU index.** On PyPI, `torch` for Linux is the CUDA build, which drags in several GB of `nvidia-*` packages, and that lands in your Docker image. The `pytorch-cpu` index serves CPU-only wheels for every platform. `explicit = true` means only the packages pinned in `[tool.uv.sources]` come from it; everything else still comes from PyPI.
- **torch is a direct dependency.** `[tool.uv.sources]` only applies to direct dependencies. In later modules, where torch arrives through sentence-transformers or transformers, list it anyway, or the pin is silently ignored.

Check the lock after `uv lock`. Every torch entry should name the CPU index, and there should be no `nvidia-*` packages:

```powershell
Select-String -Path uv.lock -Pattern 'name = "torch"' -Context 0,2   # source = { registry = "https://download.pytorch.org/whl/cpu" }
(Select-String -Path uv.lock -Pattern 'name = "nvidia').Count       # 0
```

(*bash / WSL / Git Bash*: `grep -A2 'name = "torch"' uv.lock` and `grep -c 'name = "nvidia' uv.lock`.) When this was built it resolved `torch 2.14.1+cpu` for Linux and Windows and `2.14.1` for macOS (whose PyPI-style wheel is already CPU/Metal), all from `download.pytorch.org/whl/cpu`.

**Windows with an NVIDIA GPU** (optional; this module doesn't need it): keep the CPU index for the Docker image and give Windows the CUDA build with a per-platform source. Replace the index and sources blocks with:

```toml
[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[[tool.uv.index]]
name = "pytorch-cu130"
url = "https://download.pytorch.org/whl/cu130"
explicit = true

[tool.uv.sources]
torch = [
    { index = "pytorch-cu130", marker = "sys_platform == 'win32'" },   # your NVIDIA GPU, natively
    { index = "pytorch-cpu", marker = "sys_platform != 'win32'" },     # the Linux image stays CPU-only
]
```

Use the CUDA URL PyTorch's install page gives for your driver (`cu130` resolved `torch 2.14.1+cu130` here; `cu128` only went up to 2.11 on Windows). `uv run python -c "import torch; print(torch.__version__, torch.cuda.is_available())"` should then print `2.14.1+cu130 True`. Module 16 uses the same form.

> Pythonism flag: even the CPU build of `torch` is large (hundreds of MB installed). That's normal for deep learning and the main reason these images are big.

### `src/dl/dataset.py`

The split and the "pretrained" features live in one torch-free module. `data.py`, `transfer.py` and the exporter all call it, so the C# side gets exactly the rows Python trains on, and the data contract can be tested without loading torch.

```python
# src/dl/dataset.py
"""The digits split and the frozen "pretrained" features. numpy and sklearn only, no torch.

data.py, transfer.py and export_fixtures.py all call these, so the split lives in one place
and the C# side gets exactly the rows Python trains on.
"""
from __future__ import annotations

import numpy as np
from sklearn.datasets import load_digits
from sklearn.decomposition import PCA
from sklearn.model_selection import train_test_split

N_FEATURES = 64    # 8x8 pixels
N_CLASSES = 10     # digits 0-9
N_COMPONENTS = 20  # size of the "pretrained" feature vector


def split_digits() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Raw pixels, split 80/20. stratify keeps all ten digits in the same proportions."""
    X, y = load_digits(return_X_y=True)
    X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)
    # sklearn's stubs say each part might be a list; for ndarray input it's an ndarray.
    return X_train, X_val, y_train, y_val  # pyright: ignore[reportReturnType]


def pca_features(X_train: np.ndarray, X_val: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """A stand-in for a frozen pretrained extractor, fitted on the TRAIN rows only.

    A real pretrained network learned from other data, so it has never seen your validation
    rows. Fitting PCA on all rows would let the stand-in peek at them: module 14's leakage bug.
    """
    extractor = PCA(n_components=N_COMPONENTS, random_state=0).fit(X_train)
    return extractor.transform(X_train), extractor.transform(X_val)
```

### `src/dl/data.py`

```python
# src/dl/data.py
"""Turn the digits split into PyTorch tensors + loaders."""
from __future__ import annotations

import torch
from sklearn.preprocessing import StandardScaler
from torch.utils.data import DataLoader, TensorDataset

from dl.dataset import split_digits


def make_loaders(batch_size: int = 64) -> tuple[DataLoader, DataLoader]:
    X_train, X_val, y_train, y_val = split_digits()

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
    # shuffle=True draws from torch's global RNG, so torch.manual_seed() fixes the batch order too.
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False)
    return train_loader, val_loader
```

### `src/dl/model.py`

```python
# src/dl/model.py
"""A tiny multi-layer perceptron, defined explicitly so you can see the stack."""
from __future__ import annotations

import torch
from torch import nn

from dl.dataset import N_CLASSES, N_FEATURES


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
# src/dl/train.py
"""The explicit training loop. Read every line — this is the whole idea."""
from __future__ import annotations

from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

from dl.data import make_loaders
from dl.model import TinyMLP


def evaluate(model: nn.Module, loader: DataLoader, loss_fn: nn.Module, device: str) -> float:
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


def train(epochs: int = 30, lr: float = 1e-3, seed: int = 42) -> tuple[list[float], list[float]]:
    torch.manual_seed(seed)   # weight initialization AND the DataLoader's shuffle order
    device = "cuda" if torch.cuda.is_available() else "cpu"
    train_loader, val_loader = make_loaders()

    model = TinyMLP().to(device)
    loss_fn = nn.CrossEntropyLoss()                          # the number to minimize
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

    import matplotlib  # imported here: only main() plots, so tests never load it

    matplotlib.use("Agg")  # headless backend: works in Docker with no display
    import matplotlib.pyplot as plt

    plt.plot(train_losses, label="train")
    plt.plot(val_losses, label="val")
    plt.xlabel("epoch")
    plt.ylabel("loss")
    plt.legend()
    plt.title("Train vs validation loss (watch for the gap = overfitting)")
    out = Path("outputs")  # gitignored: run outputs aren't source (same folder as the C# side)
    out.mkdir(exist_ok=True)
    plt.savefig(out / "loss_curve.png", bbox_inches="tight")
    print(f"Wrote {out / 'loss_curve.png'}")


if __name__ == "__main__":
    main()
```

### `src/dl/transfer.py`

```python
# src/dl/transfer.py
"""Transfer learning, the pattern you'll ACTUALLY use.

Instead of training a feature extractor from scratch, we treat a pretrained,
frozen component as a fixed feature source and train only a small head on top.
Here we simulate 'pretrained features' with sklearn's PCA to keep the example
tiny and CPU-only; the *pattern* — freeze the big pretrained part, train a
small head — is exactly what you do with a real pretrained network.
"""
from __future__ import annotations

import torch
from torch import nn

from dl.dataset import N_CLASSES, N_COMPONENTS, pca_features, split_digits


def run(seed: int = 0) -> float:
    torch.manual_seed(seed)   # the head's initial weights
    X_train, X_val, y_train, y_val = split_digits()

    # "Pretrained feature extractor" (frozen): fitted on train rows, then only transforms.
    F_train, F_val = pca_features(X_train, X_val)   # frozen: no gradients flow here
    xt = torch.tensor(F_train, dtype=torch.float32)
    yt = torch.tensor(y_train, dtype=torch.long)
    xv = torch.tensor(F_val, dtype=torch.float32)
    yv = torch.tensor(y_val, dtype=torch.long)

    # We train ONLY this small head. Far fewer parameters, far faster.
    head = nn.Linear(N_COMPONENTS, N_CLASSES)
    loss_fn = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(head.parameters(), lr=1e-2)

    for _ in range(50):   # full-batch: the whole training set is one batch
        head.train()
        optimizer.zero_grad()
        loss = loss_fn(head(xt), yt)
        loss.backward()
        optimizer.step()

    head.eval()
    with torch.no_grad():
        return (head(xv).argmax(dim=1) == yv).float().mean().item()


def main() -> None:
    print(f"Transfer-learning head validation accuracy: {run():.3f}")


if __name__ == "__main__":
    main()
```

### `tests/test_dataset.py`

```python
# tests/test_dataset.py
"""The data contract. No torch here, so these run in a second."""
import numpy as np

from dl.dataset import N_COMPONENTS, pca_features, split_digits


def test_split_sizes_match_the_csharp_fixtures() -> None:
    X_train, X_val, y_train, y_val = split_digits()
    assert (X_train.shape, X_val.shape) == ((1437, 64), (360, 64))   # TrainingTests.cs pins these
    assert set(y_train) == set(y_val) == set(range(10))


def test_pca_never_sees_the_validation_rows() -> None:
    X_train, X_val, _, _ = split_digits()
    F_train, F_val = pca_features(X_train, X_val)
    assert F_train.shape[1] == F_val.shape[1] == N_COMPONENTS
    # If the extractor were fitted on all rows, changing the validation rows would move the
    # training features. Fitted on train only, they can't.
    F_train_again, _ = pca_features(X_train, np.zeros_like(X_val))
    np.testing.assert_array_equal(F_train, F_train_again)
```

The second test is the leakage check from module 14, turned into an assertion: if the extractor had seen the validation rows, changing them would change the training features.

### `tests/test_train.py`

```python
# tests/test_train.py
from dl.train import train
from dl.transfer import run


def test_training_reduces_loss() -> None:
    # The core promise of the loop: loss should go DOWN over training. Seeded, so a failure reproduces.
    train_losses, val_losses = train(epochs=5, seed=42)
    assert train_losses[-1] < train_losses[0]
    # And the model should be learning something real, not just memorizing.
    assert val_losses[-1] < 1.0


def test_transfer_head_learns() -> None:
    # Ten classes: chance is 0.10. A head on 20 PCA features clears 0.8 comfortably.
    assert run(seed=0) > 0.8
```

### `src/dl/export_fixtures.py`

New for the two-language build. It writes the raw pixels (unscaled, because the C# side does its own train-only scaling, as `data.py` does) and the PCA features that `transfer.py` trains its head on. Both come from `dataset.py`, so all four files cover the same rows. The files go in the project-root `fixtures/` folder (or `FIXTURES_DIR`), where they're committed.

```python
# src/dl/export_fixtures.py
"""Write the digits split and the frozen PCA features to CSV: the data contract for the C# side."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

import numpy as np

from dl.dataset import pca_features, split_digits


def _write(path: Path, X: np.ndarray, y: np.ndarray) -> None:
    header = ",".join([f"f{i}" for i in range(X.shape[1])] + ["label"])
    np.savetxt(path, np.column_stack([X, y]), delimiter=",", header=header, comments="", fmt="%.9g")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    # FIXTURES_DIR if set, else the shared project-root fixtures/ (relative to python/, where you run this).
    default_dir = Path(os.environ.get("FIXTURES_DIR", "../fixtures"))
    parser.add_argument("--out-dir", type=Path, default=default_dir)
    args = parser.parse_args(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    X_train, X_val, y_train, y_val = split_digits()   # the split data.py and transfer.py use
    _write(args.out_dir / "digits_train.csv", X_train, y_train)   # raw pixels: C# scales them itself
    _write(args.out_dir / "digits_val.csv", X_val, y_val)

    F_train, F_val = pca_features(X_train, X_val)     # the features transfer.py trains its head on
    _write(args.out_dir / "digits_pca_train.csv", F_train, y_train)
    _write(args.out_dir / "digits_pca_val.csv", F_val, y_val)
    print(f"Wrote {len(y_train)} train / {len(y_val)} val rows to {args.out_dir.resolve()}")


if __name__ == "__main__":
    main()
```

```powershell
uv run python -m dl.export_fixtures   # run from python/; writes ../fixtures/*.csv (commit them)
```

### Run it locally

```powershell
cd projects/15-dl-intuition/python
uv sync
uv run pytest                    # 4 tests
uv run python -m dl.train        # prints per-epoch losses, writes outputs/loss_curve.png
uv run python -m dl.transfer     # prints transfer-learning accuracy
```

Open `outputs/loss_curve.png` and *look at it*. Watch train loss fall smoothly; watch whether validation loss keeps pace or starts pulling away. That gap, drawn, is the whole overfitting lesson made visible.

### Running the Python version in Docker

`Dockerfile`:

```dockerfile
# projects/15-dl-intuition/python/Dockerfile. Build context: python/ (load_digits is bundled, so no fixtures needed)
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /app
# Library pattern: dependencies first (cached layer), then README.md + code, then install the project.
# The lock pins torch to the CPU index, so this layer has no nvidia-* packages.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-install-project --no-dev
COPY src/ ./src/
RUN uv sync --frozen --no-dev
# Runs the explicit training loop on CPU and writes outputs/loss_curve.png.
CMD ["uv", "run", "--no-sync", "python", "-m", "dl.train"]
```

The working directory in the image is `/app`, so the plot lands in `/app/outputs/`. Mount a host folder there, or the plot is thrown away with the container. From the repo root:

```powershell
docker build -t dl-py projects/15-dl-intuition/python
docker run --rm -v "${PWD}/projects/15-dl-intuition/outputs/py:/app/outputs" dl-py   # plot lands on the host
docker run --rm dl-py uv run --no-sync python -m dl.transfer                         # the second script
```

(*Git Bash*: prefix `MSYS_NO_PATHCONV=1` and use `$PWD`, or the container path gets rewritten.)

> With the CPU index the image is roughly 1–1.5 GB, most of it torch. Without the index, the Linux resolve pulls the CUDA build and its `nvidia-*` packages, and the image grows several GB for a GPU it can't use. Check yours with `docker images dl-py`.

## C# implementation

Work in `projects/15-dl-intuition/csharp/`. Same model, same data split, same loop, same outputs. What differs:

- **The engine is the same; the driver isn't.** TorchSharp calls the same libtorch C++ kernels PyTorch does. Matrix multiplies, autograd and Adam all run the same native code. What changes is the language around it. TorchSharp even keeps PyTorch's snake_case names (`zero_grad`, `parameters`, `forward`) on purpose, so tutorials and papers translate almost directly. Your .NET naming instincts will object. Let them lose this one.
- **Memory is explicit.** This is the big .NET-specific lesson (see [Tensors and devices](#tensors-and-devices)). Python's refcounting frees each batch's tensors right away. In C# you wrap each batch in a dispose scope, or native memory grows until the process dies.
- **No `DataLoader`, no `StandardScaler`.** You shuffle indices and slice batches yourself, and you write the train-only standardization by hand. That's two things the Python version gets for free, and both are worth writing once.
- **Plotting.** No matplotlib. The loss curve goes to CSV (always) and to PNG via **ScottPlot**, a .NET plotting library.
- **Transfer learning has a real ecosystem gap.** PyTorch has torchvision, timm and the Hugging Face hub, each one line from a pretrained network. TorchSharp has far fewer pretrained weights, so the C# side trains its head on the frozen features Python exported. That's honest about where the extractor would come from in practice. The `Transfer.cs` section covers the realistic options.

### Scaffold

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 15-dl-intuition -Name DlIntuition
cd projects/15-dl-intuition/csharp
dotnet add src/DlIntuition package TorchSharp-cpu   # TorchSharp + the CPU build of libtorch
dotnet add src/DlIntuition package ScottPlot        # 5.1.59 when this was written
```

Delete the scaffold's `Program.cs` content; the one below replaces it. `TorchSharp-cpu` is TorchSharp plus libtorch's native binaries for every OS it supports, so the restore is big (hundreds of MB per OS, like the `torch` wheel). Each TorchSharp release expects one libtorch version: TorchSharp 0.107.0 wants libtorch 2.10.0, and `TorchSharp-cpu` pins it for you. GPU builds come as separate packages per OS (for example `TorchSharp-cuda-windows`), and their CUDA version must match your driver. Check the TorchSharp README for current names.

Run the Python exporter once (`uv run python -m dl.export_fixtures` from `python/`) and commit the four CSVs in `projects/15-dl-intuition/fixtures/`. They aren't copied into the build output. Both the app and the tests read them through `Fixtures.cs`, the same way module 14 does.

### `src/DlIntuition/Fixtures.cs`

Module 14's walker with the solution name changed: `FIXTURES_DIR` wins, else walk up from the bin folder to `DlIntuition.slnx` and take `../fixtures`. `dotnet run` and NUnit both start in a bin folder, where a plain `../fixtures` points nowhere.

```csharp
// src/DlIntuition/Fixtures.cs
namespace DlIntuition;

/// <summary>The shared projects/15-dl-intuition/fixtures/ folder. Containers set FIXTURES_DIR=/app/fixtures.</summary>
public static class Fixtures
{
    public static string Dir { get; } = Environment.GetEnvironmentVariable("FIXTURES_DIR") ?? FindDefault();

    public static string PathFor(string name) => Path.Combine(Dir, name);

    // dotnet run and dotnet test both start in a bin/ folder: walk up to the .slnx, then take ../fixtures.
    private static string FindDefault()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "DlIntuition.slnx")))
                return Path.GetFullPath(Path.Combine(dir.FullName, "..", "fixtures"));
        return Path.GetFullPath("../fixtures");
    }
}
```

### `src/DlIntuition/Digits.cs`

```csharp
// src/DlIntuition/Digits.cs
using System.Globalization;
using TorchSharp;
using static TorchSharp.torch;

namespace DlIntuition;

/// <summary>Load the exported digits CSVs and turn them into tensors.</summary>
public static class Digits
{
    public const int Features = 64;   // 8x8 pixels
    public const int Classes = 10;    // digits 0-9

    /// <summary>Feature columns, then the label in the last column. Header skipped.</summary>
    public static (float[][] X, long[] Y) LoadCsv(string path)
    {
        float[][] rows = File.ReadLines(path).Skip(1)
            .Select(line => line.Split(',').Select(v => float.Parse(v, CultureInfo.InvariantCulture)).ToArray())
            .ToArray();
        return (rows.Select(r => r[..^1]).ToArray(), rows.Select(r => (long)r[^1]).ToArray());
    }

    // float32 features, shape [rows, features].
    public static Tensor ToTensor(float[][] x) =>
        torch.tensor(x.SelectMany(r => r).ToArray()).reshape(x.Length, x[0].Length);

    // int64 class labels: what cross-entropy expects.
    public static Tensor ToTensor(long[] y) => torch.tensor(y);
}
```

### `src/DlIntuition/Standardizer.cs`

`data.py` gets this from one `StandardScaler` call. Writing it by hand turns up a detail the library hides: some digit pixels are blank in every image, so their standard deviation is 0. `StandardScaler` leaves those columns unscaled instead of dividing by zero, and so must you.

```csharp
// src/DlIntuition/Standardizer.cs
namespace DlIntuition;

/// <summary>StandardScaler by hand. Fit on TRAIN rows only, then transform both splits.</summary>
public sealed class Standardizer
{
    public float[] Mean { get; }
    public float[] Scale { get; }

    private Standardizer(float[] mean, float[] scale) => (Mean, Scale) = (mean, scale);

    public static Standardizer Fit(float[][] rows)
    {
        int d = rows[0].Length;
        var mean = new float[d];
        var scale = new float[d];
        for (int j = 0; j < d; j++)
        {
            double m = rows.Average(r => r[j]);
            double variance = rows.Average(r => (r[j] - m) * (r[j] - m));   // population variance (ddof=0), like StandardScaler
            mean[j] = (float)m;
            scale[j] = variance > 0 ? (float)Math.Sqrt(variance) : 1f;      // constant column: leave it alone
        }
        return new Standardizer(mean, scale);
    }

    public float[][] Transform(float[][] rows) =>
        rows.Select(r => r.Select((v, j) => (v - Mean[j]) / Scale[j]).ToArray()).ToArray();
}
```

### `src/DlIntuition/TinyMlp.cs`

```csharp
// src/DlIntuition/TinyMlp.cs
using TorchSharp;
using static TorchSharp.torch;
using static TorchSharp.torch.nn;

namespace DlIntuition;

/// <summary>Three stacked differentiable functions: linear -> relu -> linear.</summary>
public sealed class TinyMlp : Module<Tensor, Tensor>
{
    // Named `net`, unnamed layers: parameter names come out as net.0.weight etc., the same
    // keys PyTorch's state_dict uses for TinyMLP. That matters if you ever load Python weights.
    private readonly Module<Tensor, Tensor> net;

    public TinyMlp(int hidden = 64) : base(nameof(TinyMlp))
    {
        net = Sequential(
            Linear(Digits.Features, hidden),   // layer 1: weights + bias
            ReLU(),                            // non-linear squash: max(0, x)
            Linear(hidden, Digits.Classes));   // layer 2: outputs one score per class

        // PyTorch registers submodules automatically when __init__ assigns them. TorchSharp
        // needs this call. Forget it and parameters() is empty: the optimizer updates nothing.
        RegisterComponents();
    }

    // The "forward pass": data flows through the stacked functions.
    public override Tensor forward(Tensor x) => net.forward(x);
}
```

### `src/DlIntuition/Trainer.cs`

Read this next to `train.py`. The five numbered steps are the same lines in the same order. The differences are batching, which you do by hand, and memory, which you manage with dispose scopes.

```csharp
// src/DlIntuition/Trainer.cs
using TorchSharp;
using static TorchSharp.torch;
using static TorchSharp.torch.nn;

namespace DlIntuition;

/// <summary>The explicit training loop. Read every line — this is the whole idea.</summary>
public static class Trainer
{
    public static (List<float> Train, List<float> Val) Train(
        string fixturesDir, int epochs = 30, double lr = 1e-3, int batchSize = 64, int seed = 42)
    {
        torch.random.manual_seed(seed);       // weight initialization
        var shuffleRng = new Random(seed);    // batch order (in Python, DataLoader draws from torch's RNG)
        Device device = torch.cuda.is_available() ? CUDA : CPU;

        // The model and optimizer are created OUTSIDE any dispose scope: their tensors must outlive every batch.
        using var model = new TinyMlp();
        model.to(device);
        var lossFn = CrossEntropyLoss();                                // the number to minimize
        var optimizer = torch.optim.Adam(model.parameters(), lr: lr);   // the weight updater

        // Every tensor created after this line is freed when Train returns.
        using var outer = torch.NewDisposeScope();

        var (xTrainRaw, yTrainRaw) = Digits.LoadCsv(Path.Combine(fixturesDir, "digits_train.csv"));
        var (xValRaw, yValRaw) = Digits.LoadCsv(Path.Combine(fixturesDir, "digits_val.csv"));

        // Scale using TRAIN statistics only (leakage lesson from module 14).
        var scaler = Standardizer.Fit(xTrainRaw);
        Tensor xTrain = Digits.ToTensor(scaler.Transform(xTrainRaw)).to(device);
        Tensor yTrain = Digits.ToTensor(yTrainRaw).to(device);
        Tensor xVal = Digits.ToTensor(scaler.Transform(xValRaw)).to(device);
        Tensor yVal = Digits.ToTensor(yValRaw).to(device);

        long[] order = Enumerable.Range(0, xTrainRaw.Length).Select(i => (long)i).ToArray();
        var trainLosses = new List<float>();
        var valLosses = new List<float>();

        for (int epoch = 0; epoch < epochs; epoch++)
        {
            model.train();
            shuffleRng.Shuffle(order);   // DataLoader(shuffle=True), by hand
            for (int start = 0; start < order.Length; start += batchSize)
            {
                // Frees this batch's tensors (indices, slices, predictions, loss, graph) at the end of the iteration.
                using var batch = torch.NewDisposeScope();
                Tensor idx = torch.tensor(order[start..Math.Min(start + batchSize, order.Length)], device: device);
                Tensor xb = xTrain.index_select(0, idx);
                Tensor yb = yTrain.index_select(0, idx);

                optimizer.zero_grad();                    // 5. clear last batch's gradients
                Tensor preds = model.forward(xb);         // 1. FORWARD pass
                Tensor loss = lossFn.forward(preds, yb);  // 2. LOSS: how wrong were we?
                loss.backward();                          // 3. BACKWARD pass: autograd fills gradients
                optimizer.step();                         // 4. OPTIMIZER step: nudge the weights
            }

            trainLosses.Add(Evaluate(xTrain, yTrain));
            valLosses.Add(Evaluate(xVal, yVal));
            Console.WriteLine($"epoch {epoch + 1,2}  train_loss={trainLosses[^1]:F4}  val_loss={valLosses[^1]:F4}");
        }

        return (trainLosses, valLosses);

        // Average loss over a whole split, WITHOUT updating weights. One full batch gives the same
        // mean that train.py's evaluate() builds up batch by batch.
        float Evaluate(Tensor x, Tensor y)
        {
            model.eval();
            using var noGrad = torch.no_grad();   // don't track gradients: we're only measuring
            using var scope = torch.NewDisposeScope();
            return lossFn.forward(model.forward(x), y).item<float>();
        }
    }
}
```

The same loop, line by line:

| Step | PyTorch (`train.py`) | TorchSharp (`Trainer.cs`) |
|---|---|---|
| Seed | `torch.manual_seed(seed)` (init and shuffle) | `torch.random.manual_seed(seed)` (init) + `new Random(seed)` (shuffle) |
| Build the model | `TinyMLP().to(device)` | `new TinyMlp()` then `model.to(device)` |
| Loss and optimizer | `nn.CrossEntropyLoss()`, `torch.optim.Adam(model.parameters(), lr=lr)` | `CrossEntropyLoss()`, `torch.optim.Adam(model.parameters(), lr: lr)` |
| Batches | `for xb, yb in train_loader` | shuffle an index array, `index_select` each slice |
| Batch memory | refcounting frees it | `using var batch = torch.NewDisposeScope();` |
| 5. Zero gradients | `optimizer.zero_grad()` | `optimizer.zero_grad()` |
| 1. Forward | `model(xb)` | `model.forward(xb)` |
| 2. Loss | `loss_fn(preds, yb)` | `lossFn.forward(preds, yb)` |
| 3. Backward | `loss.backward()` | `loss.backward()` |
| 4. Step | `optimizer.step()` | `optimizer.step()` |
| Measure only | `model.eval()` + `with torch.no_grad():` | `model.eval()` + `using var noGrad = torch.no_grad();` |
| Read a number | `loss.item()` | `loss.item<float>()` |

### `src/DlIntuition/Transfer.cs`

```csharp
// src/DlIntuition/Transfer.cs
using TorchSharp;
using static TorchSharp.torch;
using static TorchSharp.torch.nn;

namespace DlIntuition;

/// <summary>Transfer learning: train ONLY a small head on features from a frozen extractor.</summary>
public static class Transfer
{
    public static float Run(string fixturesDir, int seed = 0)
    {
        torch.random.manual_seed(seed);
        var (xTrainRaw, yTrainRaw) = Digits.LoadCsv(Path.Combine(fixturesDir, "digits_pca_train.csv"));
        var (xValRaw, yValRaw) = Digits.LoadCsv(Path.Combine(fixturesDir, "digits_pca_val.csv"));

        // The "pretrained" PCA extractor already ran, in Python. It's frozen by construction:
        // no gradient can reach it. We train only this head. Far fewer parameters, far faster.
        using var head = Linear(xTrainRaw[0].Length, Digits.Classes);
        var lossFn = CrossEntropyLoss();
        var optimizer = torch.optim.Adam(head.parameters(), lr: 1e-2);

        using var outer = torch.NewDisposeScope();
        Tensor xt = Digits.ToTensor(xTrainRaw), yt = Digits.ToTensor(yTrainRaw);
        Tensor xv = Digits.ToTensor(xValRaw), yv = Digits.ToTensor(yValRaw);

        for (int epoch = 0; epoch < 50; epoch++)   // full-batch, like transfer.py
        {
            using var step = torch.NewDisposeScope();
            head.train();
            optimizer.zero_grad();
            Tensor loss = lossFn.forward(head.forward(xt), yt);
            loss.backward();
            optimizer.step();
        }

        head.eval();
        using var noGrad = torch.no_grad();
        return head.forward(xv).argmax(1).eq(yv).to_type(torch.float32).mean().item<float>();
    }
}
```

The honest gap: in Python, swapping the PCA stand-in for a real pretrained network is one line with torchvision or the Hugging Face hub. TorchSharp has model *definitions* in companion packages, but few ready-made pretrained *weights*. Realistic .NET options, from most to least common:

1. **Run the frozen extractor with ONNX Runtime**, as you did with MiniLM in module 03. Export it from PyTorch (`torch.onnx.export`), and train or serve only the head in .NET. The head can be TorchSharp, or even ML.NET's logistic regression from module 14.
2. **Load PyTorch weights into a TorchSharp module.** The TorchSharp repo ships an `exportsd.py` helper that saves a PyTorch `state_dict` in a format `module.load(path)` reads. The module structure and parameter names must match, which is why `TinyMlp` names its field `net`. Verify the current procedure in the TorchSharp docs before relying on it.
3. **Keep training in Python** and treat .NET as the serving side. This is often the right call.

### `src/DlIntuition/LossCurve.cs`

```csharp
// src/DlIntuition/LossCurve.cs
using System.Globalization;
using ScottPlot;

namespace DlIntuition;

public static class LossCurve
{
    public static void WriteCsv(string path, IReadOnlyList<float> train, IReadOnlyList<float> val) =>
        File.WriteAllLines(path, train
            .Select((t, i) => string.Create(CultureInfo.InvariantCulture, $"{i + 1},{t:F6},{val[i]:F6}"))
            .Prepend("epoch,train_loss,val_loss"));

    // ScottPlot 5 API. Plotting libraries change their APIs between majors: check its cookbook.
    public static void WritePng(string path, IReadOnlyList<float> train, IReadOnlyList<float> val)
    {
        double[] epochs = Enumerable.Range(1, train.Count).Select(i => (double)i).ToArray();
        var plot = new Plot();
        plot.Add.Scatter(epochs, train.Select(v => (double)v).ToArray()).LegendText = "train";
        plot.Add.Scatter(epochs, val.Select(v => (double)v).ToArray()).LegendText = "val";
        plot.XLabel("epoch");
        plot.YLabel("loss");
        plot.Title("Train vs validation loss (watch for the gap = overfitting)");
        plot.ShowLegend();
        plot.SavePng(path, 640, 480);
    }
}
```

### `src/DlIntuition/Program.cs`

Outputs go to `outputs/`, which the repo `.gitignore` already excludes. Run outputs aren't source.

```csharp
// src/DlIntuition/Program.cs
using System.Globalization;
using DlIntuition;

CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

// Shared with Python: one committed copy. FIXTURES_DIR, else the walk up from bin/ in Fixtures.cs.
string fixtures = Fixtures.Dir;
string outDir = Environment.GetEnvironmentVariable("DL_OUT_DIR") ?? "outputs";

switch (args)
{
    case [] or ["train"]:
    {
        var (train, val) = Trainer.Train(fixtures);
        Directory.CreateDirectory(outDir);
        LossCurve.WriteCsv(Path.Combine(outDir, "loss_curve.csv"), train, val);
        LossCurve.WritePng(Path.Combine(outDir, "loss_curve.png"), train, val);
        Console.WriteLine($"Wrote {Path.GetFullPath(outDir)}/loss_curve.csv and loss_curve.png");
        return 0;
    }
    case ["transfer"]:
        Console.WriteLine($"Transfer-learning head validation accuracy: {Transfer.Run(fixtures):F3}");
        return 0;
    default:
        Console.Error.WriteLine("usage: dl-intuition [train | transfer]");
        return 2;
}
```

### `tests/DlIntuition.Tests/StandardizerTests.cs`

```csharp
// tests/DlIntuition.Tests/StandardizerTests.cs
using NUnit.Framework;

namespace DlIntuition.Tests;

public class StandardizerTests
{
    // Column 0 varies; column 1 is constant, like a pixel that is blank in every image.
    private static readonly float[][] Rows = [[1f, 10f], [3f, 10f]];

    [Test]
    public void Fit_uses_population_std_and_leaves_constant_columns_unscaled()
    {
        var s = Standardizer.Fit(Rows);
        Assert.That(s.Mean, Is.EqualTo(new[] { 2f, 10f }));
        Assert.That(s.Scale, Is.EqualTo(new[] { 1f, 1f }));   // std of [1, 3] with ddof=0 is 1; constant -> 1, not 0
    }

    [TestCase(1f, -1f)]
    [TestCase(2f, 0f)]
    [TestCase(3f, 1f)]
    public void Transform_centres_and_scales(float raw, float expected) =>
        Assert.That(Standardizer.Fit(Rows).Transform([[raw, 10f]])[0][0], Is.EqualTo(expected).Within(1e-6));
}
```

### `tests/DlIntuition.Tests/TrainingTests.cs`

```csharp
// tests/DlIntuition.Tests/TrainingTests.cs
using NUnit.Framework;

namespace DlIntuition.Tests;

public class TrainingTests
{
    // Same lookup as the app (Fixtures.cs): FIXTURES_DIR, else walk up from the test bin/ folder.
    private static readonly string FixturesDir = Fixtures.Dir;

    [TestCase("digits_train.csv", 1437, 64)]
    [TestCase("digits_val.csv", 360, 64)]
    [TestCase("digits_pca_train.csv", 1437, 20)]
    [TestCase("digits_pca_val.csv", 360, 20)]
    public void Fixtures_match_the_python_split(string file, int rows, int features)
    {
        var (x, y) = Digits.LoadCsv(Path.Combine(FixturesDir, file));
        Assert.That(x, Has.Length.EqualTo(rows));
        Assert.That(x.All(r => r.Length == features), Is.True);
        Assert.That(y.Distinct().Order(), Is.EqualTo(Enumerable.Range(0, 10).Select(i => (long)i)));
    }

    [Test]
    public void Training_reduces_loss()
    {
        // The core promise of the loop: loss goes DOWN. Seeded, so a failure reproduces.
        var (train, val) = Trainer.Train(FixturesDir, epochs: 5, seed: 42);
        Assert.That(train[^1], Is.LessThan(train[0]));
        // And the model is learning something real. Same floor as the Python test.
        Assert.That(val[^1], Is.LessThan(1.0f));
    }

    // Ten classes: chance is 0.10. Same floor as the Python test.
    [Test]
    public void Transfer_head_learns() =>
        Assert.That(Transfer.Run(FixturesDir, seed: 0), Is.GreaterThan(0.8f));
}
```

Delete the scaffold's `SmokeTests.cs`. Run locally, from `csharp/`:

```powershell
dotnet test                                        # 10 tests
dotnet run --project src/DlIntuition -- train      # per-epoch losses, writes outputs/loss_curve.{csv,png}
dotnet run --project src/DlIntuition -- transfer   # transfer-learning accuracy
```

### Running the C# version in Docker

Same multi-stage shape as module 14, with the smaller `runtime` image since there's no web server. The build context is the project root, so the image can copy the shared `fixtures/` folder, which is why every `COPY` path starts with `csharp/` or `fixtures/`.

The part specific to TorchSharp is the runtime identifier. `TorchSharp-cpu` carries libtorch for Linux, Windows and macOS. Publish without `-r` and all of them land in the output (and the image); publish with `-r linux-x64` and only the Linux `.so` files do. Because `publish` runs with `--no-restore`, the restore has to use `-r linux-x64` too, or publish fails with `NETSDK1047` (the assets file has no `linux-x64` target). The restore still downloads every OS's package; if that download matters, reference `TorchSharp` plus the single `libtorch-cpu-linux-x64` package for the image instead of `TorchSharp-cpu`.

```dockerfile
# projects/15-dl-intuition/csharp/Dockerfile. Build context: projects/15-dl-intuition (to reach fixtures/)
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app
COPY csharp/DlIntuition.slnx csharp/Directory.Build.props csharp/
COPY csharp/src/DlIntuition/DlIntuition.csproj csharp/src/DlIntuition/
COPY csharp/tests/DlIntuition.Tests/DlIntuition.Tests.csproj csharp/tests/DlIntuition.Tests/
# -r linux-x64 here too: publish --no-restore below needs the linux-x64 assets in the restore output.
RUN dotnet restore csharp/DlIntuition.slnx -r linux-x64
COPY fixtures/ fixtures/
COPY csharp/ csharp/
# Without -r, publish copies libtorch for every OS TorchSharp-cpu supports into the output.
RUN dotnet publish csharp/src/DlIntuition -c Release -r linux-x64 --self-contained false -o /app/publish --no-restore

FROM build AS test
ENV FIXTURES_DIR=/app/fixtures
ENTRYPOINT ["dotnet", "test", "csharp/DlIntuition.slnx", "--no-restore"]

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
COPY fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
# outputs/ must be writable by the non-root user, mounted or not.
RUN mkdir outputs && chown $APP_UID outputs
USER $APP_UID
ENTRYPOINT ["dotnet", "DlIntuition.dll"]
CMD ["train"]
```

From the repo root (`-f` is resolved from your current directory, not from the build context):

```powershell
docker build -f projects/15-dl-intuition/csharp/Dockerfile -t dl-cs projects/15-dl-intuition
docker run --rm -v "${PWD}/projects/15-dl-intuition/outputs/cs:/app/outputs" dl-cs   # next to the Python plot
docker run --rm dl-cs transfer

docker build -f projects/15-dl-intuition/csharp/Dockerfile --target test -t dl-cs-test projects/15-dl-intuition
docker run --rm dl-cs-test
```

Expect the `dl-cs` image to be roughly 1 GB: about 200 MB of .NET runtime, the rest libtorch's Linux CPU libraries. That's an estimate from the package sizes, not a measured build; check with `docker images dl-cs`. Without `-r linux-x64` it's several times that.

ScottPlot renders with SkiaSharp, whose Linux native library needs fontconfig. If the PNG step fails in the container with a SkiaSharp load error, add the `SkiaSharp.NativeAssets.Linux.NoDependencies` package. The CSV is written first either way.

## Cross-check the two

Run `train` and `transfer` on both sides, locally or with the container commands above, and put the outputs side by side. With the mounts above, the plots land in `outputs/py/` and `outputs/cs/` under the project root.

- **The data** must match **exactly**: 1,437 train rows and 360 validation rows, 64 pixel features or 20 PCA features, labels 0–9. The fixture tests on both sides pin this.
- **The scaling** must match to float precision. Same train-only statistics, same constant-column rule. If you want proof, print a few standardized values from both sides.
- **The loss curves** should have the **same shape, not the same numbers**. An untrained 10-class model scores about `ln(10) ≈ 2.30`, so both curves should start below that after epoch 1, fall quickly, then flatten, with validation loss levelling off above training loss. Final losses should agree to within a few hundredths. Both sides are seeded, so each is repeatable run to run, but they can't match each other: Python's batch order comes from torch's RNG and C#'s from `System.Random`, and the initialization draws happen in a different sequence. The engine underneath is identical; what differs is the random numbers fed into it.
- **Transfer accuracy** should agree to within about **2 points** (0.02). Same frozen features, same full-batch loop, same optimizer; only the head's initial weights differ, and on 360 validation rows one image is 0.28 points, so a handful of borderline digits flipping is normal. A bigger gap means the features differ: re-export the fixtures.
- If the C# loss **doesn't move at all**, suspect `RegisterComponents()` before anything else. If memory **climbs every epoch**, a tensor is being created outside a dispose scope.

| Concern | Python | C# / .NET |
|---|---|---|
| Tensor library | PyTorch (`torch`) | TorchSharp, the same libtorch underneath |
| Package | `torch` wheel, pinned to the CPU index (CUDA index per platform) | `TorchSharp-cpu` / `TorchSharp-cuda-*` NuGet; publish with `-r` |
| Define a model | subclass `nn.Module`; submodules auto-register | subclass `Module<Tensor, Tensor>`; call `RegisterComponents()` |
| Call a model | `model(x)` | `model.forward(x)` |
| Tensor lifetime | refcounting frees tensors promptly | native memory; `torch.NewDisposeScope()` per batch |
| Batching | `TensorDataset` + `DataLoader` | shuffled index array + `index_select` |
| Scaling | `StandardScaler` | hand-written `Standardizer` |
| Dataset | `load_digits()` (bundled) | CSV fixtures exported from Python |
| Finding fixtures | `FIXTURES_DIR`, else `../fixtures` | `FIXTURES_DIR`, else walk up to the `.slnx` |
| Loss curve | matplotlib PNG | CSV + ScottPlot PNG |
| Pretrained models | torchvision, timm, Hugging Face hub | thin; ONNX Runtime or weights exported from Python |
| Tests | `pytest` | NUnit (`Assert.That`, `[TestCase]`) |

## Moving to AWS

The honest version, which is more reassuring than beginners expect:

- **You rarely need a GPU early.** Everything in this module runs fine on a CPU. Fine-tuning small models (module 16) and full training are where GPUs earn their cost. Don't rent a GPU to learn the loop.
- **When you do need training compute:** GPU EC2 instances (the `g` and `p` families) give you raw machines; **SageMaker Training** gives you managed jobs where you hand it your `train.py` and a data location and it spins up the GPU, runs, saves the artifact to S3, and tears the instance down — so you don't leave an expensive GPU idling (a classic way to burn money). SageMaker also handles distributed multi-GPU training when a model outgrows one card.
- **Serving:** a trained model is just weights. Small models serve on CPU containers exactly like module 14; only large models need GPU inference (SageMaker real-time endpoints or a GPU ECS task). Match the hardware to the model size, not to the word "AI."
- **Per language:** the Python image is what SageMaker Training expects. Its SDK and prebuilt PyTorch containers are Python-first. The `dl-cs` image runs fine as an ECS/Fargate task or a batch job on CPU. On a GPU instance you'd switch to a CUDA TorchSharp package, and its libtorch/CUDA versions must match the instance's drivers. A common split in a .NET shop: **train in PyTorch** (on SageMaker or a GPU EC2 instance), **export to ONNX**, and **serve from .NET with ONNX Runtime**. That uses each ecosystem for what it's strongest at, and TorchSharp stays the tool for understanding the loop or training small models in-process.

The senior habit: **treat GPUs like any expensive, metered resource** — provision them for a job, watch the meter, release them. A forgotten running GPU instance is the deep-learning equivalent of a leaked connection pool, except it costs dollars an hour. (Module 13's cost discipline applies directly. Verify current instance families and SageMaker specifics in AWS docs.)

## How experts think / pitfalls

- **You don't understand a model until you've watched its loss curve.** Print/plot train and val loss every run. Loss not going down → learning rate wrong, data mislabeled, or a bug. It's your `console.log` for training.
- **Learning rate is the first knob to touch.** Loss is NaN or exploding → lower it. Loss barely moves → raise it (or train longer). Most "the model won't learn" problems are learning rate.
- **`optimizer.zero_grad()` is not optional.** PyTorch *accumulates* gradients by default; forget to clear them and each batch is polluted by the last. A silent, classic bug — there's a reason it's step 5 in every loop.
- **`model.train()` vs `model.eval()`.** Some layers (dropout, batch-norm) behave differently in training vs inference. Forgetting `eval()` at inference gives subtly wrong, noisy results. Also wrap evaluation in `torch.no_grad()` — it's faster and makes intent clear.
- **Device mismatches are the top runtime error.** Model and data must be on the same device. Move both with `.to(device)` and define `device` once.
- **Don't train from scratch to feel legitimate.** Reaching for a pretrained model isn't cutting corners; it's the professional default. Training from scratch is the exception you justify, not the norm you prove yourself with.
- **Set seeds, but expect wobble.** `torch.manual_seed(...)` helps reproducibility, but GPU nondeterminism and library versions mean exact numbers vary. Assert quality floors in tests, not exact values (same lesson as module 14).
- **In .NET, tensor memory is your job.** The GC can't see libtorch's native allocations, so a loop that leaks one small tensor per batch looks fine in a five-epoch test and runs out of memory in a real run. Put a dispose scope around every batch and every evaluation, and keep long-lived tensors (weights, the dataset) outside them. It's the same discipline as `using` on a `DbConnection`, applied at a much higher rate.
- **A model with no registered parameters trains "fine."** In TorchSharp, forgetting `RegisterComponents()` gives no error. `parameters()` is just empty, the optimizer has nothing to update, and the loss stays flat. When a loss won't move, check `model.parameters().Count()` before you touch the learning rate.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Revisit:** re-read the [reward-hacking section](R-reviewing-ai-written-code.md#gameable-tests-and-reward-hacking-at-engineer-depth). You've now seen the loop: a model changes whatever lowers the loss, whether or not that's what you meant. RL swaps the loss for a reward, and the same pressure applies.
- **Before moving on:** write your one-page reward-hacking explainer in your own words, backed by examples from your journal.
- **C#-specific watch:** TorchSharp's API has shifted between releases, and agents mix the versions. Loss functions used to be delegates called as `lossFn(preds, y)` and are now modules with `.forward(...)`. Optimizer parameter names vary (`lr:` vs invented `learningRate:`). Agents also invent a PyTorch-style `DataLoader`/`TensorDataset` API, call `model(x)` as if C# had `__call__`, omit `RegisterComponents()`, and leave out dispose scopes. They confuse the `TorchSharp`, `TorchSharp-cpu` and `libtorch-*` packages too, and write Dockerfiles that publish `TorchSharp-cpu` without `-r linux-x64` (every OS's libtorch in the image). On the Python side, watch for `torch` added without the CPU index, or only as a transitive dependency, so the pin never applies. For plotting, ScottPlot 4 (`plt.AddScatter`, `SaveFig`) and ScottPlot 5 (`plot.Add.Scatter`, `SavePng`) get mixed in the same file. The code in this doc is no exception: verify it.

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
- Put `train.py` and `Trainer.cs` side by side and map every line of the loop. Say which outputs of the two versions must match exactly (the data and the split), which only approximately (the loss curves, transfer accuracy), and why, given that both run on libtorch.
- Explain why the C# loop needs dispose scopes when the Python one doesn't, and what goes wrong if you put the model's construction inside the per-batch scope.
- Show from `uv.lock` that torch comes from the CPU index with no `nvidia-*` packages, and say what changes (and what stays CPU) when you add the CUDA index for Windows.
- Explain why the PCA stand-in is fitted on the training rows only, and which test proves it.

## Going deeper

Search terms and topics when you want more (verify against current docs):

- "PyTorch 60 Minute Blitz" and "PyTorch tutorials" — the official on-ramp; the autograd tutorial is worth doing once.
- "Andrej Karpathy — Neural Networks: Zero to Hero" — builds autograd and a small language model from scratch; the single best intuition-builder if you want to go one level deeper without heavy math.
- "3Blue1Brown neural networks" — the visual intuition for what gradients and layers do, if you're a visual learner.
- "The Illustrated Transformer" (Jay Alammar) — attention explained with pictures, when you're curious how LLMs differ from the MLP here.
- "PyTorch learning rate scheduler" and "early stopping" — the standard tools for the training-dynamics problems above.
- "cross-entropy loss intuition" — the one bit of loss-function math worth the one-paragraph version.
- "TorchSharp memory management" and "TorchSharp dispose scopes": the wiki pages on native tensor lifetime. Read them before writing any long-running TorchSharp code.
- "TorchSharpExamples" (the dotnet GitHub repo) and "TorchSharp exportsd.py": complete training loops in C#, and how to move PyTorch weights into TorchSharp.
- "torch.onnx.export" and "ONNX Runtime C#": the train-in-Python, serve-in-.NET route most .NET teams end up using.

The math you *could* learn but don't need to ship: backpropagation and the chain rule, the derivation of attention, optimizer internals (Adam's moment estimates). Name them, trust autograd, move on.

*Last verified: 2026-10-05. Built, in a throwaway build: `uv lock` with the CPU index (torch 2.14.1+cpu for Linux and Windows, 2.14.1 for macOS, all from `download.pytorch.org/whl/cpu`, no `nvidia-*` packages) and with the per-platform CUDA variant (2.14.1+cu130 on Windows); the torch-free `dataset.py`, `export_fixtures.py` and `tests/test_dataset.py` (2 passed); ruff clean. C#: compiled against TorchSharp 0.107.0 (the managed package, no libtorch) and ScottPlot 5.1.59, with warnings as errors; the 8 tests that don't touch libtorch passed; `restore -r linux-x64` + `publish -r linux-x64 --no-restore` succeeded and publish without the restore RID failed with NETSDK1047, as described. Read-only: every torch and TorchSharp training run (`train`, `transfer`, `test_train.py`, the two C# training tests), the loss-curve PNGs, and the Docker images, so the image sizes are estimates.*

**Verify on first build:**

- That `TorchSharp-cpu` (0.107.0, libtorch 2.10.0) runs the C# tests: `dotnet test` should show 10 passed.
- The ScottPlot 5 calls in `LossCurve.cs` (`Add.Scatter(...).LegendText`, `ShowLegend`, `SavePng`) produce the PNG; they compiled against 5.1.59 but weren't run.
- The two image sizes (`docker images dl-py dl-cs`), and whether the `runtime:10.0` image needs `SkiaSharp.NativeAssets.Linux.NoDependencies` for the PNG.
- That Adam's state tensors survive the per-batch `DisposeScope`: after two epochs, `model.parameters()` should still be readable and the loss still falling. A use-after-dispose shows up as an `ObjectDisposedException` or a loss that jumps to `NaN`.
- That both loss curves start below `ln(10) ≈ 2.30` after epoch 1 and that transfer accuracy agrees within about 2 points.

Next: [16 — Fine-tuning & adaptation](16-fine-tuning-and-adaptation.md).
