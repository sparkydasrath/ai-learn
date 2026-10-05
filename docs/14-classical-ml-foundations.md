# 14 — Classical ML foundations

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer, and you're doing it *without* a deep math or ML-research background. This phase (14–17) touches the most theory in the whole series, so the discipline changes slightly: you get **intuition and working code**, math stays minimal on purpose, and whenever a concept has heavy math underneath it, this doc names it, gives you the one-sentence intuition, and points you to "going deeper" instead of deriving it. You do not need to derive gradient descent or the math behind decision trees to be an excellent AI engineer — you need to know *what each tool is for*, *when to reach for it*, and *how to measure whether it worked*. That's what this module builds, using scikit-learn, the classical-ML workhorse.

Not everything should be an LLM. That sentence is the whole point of this module. An LLM is a spectacular, expensive, slow, hard-to-explain hammer, and a large fraction of the "AI" problems you'll be handed are screws: score this lead, route this ticket, flag this transaction, predict this churn, rank these results. For those, a **classical ML** model — logistic regression, a gradient-boosted tree — is cheaper by orders of magnitude, answers in microseconds instead of seconds, runs on a CPU, and can often *tell you why* it decided what it decided. Frequently it's also just *more accurate* on tabular data. Knowing this — and knowing when to say "this doesn't need an LLM" — is a senior judgment call that separates an AI engineer from someone who reaches for the biggest model reflexively.

## Where this fits

**Prerequisites:** modules 01–13. You can write typed Python and run the toolchain (01), you understand the AI landscape and where models sit (02–03), and — critically — you learned to **evaluate** in module 09. This module recaps metrics, but 09 is where "quality is a number" became a habit. You also met **embeddings** in 03 and used them in RAG (07); we connect those to classical ML here.

**After this module you can:**

- Decide when a problem wants classical ML instead of an LLM, and defend the choice.
- Run the standard supervised-ML workflow — split, fit, evaluate — without leaking test data into training.
- Pick a sensible algorithm (logistic regression, tree, gradient boosting, k-means) by what it's *good at*, not by its math.
- Use the scikit-learn `fit`/`predict`/`transform` API and compose steps into a `Pipeline`.
- Read a confusion matrix and choose the right metric for the business problem.
- Recognize overfitting and use cross-validation to get an honest quality estimate.
- Serve a trained model behind a FastAPI endpoint, in Docker, and know how it moves to AWS.
- Rebuild the same pipeline in ML.NET, serve it from ASP.NET Core, and score the Python-trained model from .NET through ONNX. You'll know when to retrain in .NET and when to ship the Python model instead.

## Supervised vs unsupervised — the first fork

Two big families, and you decide which by asking *"do I have labeled examples of the answer?"*

- **Supervised learning** — you have inputs *and* the correct outputs (labels), and you want to predict the output for new inputs. "Here are 10,000 emails each marked spam/not-spam; predict spam for new ones." This is 90% of what you'll build. It splits again into **classification** (predict a category — spam/not-spam, which-of-5-queues) and **regression** (predict a number — expected revenue, days-to-churn).
- **Unsupervised learning** — you have inputs but *no* labels, and you want structure. "Here are 100,000 customers; group them into segments." The main tool is **clustering** (k-means). There's no "right answer" to score against, which makes it fuzzier and less common in production than beginners expect.

The .NET analogy: supervised learning is like having a big set of `(input, expectedOutput)` test cases and fitting a function to pass them; unsupervised is like running a grouping/dedup pass over data with no expected output to compare to.

## The standard workflow (memorize this shape)

Every supervised project has the same skeleton. Internalize it the way you internalized arrange-act-assert:

1. **Split the data** into train / validation / test *before you look at anything*. Train is what the model learns from; validation is what you tune against; test is touched **once**, at the very end, to get an honest final number. (For smaller data you often fold validation into cross-validation — below.)
2. **Build features** — turn raw data into numeric columns the model can consume (scaling numbers, encoding categories, extracting text features). This is where most of the real work and most of the mistakes live.
3. **Fit** the model on the training set.
4. **Evaluate** on held-out data with the metric that matches the business goal.
5. **Iterate** — change features or model, re-measure. Only ever compare on held-out data.

### Data leakage — the bug that fakes success

The single most dangerous mistake in classical ML has no analog in ordinary bugs, because your tests will *pass* and your model will *look great* and then fail in production. **Data leakage** is when information from outside the training set sneaks into training, so the model "cheats." The classic version: you scale your features (subtract the mean, divide by std) using statistics computed over the *whole* dataset — including the test rows — before splitting. Now the model has secretly seen the test data's distribution, your test score is inflated, and prod is a disappointment.

The .NET instinct that saves you: treat the test set like **production data you don't have yet**. You would never let production data influence a build-time decision. Same here. The fix, mechanically, is scikit-learn `Pipeline` (below) fitted *only* on training data — it makes leakage hard to commit by accident.

## Core algorithms at intuition level

You do **not** need the math. You need to know what each is for. Here's the working engineer's mental model of the four you'll actually reach for.

### Logistic regression — the sensible default for classification

Despite "regression" in the name, it's a **classifier**. Intuition: it draws a straight boundary (a weighted sum of your features passed through a squashing function) and outputs a *probability* of the positive class. It's fast, it's interpretable (each feature has a weight — you can see what pushed the decision), and it's a great baseline. **Reach for it first**; if a fancier model can't beat it, you've learned something. Heavy math it hides from you: the sigmoid function and maximum-likelihood fitting — name-drop, don't derive.

### Decision trees — the flowchart learner

Intuition: it learns a flowchart of yes/no questions ("is amount > $500? then is country foreign? …") that splits the data toward an answer. Extremely interpretable for shallow trees; you can literally read the rules. On its own a single tree **overfits** badly (memorizes the training data). Its real value is as the building block for ensembles.

### Gradient boosting (XGBoost / LightGBM) — what usually wins on tabular data

Intuition: train many small, weak trees *in sequence*, where each new tree focuses on the mistakes the previous ones made, and sum their votes. This "many weak learners correcting each other" idea (boosting) is, empirically, the thing that **most often wins on tabular/structured data** — the CSV-shaped problems that make up most business ML. If you have rows and columns and a label, start with logistic regression as a baseline and reach for gradient boosting (`XGBoost`, `LightGBM`, or scikit-learn's `HistGradientBoostingClassifier`) as the strong contender. Heavy math it hides: gradient descent in "function space." You will never need to derive that.

### k-means — the unsupervised grouper

Intuition: you tell it "find *k* groups," and it iteratively places *k* center points and assigns each row to its nearest center until things settle. Good for customer segmentation, quick data exploration, deduplication-ish grouping. Weaknesses to know: **you have to pick *k***, it assumes roughly round clusters, and results shift with initialization. It's a useful tool, not a magic "find the natural groups" button.

There are dozens more (random forests, SVMs, k-NN, naive Bayes). You'll recognize them; you don't need them to start. The four above cover an enormous amount of real work.

## The scikit-learn API — one interface, everywhere

Here's the thing that makes scikit-learn a joy for an engineer: **almost every object follows the same tiny interface.** Once you know it, you know the whole library. It's the strongest "learn one abstraction, reuse it everywhere" story in ML.

- **`estimator.fit(X, y)`** — learn from data. `X` is your features (a 2-D array/DataFrame, rows = samples, columns = features); `y` is the labels. For unsupervised, just `fit(X)`.
- **`estimator.predict(X)`** — produce predictions for new data.
- **`transformer.transform(X)`** — turn data into a new representation (scale it, encode it, reduce it). Transformers *also* have `fit` (to learn the transformation's parameters from training data).
- **`predict_proba(X)`** — for classifiers, the class probabilities, not just the hard label. You'll want these constantly (for thresholds, ROC-AUC).

The .NET analogy that makes `Pipeline` click: it's a **composable transform pipeline**, like chaining middleware in ASP.NET or `IEnumerable` operators — each stage `transform`s the data and hands it to the next, and the final stage is your model. Crucially, a `Pipeline` is itself an estimator: it has `fit` and `predict`, so the whole chain behaves as one model. That's what makes leakage hard: when you call `pipeline.fit(X_train)`, every step — including the scaler — learns from training data *only*, and at `predict` time the *same* fitted transforms apply. You physically can't leak test statistics through a properly built pipeline.

```python
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

# One object that scales, then classifies. fit/predict on the whole thing.
pipe = Pipeline([
    ("scale", StandardScaler()),          # transformer
    ("model", LogisticRegression()),      # final estimator
])
pipe.fit(X_train, y_train)                # scaler learns from train only
preds = pipe.predict(X_test)              # same scaler applied to test
```

ML.NET, the .NET counterpart, has the same idea with one twist: the type system splits it in two. The unfitted chain is an `IEstimator<ITransformer>` (a recipe, nothing learned yet). `Fit` returns an `ITransformer` (the learned model). In scikit-learn both are the same `Pipeline` object before and after `fit`:

```csharp
using Microsoft.ML;

var ml = new MLContext(seed: 42);
IEstimator<ITransformer> pipeline = ml.Transforms.NormalizeMeanVariance("Features", fixZero: false)  // transformer
    .Append(ml.BinaryClassification.Trainers.LbfgsLogisticRegression());                           // final estimator
ITransformer model = pipeline.Fit(trainData);    // scaler learns from train only
IDataView preds = model.Transform(testData);     // same fitted scaler applied to test
```

## Metrics — recap from 09, with the classical-ML lens

Module 09 drilled "quality is a number." Here are the numbers for classification, and — more important — *when each one matters*. Accuracy is almost never the one you want.

- **Accuracy** — fraction correct. **Misleading on imbalanced data.** If 99% of transactions are legitimate, a model that always says "legit" is 99% accurate and completely useless. Beware.
- **Precision** — of the things you *flagged positive*, how many really were? High precision = few false alarms. Matters when acting on a positive is expensive (blocking a customer's card).
- **Recall** — of the things that *actually were positive*, how many did you catch? High recall = few misses. Matters when a miss is expensive (missing fraud, missing a tumor).
- **Precision/recall trade off.** You tune the decision threshold to move between them; you rarely get both for free. Decide which error is worse *for the business* before you optimize.
- **F1** — the harmonic mean of precision and recall, a single number when you care about both.
- **ROC-AUC** — how well the model *ranks* positives above negatives across all thresholds (1.0 = perfect, 0.5 = coin flip). Threshold-independent; good for comparing models.
- **Confusion matrix** — the 2×2 (or N×N) table of predicted-vs-actual: true positives, false positives, false negatives, true negatives. **Always look at this.** Every other metric is a summary of it, and the raw table tells you *which kind* of mistake your model makes.

The senior move: pick the metric *from the cost of each error*, before training, and write it down. "We optimize recall at ≥0.90 precision" is an engineering spec. "It's 94% accurate" is usually a red flag that nobody thought about the errors.

## Overfitting, regularization, cross-validation

**Overfitting** is the central failure mode, and you already have the intuition from software: it's a model that has *memorized* the training data (including its noise) instead of learning the general pattern — like a test suite so coupled to the implementation that it passes on your machine and tells you nothing about real behavior. You spot it when training score is high but held-out score is much lower.

Two defenses:

- **Regularization** — a knob that penalizes complexity, pushing the model toward simpler explanations that generalize better. Every serious model has one (in logistic regression it's the `C` parameter; in boosting it's tree depth, learning rate, number of trees). Intuition only: "turn this to fight overfitting"; the math is a penalty term you don't need to derive.
- **Cross-validation** — instead of a single train/val split (which might be lucky or unlucky), you split the training data into *k* folds, train on *k*−1 and validate on the held-out fold, rotate through all *k*, and average. You get a *distribution* of scores, not one, so your quality estimate is honest and you notice high variance. This is the single most useful habit for trustworthy numbers, and scikit-learn makes it one function call (`cross_val_score`).

## Feature engineering, and the bridge to the LLM world

**Feature engineering** — turning raw data into informative numeric columns — is where classical ML projects are won or lost. Scaling numbers, one-hot encoding categories, extracting the day-of-week from a timestamp, bucketing ages: unglamorous, high-leverage work. A mediocre model with great features beats a great model with raw junk.

Here's the bridge that connects everything in this series: **an embedding is just a feature vector.** In module 03/07 you turned text into a dense vector with an embedding model. You can hand that vector straight to a classical classifier as its features. That means the standard pattern — *embed the text with an LLM-family model, then classify with cheap fast logistic regression or gradient boosting* — gives you LLM-quality text understanding with classical-ML cost and latency at inference. This is not a toy trick; it's how a lot of production text classification actually works. The LLM does the "understanding," the classical model does the fast, cheap, explainable decision.

## Where classical ML sits *next to* LLMs

In a real AI system, classical ML rarely competes with the LLM — it *supports* it:

- **Routing** — a cheap classifier decides which model/prompt/tool handles a request, so you don't pay for the big model on easy inputs.
- **Classification & triage** — ticket/queue assignment, intent detection, spam/abuse — often a classifier on embeddings, far cheaper than an LLM call per item.
- **Guardrails** — a fast classifier flags toxic/PII/injection inputs before they reach the model (module 11).
- **Reranking** — after RAG retrieval (07) returns candidates, a learned ranker reorders them for relevance.

The judgment: reach for classical ML when the task is a well-defined prediction over structured or embeddable inputs, you can get labeled data, and you need it cheap, fast, or explainable. Reach for the LLM when the task genuinely needs open-ended language generation or reasoning. The [optional exercise](#optional-exercise-measure-not-everything-should-be-an-llm) after the cross-check puts numbers on that trade-off.

## The build project

**`projects/14-classical-ml/`** — train a classifier on a bundled tabular dataset with a proper scikit-learn `Pipeline`, evaluate it honestly (train/test split + cross-validation + a confusion matrix), and serve `predict` behind a small FastAPI endpoint. All in Docker. We use the classic **breast-cancer** dataset bundled with scikit-learn so there's no data to download and the example is fully reproducible — swap in your own CSV later.

You build it twice. Both versions:

1. Train a scale-then-logistic-regression pipeline on the same training rows, with 5-fold cross-validation first.
2. Evaluate once on the same 114 held-out test rows and print a confusion matrix in the same `[[TN FP] [FN TP]]` layout.
3. Serve `GET /health` and `POST /predict` with the same JSON contract, including a 400 for a malformed row.

The Python version is the spec. It also exports the dataset, already split, to CSV for the C# side, because ML.NET doesn't bundle datasets. The C# version retrains in ML.NET, and an optional last step scores the *Python-trained* model from .NET through ONNX. Those two routes give you different kinds of agreement, and the cross-check is about seeing why.

### Layout

```
projects/14-classical-ml/
├── fixtures/                        # committed, shared: written once by the Python exporter
│   ├── breast_cancer_train.csv
│   └── breast_cancer_test.csv
├── python/
│   ├── pyproject.toml
│   ├── uv.lock                     # committed
│   ├── Dockerfile                  # build context: python/
│   ├── Dockerfile.dockerignore     # from the scaffold
│   ├── README.md
│   ├── compare_llm.py              # optional exercise: embed + logreg vs an LLM classifier
│   ├── src/
│   │   └── clf/
│   │       ├── __init__.py
│   │       ├── train.py            # build pipeline, cross-validate, fit, save model
│   │       ├── evaluate.py         # confusion matrix + report on held-out test set
│   │       ├── serve.py            # FastAPI app loading the saved model
│   │       ├── export_fixtures.py  # writes the train/test split to ../fixtures/
│   │       └── export_onnx.py      # optional: fitted pipeline -> ../csharp/models/clf.onnx
│   └── tests/
│       ├── test_train.py
│       └── test_serve.py           # the HTTP contract, through TestClient
└── csharp/
    ├── ClassicalMl.slnx
    ├── Directory.Build.props        # shared settings: nullable, warnings-as-errors
    ├── Dockerfile                   # build context: the project root (for fixtures/)
    ├── Dockerfile.dockerignore      # from the scaffold, plus *.joblib; applies whatever the context
    ├── .vscode/settings.json
    ├── README.md
    ├── models/                      # gitignored; optional ONNX export from Python
    ├── src/
    │   └── ClassicalMl/
    │       ├── ClassicalMl.csproj   # web API project
    │       ├── Fixtures.cs          # finds ../fixtures, or FIXTURES_DIR
    │       ├── Schema.cs
    │       ├── Training.cs
    │       ├── ConfusionCounts.cs
    │       ├── Evaluation.cs
    │       ├── OnnxScorer.cs        # optional
    │       └── Program.cs           # `train` / `evaluate` / `onnx-check` commands, else serve
    └── tests/
        └── ClassicalMl.Tests/
            ├── ClassicalMl.Tests.csproj    # NUnit
            ├── SmokeTests.cs               # from the bootstrap script; delete once real tests exist
            ├── ConfusionCountsTests.cs
            └── TrainingTests.cs
```

## Python implementation

Work in `projects/14-classical-ml/python/`. Scaffold it from the repo root:

```powershell
pwsh ./scripts/new-python-project.ps1 -ProjectName 14-classical-ml
```

The script names the package `classical_ml`; this doc uses the shorter `clf`. Rename `src/classical_ml/` to `src/clf/`, empty its `__init__.py`, delete `tests/test_smoke.py`, and use the `pyproject.toml` below.

### `pyproject.toml`

```toml
# projects/14-classical-ml/python/pyproject.toml
[project]
name = "clf"
version = "0.1.0"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "scikit-learn>=1.5",
    "numpy>=2.0",
    "joblib>=1.4",
    "fastapi>=0.115",
    "uvicorn>=0.30",
    "pydantic>=2.7",
]

[dependency-groups]
dev = [
    "pytest>=8.2",
    "ruff>=0.5",
    "pyright>=1.1.370",
    "httpx>=0.27",
    "skl2onnx>=1.20.0",
]

[build-system]
requires = ["uv_build>=0.10.9,<0.11.0"]
build-backend = "uv_build"
```

This is a **library**-shaped project (`-Mode package`, code in `src/clf/`). The `[build-system]` block is what makes `uv sync` install `clf` into the venv, so `python -m clf.train` can import it. Without it, uv treats the folder as a plain app and `src/clf` is never installed. Keep the block the scaffold wrote; its `uv_build` version range comes from your uv version, so don't copy the one above if yours differs. `skl2onnx` is only for the optional ONNX section; add it later with `uv add --dev skl2onnx`.

> Pythonism flag: scikit-learn's type stubs are incomplete, so pyright stays in its default `standard` mode here, not `strict`, and a couple of lines carry a targeted `# pyright: ignore[...]` where the stubs are wrong. That's a real-world compromise: the library predates modern typing. Keep your *own* code strictly typed, and make each ignore name the rule it silences.

### `src/clf/train.py`

```python
# src/clf/train.py
"""Build a leakage-safe pipeline, cross-validate it, fit it, and save it."""
from __future__ import annotations

from pathlib import Path

import joblib
import numpy as np
from sklearn.datasets import load_breast_cancer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score, train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

MODEL_PATH = Path("model.joblib")   # relative to where you run it: python/ locally, /app in the image


def build_pipeline() -> Pipeline:
    """Scale, then classify — as one composable estimator.

    Because the scaler lives *inside* the pipeline, it is fitted only on
    training data during fit(), which is what prevents leakage.
    """
    return Pipeline([
        ("scale", StandardScaler()),
        ("model", LogisticRegression(max_iter=10_000, C=1.0)),
    ])


def load_data() -> tuple[np.ndarray, np.ndarray]:
    X, y = load_breast_cancer(return_X_y=True)   # 569 rows x 30 features; 1 = benign
    return X, y


def split(X: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """The one train/test split. export_fixtures.py writes exactly these rows for the C# side."""
    # stratify keeps the class balance the same in train and test.
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)
    # sklearn's stubs say each part might be a list; for ndarray input it's an ndarray.
    return X_train, X_test, y_train, y_test  # pyright: ignore[reportReturnType]


def main() -> None:
    X, y = load_data()

    # Split BEFORE touching the data for anything else.
    X_train, X_test, y_train, y_test = split(X, y)

    pipe = build_pipeline()

    # Cross-validate on the TRAINING data only, for an honest quality estimate
    # BEFORE we spend our one look at the test set.
    scores = cross_val_score(pipe, X_train, y_train, cv=5, scoring="roc_auc")
    print(f"5-fold CV ROC-AUC: {scores.mean():.3f} +/- {scores.std():.3f}")

    # Now fit on all training data and persist the fitted pipeline.
    pipe.fit(X_train, y_train)
    joblib.dump({"pipeline": pipe, "X_test": X_test, "y_test": y_test}, MODEL_PATH)
    print(f"Saved model to {MODEL_PATH.resolve()}")


if __name__ == "__main__":
    main()
```

`split()` is the only place the split arguments live. The exporter below calls it too, so the C# side gets exactly these rows.

### `src/clf/evaluate.py`

```python
# src/clf/evaluate.py
"""Touch the test set ONCE, here, to get the honest final numbers."""
from __future__ import annotations

import joblib
from sklearn.metrics import (
    classification_report,
    confusion_matrix,
    roc_auc_score,
)

from clf.train import MODEL_PATH


def main() -> None:
    bundle = joblib.load(MODEL_PATH)
    pipe, X_test, y_test = bundle["pipeline"], bundle["X_test"], bundle["y_test"]

    preds = pipe.predict(X_test)
    proba = pipe.predict_proba(X_test)[:, 1]  # probability of the positive class

    print("Confusion matrix [[TN FP] [FN TP]]:")
    print(confusion_matrix(y_test, preds))
    print()
    print(classification_report(y_test, preds, digits=3))
    print(f"ROC-AUC on held-out test: {roc_auc_score(y_test, proba):.3f}")


if __name__ == "__main__":
    main()
```

### `src/clf/serve.py`

```python
# src/clf/serve.py
"""Serve predict behind FastAPI. The model is loaded once, at import."""
from __future__ import annotations

import joblib
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from clf.train import MODEL_PATH

app = FastAPI(title="Tumor classifier")
_bundle = joblib.load(MODEL_PATH)
_pipe = _bundle["pipeline"]
_N_FEATURES = int(_pipe.named_steps["scale"].n_features_in_)


class PredictRequest(BaseModel):
    rows: list[list[float]]   # one feature vector per row, each exactly _N_FEATURES long


class PredictResponse(BaseModel):
    labels: list[int]
    probabilities: list[float]


@app.get("/health")
def health() -> dict[str, str | int]:
    return {"status": "ok", "expected_features": _N_FEATURES}


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest) -> PredictResponse:
    # Validate at the boundary. Without this, a short row reaches sklearn, which raises
    # ValueError, and FastAPI turns it into a 500: the client's mistake reported as ours.
    if not req.rows or any(len(r) != _N_FEATURES for r in req.rows):
        raise HTTPException(status_code=400, detail=f"each row must have exactly {_N_FEATURES} numbers")
    labels = _pipe.predict(req.rows)
    proba = _pipe.predict_proba(req.rows)[:, 1]
    return PredictResponse(
        labels=[int(x) for x in labels],
        probabilities=[float(p) for p in proba],
    )
```

The length check is the step that matters. Without it, a row with the wrong number of features reaches scikit-learn, which raises `ValueError`, and FastAPI reports it as a 500: the client's mistake logged as your outage. Checking at the boundary turns it into a 400 with a message the caller can act on, which is also what the C# service does. Pydantic could enforce the shape too, but it answers with FastAPI's 422, and the contract both services share is 400.

### `tests/test_train.py`

```python
# tests/test_train.py
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

from clf.train import build_pipeline, load_data, split


def test_pipeline_beats_coin_flip() -> None:
    X, y = load_data()
    # A different seed from train.py's split: the floor should hold for any reasonable split.
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=0, stratify=y
    )
    pipe = build_pipeline()
    pipe.fit(X_train, y_train)
    proba = pipe.predict_proba(X_test)[:, 1]
    # A trivial sanity gate: a real model must clear 0.5 (chance) comfortably.
    assert roc_auc_score(y_test, proba) > 0.9


def test_pipeline_has_scaler_before_model() -> None:
    steps = [name for name, _ in build_pipeline().steps]
    assert steps == ["scale", "model"]  # scaling inside the pipeline = no leakage


def test_split_sizes_match_the_csharp_fixtures() -> None:
    X_train, X_test, _, _ = split(*load_data())
    assert (len(X_train), len(X_test)) == (455, 114)   # TrainingTests.cs pins the same numbers
```

> Note the test style from module 09: we assert a *quality floor* (`> 0.9`), not an exact number. Model outputs vary slightly across library versions and platforms; pinning an exact score makes a brittle test.

### `tests/test_serve.py`

The HTTP contract gets its own tests, run in-process with FastAPI's `TestClient` (it drives the app through `httpx`, which is why `httpx` is a dev dependency). No server, no port.

```python
# tests/test_serve.py
"""The HTTP contract, in-process: FastAPI's TestClient drives the app through httpx, no server."""
import importlib
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from clf import train


@pytest.fixture(scope="module")
def client(tmp_path_factory: pytest.TempPathFactory) -> Iterator[TestClient]:
    # serve.py loads model.joblib from the working directory at import, so train into a
    # temp folder and import from there. Your real model.joblib is never touched.
    with pytest.MonkeyPatch.context() as mp:
        mp.chdir(tmp_path_factory.mktemp("model"))
        train.main()
        serve = importlib.import_module("clf.serve")
    with TestClient(serve.app) as c:
        yield c


def test_health_reports_feature_count(client: TestClient) -> None:
    assert client.get("/health").json() == {"status": "ok", "expected_features": 30}


def test_predict_returns_a_label_and_probability_per_row(client: TestClient) -> None:
    X, _ = train.load_data()
    body = client.post("/predict", json={"rows": X[:3].tolist()}).json()
    assert len(body["labels"]) == len(body["probabilities"]) == 3
    assert all(label in (0, 1) for label in body["labels"])
    assert all(0.0 <= p <= 1.0 for p in body["probabilities"])


@pytest.mark.parametrize("rows", [[[1.0, 2.0]], []])   # wrong feature count; no rows at all
def test_bad_rows_are_a_400_not_a_500(client: TestClient, rows: list[list[float]]) -> None:
    r = client.post("/predict", json={"rows": rows})
    assert r.status_code == 400
    assert "30" in r.json()["detail"]
```

### `src/clf/export_fixtures.py`

New for the two-language build. The C# side can't call `load_breast_cancer()`, so Python writes the data to CSV once and the files get committed. It writes the *split*, not just the data, by calling `train.py`'s `split()`. That way both languages train on the same 455 rows and get scored on the same 114. The repo `.gitignore` ignores `*.csv` everywhere except under `fixtures/`, `samples/` and `test_data/`, which is why the files go in `fixtures/`. That's the shared folder at the project root (`projects/14-classical-ml/fixtures/`), and the two CSVs are committed there, once, for both languages. Like every project with fixtures, it honours `FIXTURES_DIR` ([conventions](conventions.md#project-layout)).

```python
# src/clf/export_fixtures.py
"""Write the breast-cancer train/test split to CSV: the data contract for the C# side."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

import numpy as np

from clf.train import load_data, split


def _write(path: Path, X: np.ndarray, y: np.ndarray) -> None:
    header = ",".join([f"f{i}" for i in range(X.shape[1])] + ["label"])
    # %.17g round-trips a float64 exactly; the label prints as 0 or 1.
    np.savetxt(path, np.column_stack([X, y]), delimiter=",", header=header, comments="", fmt="%.17g")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    # FIXTURES_DIR if set, else the shared project-root fixtures/ (relative to python/, where you run this).
    default_dir = Path(os.environ.get("FIXTURES_DIR", "../fixtures"))
    parser.add_argument("--out-dir", type=Path, default=default_dir)
    args = parser.parse_args(argv)

    X_train, X_test, y_train, y_test = split(*load_data())   # the same split train.py uses
    args.out_dir.mkdir(parents=True, exist_ok=True)
    _write(args.out_dir / "breast_cancer_train.csv", X_train, y_train)
    _write(args.out_dir / "breast_cancer_test.csv", X_test, y_test)
    print(f"Wrote {len(y_train)} train / {len(y_test)} test rows to {args.out_dir.resolve()}")


if __name__ == "__main__":
    main()
```

```powershell
uv run python -m clf.export_fixtures   # run from python/; writes ../fixtures/*.csv (commit them)
```

### Run it locally

```powershell
cd projects/14-classical-ml/python
uv sync
uv run pytest                         # 7 tests
uv run python -m clf.train            # prints CV score, saves model.joblib
uv run python -m clf.evaluate         # prints confusion matrix + report
uv run uvicorn clf.serve:app --port 8000
# in another shell (curl.exe: in Windows PowerShell 5.1, plain `curl` is Invoke-WebRequest)
curl.exe -s localhost:8000/health
```

A run on scikit-learn 1.9 prints a CV ROC-AUC of 0.993 ± 0.011, a test confusion matrix of `[[41 1] [1 71]]` and a test ROC-AUC of 0.995. Yours may differ in the third decimal.

### Running the Python version in Docker

`Dockerfile` (and the scaffold's `Dockerfile.dockerignore` next to it):

```dockerfile
# projects/14-classical-ml/python/Dockerfile. Build context: python/ (load_breast_cancer is bundled, so no fixtures needed)
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /app
# Library pattern: dependencies first (cached layer), then README.md + code, then install the project.
# --no-dev: a serving image needs neither pytest nor skl2onnx.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-install-project --no-dev
COPY src/ ./src/
RUN uv sync --frozen --no-dev
# Train at build time so the image ships with a ready model.joblib.
# (For real work you'd train separately and COPY the artifact in: see below.)
RUN uv run --no-sync python -m clf.train
EXPOSE 8000
CMD ["uv", "run", "--no-sync", "uvicorn", "clf.serve:app", "--host", "0.0.0.0", "--port", "8000"]
```

From the repo root:

```powershell
docker build -t clf-py projects/14-classical-ml/python
docker run --rm -p 8000:8000 clf-py
docker run --rm clf-py uv run --no-sync python -m clf.evaluate   # the one look at the test set, in the container
```

> Baking `train` into the build keeps the demo one-command-simple, but it couples model version to image version. In real life, **training and serving are separate concerns**: train produces a versioned `model.joblib` artifact (stored in S3 or an artifact registry), and the serving image `COPY`s or downloads a specific version at deploy. Decoupling them lets you roll the model back without rebuilding the app — the same instinct as separating config from code.

## C# implementation

Work in `projects/14-classical-ml/csharp/`. Same workflow (train, evaluate, serve), same test rows, same `/health` and `/predict` contract. What differs:

- **The library.** ML.NET (`Microsoft.ML`) is .NET's classical-ML framework, and it has scikit-learn's shape: estimators you fit, transformers you apply, and a chain that is itself an estimator. The split between `IEstimator<ITransformer>` (unfitted) and `ITransformer` (fitted) is the concept section's `Pipeline` made explicit in types. Leakage safety works the same way.
- **The data.** ML.NET has no bundled datasets, so it loads the CSV fixtures the Python exporter wrote. Same file, same split, so the test rows are identical.
- **The schema is a class.** ML.NET reads columns into a plain class marked with attributes (`[LoadColumn]`, `[VectorType]`). It needs a parameterless constructor and settable properties, so this is one place records don't fit.
- **Serving.** An ASP.NET Core minimal API instead of FastAPI. `PredictionEngine` is **not thread-safe**, so a web app uses `PredictionEnginePool` from `Microsoft.Extensions.ML`. That's the DI-registered, per-request-safe wrapper.
- **Retraining gives close numbers, not identical ones.** The solver internals differ, regularization is scaled differently from scikit-learn's `C`, and the CV folds are different. If you need the *same* model in both languages, don't retrain. Export the scikit-learn pipeline to ONNX and score it from .NET. The optional last section does that.

### Scaffold

From the repo root, run the C# bootstrap script with the web API template (see [project bootstrap automation](project-bootstrap-automation.md)). You get `ClassicalMl.slnx`, a `net10.0` web API in `src/ClassicalMl`, an NUnit test project in `tests/ClassicalMl.Tests`, `Directory.Build.props` and a `Dockerfile.dockerignore`. You replace the template's `Program.cs` below; delete its `ClassicalMl.http` (it calls the weather endpoint). Then add the packages:

```powershell
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 14-classical-ml -Template webapi -Name ClassicalMl
cd projects/14-classical-ml/csharp
dotnet add src/ClassicalMl package Microsoft.ML                  # 5.0.0 when this was built
dotnet add src/ClassicalMl package Microsoft.Extensions.ML       # 5.0.0
dotnet add src/ClassicalMl package Microsoft.ML.OnnxRuntime      # 1.30.0; only for the optional ONNX section
```

Then run the Python exporter once (`uv run python -m clf.export_fixtures` from `python/`) so the project-root `fixtures/` exists, and commit the two CSVs.

### `src/ClassicalMl/Fixtures.cs` — finding the shared data

The C# side reads the CSVs straight from the shared `fixtures/` folder, with no copy in the build output. `FIXTURES_DIR` wins when it's set (containers set `/app/fixtures`). Otherwise it walks up from the bin folder to the folder holding `ClassicalMl.slnx` and takes `../fixtures`, so `dotnet run` and NUnit (which runs from the test bin folder) both find it. It's the same rule as module 09's harness, and module 15 reuses it.

```csharp
// src/ClassicalMl/Fixtures.cs
namespace ClassicalMl;

/// <summary>The shared projects/14-classical-ml/fixtures/ folder. Containers set FIXTURES_DIR=/app/fixtures.</summary>
public static class Fixtures
{
    public static string Dir { get; } = Environment.GetEnvironmentVariable("FIXTURES_DIR") ?? FindDefault();

    public static string PathFor(string name) => Path.Combine(Dir, name);

    // dotnet run and dotnet test both start in a bin/ folder: walk up to the .slnx, then take ../fixtures.
    private static string FindDefault()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "ClassicalMl.slnx")))
                return Path.GetFullPath(Path.Combine(dir.FullName, "..", "fixtures"));
        return Path.GetFullPath("../fixtures");
    }
}
```

### `src/ClassicalMl/Schema.cs`

```csharp
// src/ClassicalMl/Schema.cs
using Microsoft.ML.Data;

namespace ClassicalMl;

/// <summary>One CSV row: 30 features, then the label. ML.NET maps columns by attribute.</summary>
public sealed class TumorRow
{
    [LoadColumn(0, 29), VectorType(30)]
    public float[] Features { get; set; } = [];

    // 1 = benign = the positive class, same as scikit-learn's target. The text loader reads
    // "0"/"1" as false/true (ML.NET 5.0); TrainingTests asserts both classes come through.
    [LoadColumn(30)]
    public bool Label { get; set; }
}

/// <summary>What the fitted pipeline adds. Column names are ML.NET's conventions.</summary>
public sealed class TumorPrediction
{
    [ColumnName("PredictedLabel")]
    public bool PredictedLabel { get; set; }

    public float Probability { get; set; }   // calibrated P(positive): predict_proba(...)[:, 1]
    public float Score { get; set; }         // raw margin before the sigmoid
}

/// <summary>Label next to prediction, for counting the confusion matrix ourselves.</summary>
public sealed class ScoredRow
{
    public bool Label { get; set; }
    public bool PredictedLabel { get; set; }
    public float Probability { get; set; }
}
```

### `src/ClassicalMl/Training.cs`

```csharp
// src/ClassicalMl/Training.cs
using Microsoft.ML;

namespace ClassicalMl;

/// <summary>Build a leakage-safe pipeline, cross-validate it, fit it, and save it.</summary>
public static class Training
{
    public const int FeatureCount = 30;

    /// <summary>
    /// Scale, then classify. Unfitted, like an sklearn Pipeline before fit(). The normalizer
    /// lives inside the chain, so Fit() learns its statistics from training data only.
    /// </summary>
    public static IEstimator<ITransformer> BuildPipeline(MLContext ml) =>
        // fixZero: false centres AND scales, like StandardScaler. The default (true) only scales.
        ml.Transforms.NormalizeMeanVariance("Features", fixZero: false)
            .Append(ml.BinaryClassification.Trainers.LbfgsLogisticRegression(
                labelColumnName: "Label",
                featureColumnName: "Features",
                // Pure L2, like sklearn's default penalty. Not on the same scale as sklearn's C.
                l1Regularization: 0f,
                l2Regularization: 1f));

    public static IDataView Load(MLContext ml, string csvPath) =>
        ml.Data.LoadFromTextFile<TumorRow>(csvPath, separatorChar: ',', hasHeader: true);

    public static void Run(string trainCsv, string modelPath)
    {
        var ml = new MLContext(seed: 42);
        IDataView train = Load(ml, trainCsv);   // the split already happened, in Python
        IEstimator<ITransformer> pipeline = BuildPipeline(ml);

        // Cross-validate on the TRAINING data only, before the one look at the test set.
        // Unlike cross_val_score on a classifier, these folds are not stratified.
        var folds = ml.BinaryClassification.CrossValidate(train, pipeline, numberOfFolds: 5, labelColumnName: "Label", seed: 42);
        double[] auc = folds.Select(f => f.Metrics.AreaUnderRocCurve).ToArray();
        Console.WriteLine($"5-fold CV ROC-AUC: {auc.Average():F3} +/- {PopulationStd(auc):F3}");

        // Fit on all training data and persist the fitted transformer chain.
        ITransformer model = pipeline.Fit(train);
        ml.Model.Save(model, train.Schema, modelPath);
        Console.WriteLine($"Saved model to {Path.GetFullPath(modelPath)}");
    }

    // numpy's .std() default (ddof=0), so the printed spread is comparable.
    private static double PopulationStd(double[] xs)
    {
        double mean = xs.Average();
        return Math.Sqrt(xs.Sum(x => (x - mean) * (x - mean)) / xs.Length);
    }
}
```

Want to see gradient boosting win (or not) on this data? Add `Microsoft.ML.FastTree` and swap the trainer for `ml.BinaryClassification.Trainers.FastTree(...)`. It's ML.NET's boosted-trees trainer, the counterpart of `HistGradientBoostingClassifier`. Everything else in the chain stays the same.

### `src/ClassicalMl/ConfusionCounts.cs`

ML.NET prints its own confusion table, but its layout differs from scikit-learn's (positive class first). Counting the four cells yourself gives you a pure, testable function and output you can compare line for line with the Python version.

```csharp
// src/ClassicalMl/ConfusionCounts.cs
namespace ClassicalMl;

/// <summary>The 2x2 confusion matrix as counts. Every classification metric is a summary of it.</summary>
public readonly record struct ConfusionCounts(int TruePositive, int FalsePositive, int FalseNegative, int TrueNegative)
{
    public double Precision => Ratio(TruePositive, TruePositive + FalsePositive);
    public double Recall => Ratio(TruePositive, TruePositive + FalseNegative);
    public double F1 => Precision + Recall == 0 ? 0 : 2 * Precision * Recall / (Precision + Recall);

    public static ConfusionCounts From(IEnumerable<(bool Actual, bool Predicted)> pairs)
    {
        int tp = 0, fp = 0, fn = 0, tn = 0;
        foreach (var (actual, predicted) in pairs)
        {
            switch (actual, predicted)
            {
                case (true, true): tp++; break;
                case (false, true): fp++; break;
                case (true, false): fn++; break;
                default: tn++; break;
            }
        }
        return new(tp, fp, fn, tn);
    }

    // scikit-learn's zero_division default: report 0, not NaN.
    private static double Ratio(int numerator, int denominator) =>
        denominator == 0 ? 0 : (double)numerator / denominator;
}
```

### `src/ClassicalMl/Evaluation.cs`

```csharp
// src/ClassicalMl/Evaluation.cs
using Microsoft.ML;

namespace ClassicalMl;

/// <summary>Touch the test set ONCE, here, to get the honest final numbers.</summary>
public static class Evaluation
{
    public static void Run(string testCsv, string modelPath)
    {
        var ml = new MLContext(seed: 42);
        ITransformer model = ml.Model.Load(modelPath, out _);
        IDataView scored = model.Transform(Training.Load(ml, testCsv));

        var counts = ConfusionCounts.From(
            ml.Data.CreateEnumerable<ScoredRow>(scored, reuseRowObject: false)
                .Select(r => (r.Label, r.PredictedLabel)));

        Console.WriteLine("Confusion matrix [[TN FP] [FN TP]]:");   // sklearn's layout
        Console.WriteLine($"[[{counts.TrueNegative} {counts.FalsePositive}]");
        Console.WriteLine($" [{counts.FalseNegative} {counts.TruePositive}]]");
        Console.WriteLine();
        Console.WriteLine($"class 1: precision={counts.Precision:F3} recall={counts.Recall:F3} f1={counts.F1:F3}");

        // ML.NET's own metrics should agree with the hand count above.
        var metrics = ml.BinaryClassification.Evaluate(scored, labelColumnName: "Label");
        Console.WriteLine($"ML.NET:  precision={metrics.PositivePrecision:F3} recall={metrics.PositiveRecall:F3} f1={metrics.F1Score:F3}");
        Console.WriteLine($"ROC-AUC on held-out test: {metrics.AreaUnderRocCurve:F3}");
        Console.WriteLine(metrics.ConfusionMatrix.GetFormattedConfusionTable());
    }
}
```

### `src/ClassicalMl/Program.cs`

One project with two jobs. The command-line verbs mirror the Python modules (`clf.train`, `clf.evaluate`). With no verb, it serves. `ConfigureHttpJsonOptions` with snake_case makes the JSON match FastAPI's field names exactly (`expected_features`), so the same client works against both services.

```csharp
// src/ClassicalMl/Program.cs
using System.Globalization;
using System.Text.Json;
using ClassicalMl;
using Microsoft.Extensions.ML;

CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;   // "0.957", never "0,957"

// The CSVs come from Fixtures.cs (FIXTURES_DIR, else the shared ../fixtures). The model sits next to the dll.
string modelPath = Environment.GetEnvironmentVariable("CLF_MODEL_PATH")
    ?? Path.Combine(AppContext.BaseDirectory, "model.zip");

switch (args)
{
    case ["train"]:
        Training.Run(Fixtures.PathFor("breast_cancer_train.csv"), modelPath);
        return 0;
    case ["evaluate"]:
        Evaluation.Run(Fixtures.PathFor("breast_cancer_test.csv"), modelPath);
        return 0;
    case ["onnx-check", var onnxPath]:   // optional section; drop this case if you skip it
        return OnnxCheck.Run(onnxPath, Fixtures.PathFor("breast_cancer_test.csv"));
}

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);

// The model is loaded once, like serve.py's module-level joblib.load. PredictionEngine isn't
// thread-safe; the pool hands each request an engine of its own.
builder.Services.AddPredictionEnginePool<TumorRow, TumorPrediction>()
    .FromFile(filePath: modelPath, watchForChanges: false);

var app = builder.Build();

app.MapGet("/health", () => new Health("ok", Training.FeatureCount));

app.MapPost("/predict", (PredictRequest req, PredictionEnginePool<TumorRow, TumorPrediction> pool) =>
{
    // Validate at the boundary. (The Python version lets sklearn throw, which FastAPI turns into a 500.)
    if (req.Rows is not { Count: > 0 } || req.Rows.Any(r => r.Length != Training.FeatureCount))
        return Results.BadRequest(new { detail = $"each row must have exactly {Training.FeatureCount} numbers" });

    var predictions = req.Rows.Select(r => pool.Predict(new TumorRow { Features = r })).ToList();
    return Results.Ok(new PredictResponse(
        predictions.Select(p => p.PredictedLabel ? 1 : 0).ToList(),
        predictions.Select(p => p.Probability).ToList()));
});

app.Run();
return 0;

record Health(string Status, int ExpectedFeatures);
record PredictRequest(IReadOnlyList<float[]> Rows);
record PredictResponse(IReadOnlyList<int> Labels, IReadOnlyList<float> Probabilities);
```

### `tests/ClassicalMl.Tests/ConfusionCountsTests.cs`

```csharp
// tests/ClassicalMl.Tests/ConfusionCountsTests.cs
using NUnit.Framework;

namespace ClassicalMl.Tests;

public class ConfusionCountsTests
{
    [Test]
    public void From_counts_each_cell()
    {
        var counts = ConfusionCounts.From([(true, true), (true, false), (false, true), (false, false), (false, false)]);
        Assert.That(counts, Is.EqualTo(new ConfusionCounts(TruePositive: 1, FalsePositive: 1, FalseNegative: 1, TrueNegative: 2)));
    }

    [TestCase(8, 2, 0, 0.8, 1.0)]
    [TestCase(0, 0, 5, 0.0, 0.0)]   // nothing flagged: precision is 0, not NaN
    public void Precision_and_recall(int tp, int fp, int fn, double precision, double recall)
    {
        var counts = new ConfusionCounts(tp, fp, fn, TrueNegative: 0);
        Assert.That(counts.Precision, Is.EqualTo(precision).Within(1e-9));
        Assert.That(counts.Recall, Is.EqualTo(recall).Within(1e-9));
    }
}
```

### `tests/ClassicalMl.Tests/TrainingTests.cs`

The fixture test pins the split. If someone regenerates the CSVs with different split arguments, it fails before any metric quietly drifts. It also checks that both classes survive the `"0"`/`"1"` → `bool` label parse. The quality test uses the same floor as the Python one.

```csharp
// tests/ClassicalMl.Tests/TrainingTests.cs
using Microsoft.ML;
using NUnit.Framework;

namespace ClassicalMl.Tests;

public class TrainingTests
{
    // Same lookup as the app: FIXTURES_DIR, else walk up from the test bin folder to ../fixtures.
    private static string Fixture(string name) => Fixtures.PathFor(name);

    [TestCase("breast_cancer_train.csv", 455)]
    [TestCase("breast_cancer_test.csv", 114)]
    public void Fixtures_match_the_python_split(string file, int expectedRows)
    {
        var ml = new MLContext();
        var rows = ml.Data.CreateEnumerable<TumorRow>(Training.Load(ml, Fixture(file)), reuseRowObject: false).ToList();
        Assert.That(rows, Has.Count.EqualTo(expectedRows));
        Assert.That(rows.All(r => r.Features.Length == Training.FeatureCount), Is.True);
        // The CSV label is "0"/"1"; if the loader misread it as bool, every row would land in one class.
        Assert.That(rows.Select(r => r.Label).Distinct().Count(), Is.EqualTo(2));
    }

    [Test]
    public void Pipeline_beats_coin_flip()
    {
        var ml = new MLContext(seed: 0);
        ITransformer model = Training.BuildPipeline(ml).Fit(Training.Load(ml, Fixture("breast_cancer_train.csv")));
        var metrics = ml.BinaryClassification.Evaluate(model.Transform(Training.Load(ml, Fixture("breast_cancer_test.csv"))));
        // A quality floor, not an exact number: same rule as the Python test.
        Assert.That(metrics.AreaUnderRocCurve, Is.GreaterThan(0.9));
    }
}
```

Delete the scaffold's `SmokeTests.cs` once these exist. Run locally, from `csharp/`:

```powershell
dotnet test                                          # 6 tests
dotnet run --project src/ClassicalMl -- train        # prints CV score, saves bin/.../model.zip
dotnet run --project src/ClassicalMl -- evaluate     # confusion matrix + metrics
$env:ASPNETCORE_URLS = 'http://localhost:8001'; dotnet run --project src/ClassicalMl --no-launch-profile   # serve on 8001
curl.exe -s localhost:8001/health
```

`--no-launch-profile` skips `launchSettings.json`, whose random port would otherwise win over `ASPNETCORE_URLS`. A run on ML.NET 5.0 prints a CV ROC-AUC of 0.995 ± 0.007 and the same `[[41 1] [1 71]]` test confusion matrix as Python.

### Running the C# version in Docker

Same multi-stage shape as module 04: the SDK image restores, builds and tests; the `aspnet` runtime image serves. Training runs at build time in the final stage, the same convenience (and the same coupling) as the Python image. The ML.NET model is a `model.zip`, which the repo's `.gitignore` already excludes with `*.zip`. It's a build output, not source.

The image needs the shared `fixtures/`, which sits outside `csharp/`. So the build context is the project root (`projects/14-classical-ml`) and the `COPY` paths start with `csharp/` or `fixtures/`. The ignore file is the scaffold's `Dockerfile.dockerignore` beside the Dockerfile: BuildKit reads it whatever the context, and its `**/` patterns match at any depth ([conventions](conventions.md#docker)). Add one line so the Python model stays out of the context:

```gitignore
# projects/14-classical-ml/csharp/Dockerfile.dockerignore (from the scaffold, plus *.joblib)
**/bin/
**/obj/
**/.vs/
**/models/
**/.venv/
**/__pycache__/
**/outputs/
**/runs/
**/*.joblib
```

```dockerfile
# projects/14-classical-ml/csharp/Dockerfile. Build context: projects/14-classical-ml (to reach fixtures/)
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app
# Restore on its own layer so package downloads cache across code changes.
COPY csharp/ClassicalMl.slnx csharp/Directory.Build.props csharp/
COPY csharp/src/ClassicalMl/ClassicalMl.csproj csharp/src/ClassicalMl/
COPY csharp/tests/ClassicalMl.Tests/ClassicalMl.Tests.csproj csharp/tests/ClassicalMl.Tests/
RUN dotnet restore csharp/ClassicalMl.slnx
COPY fixtures/ fixtures/
COPY csharp/ csharp/
RUN dotnet publish csharp/src/ClassicalMl -c Release -o /app/publish --no-restore

FROM build AS test
ENV FIXTURES_DIR=/app/fixtures
ENTRYPOINT ["dotnet", "test", "csharp/ClassicalMl.slnx", "--no-restore"]

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
COPY fixtures/ ./fixtures/
ENV FIXTURES_DIR=/app/fixtures
# Train at build time, as root, so the image ships with a ready model.zip (same trade-off as the Python image).
RUN ["dotnet", "ClassicalMl.dll", "train"]
USER $APP_UID
# The aspnet image listens on 8080; compose and `docker run` publish it on 8001.
EXPOSE 8080
ENTRYPOINT ["dotnet", "ClassicalMl.dll"]
```

Run these from the repo root. `-f` is resolved from your current directory, not from the build context:

```powershell
docker build -f projects/14-classical-ml/csharp/Dockerfile -t clf-cs projects/14-classical-ml
docker run --rm -p 8001:8080 clf-cs
docker run --rm clf-cs evaluate

docker build -f projects/14-classical-ml/csharp/Dockerfile --target test -t clf-cs-test projects/14-classical-ml
docker run --rm clf-cs-test
```

Logistic regression via L-BFGS is managed code. If you swap in a trainer that needs a native library and it fails to load in the container, the usual fix is installing the missing OS package (often `libgomp1`) in the final stage. Check the trainer's docs.

### Optional: score the Python model from C# with ONNX

Retraining in ML.NET gives you a second model that is *similar* to the first. Often you want the *same* model: data scientists train in Python, and the .NET service just runs what they shipped. **ONNX** is the contract for that. It's a portable model file format that both ecosystems read. `skl2onnx` converts the fitted scikit-learn pipeline, scaler included, and `Microsoft.ML.OnnxRuntime` runs it in .NET.

In `python/`, add the converter as a dev dependency (`uv add --dev skl2onnx`) and add `src/clf/export_onnx.py`:

```python
# src/clf/export_onnx.py
"""Export the fitted sklearn pipeline to ONNX, plus sklearn's own probabilities to check against."""
from __future__ import annotations

from pathlib import Path

import joblib
import numpy as np
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType

from clf.train import MODEL_PATH

OUT_DIR = Path("../csharp/models")   # gitignored and dockerignored: model artifacts stay out of git


def main() -> None:
    bundle = joblib.load(MODEL_PATH)
    pipe, X_test = bundle["pipeline"], bundle["X_test"]
    n_features = int(pipe.named_steps["scale"].n_features_in_)

    onx = convert_sklearn(
        pipe,
        initial_types=[("input", FloatTensorType([None, n_features]))],
        # zipmap=False: probabilities come out as a plain [rows, classes] tensor, not a list of dicts.
        options={id(pipe.named_steps["model"]): {"zipmap": False}},
    )
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # The stubs type the result as a union; for a pipeline it is always an ONNX ModelProto.
    (OUT_DIR / "clf.onnx").write_bytes(onx.SerializeToString())  # pyright: ignore[reportAttributeAccessIssue]

    # sklearn's answer for the test rows, in the same order as breast_cancer_test.csv.
    np.savetxt(OUT_DIR / "clf_expected_proba.csv", pipe.predict_proba(X_test)[:, 1],
               header="proba", comments="", fmt="%.9g")
    print(f"Wrote {OUT_DIR.resolve()}")


if __name__ == "__main__":
    main()
```

Then `src/ClassicalMl/OnnxScorer.cs`. It's the same `InferenceSession` pattern as module 03's embedder, with a much smaller model. `onnx-check` exits non-zero when the difference is over tolerance, so it can gate a pipeline:

```csharp
// src/ClassicalMl/OnnxScorer.cs
using System.Globalization;
using Microsoft.ML;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ClassicalMl;

/// <summary>Runs the scikit-learn pipeline exported by export_onnx.py. No retraining.</summary>
public sealed class OnnxScorer(string modelPath) : IDisposable
{
    private readonly InferenceSession _session = new(modelPath);

    public float[] PositiveProbabilities(float[][] rows)
    {
        int n = rows.Length, d = rows[0].Length;
        var input = new DenseTensor<float>(rows.SelectMany(r => r).ToArray(), [n, d]);

        // "input" is the name we gave in initial_types. Output names come from skl2onnx:
        // list them with _session.OutputMetadata.Keys if this lookup fails.
        using var results = _session.Run([NamedOnnxValue.CreateFromTensor("input", input)]);
        Tensor<float> proba = results.First(r => r.Name == "probabilities").AsTensor<float>();
        return Enumerable.Range(0, n).Select(i => proba[i, 1]).ToArray();
    }

    public void Dispose() => _session.Dispose();
}

public static class OnnxCheck
{
    // Same model, float32 inside ONNX vs float64 in sklearn: expect about 1e-7, allow 1e-5.
    // Anything above 1e-3 is a conversion bug (wrong input order, a lost scaler), not rounding.
    private const float Tolerance = 1e-5f;

    public static int Run(string onnxPath, string testCsv)
    {
        var ml = new MLContext();
        float[][] rows = ml.Data.CreateEnumerable<TumorRow>(Training.Load(ml, testCsv), reuseRowObject: false)
            .Select(r => r.Features).ToArray();
        float[] expected = File.ReadLines(Path.Combine(Path.GetDirectoryName(onnxPath)!, "clf_expected_proba.csv"))
            .Skip(1).Select(l => float.Parse(l, CultureInfo.InvariantCulture)).ToArray();

        using var scorer = new OnnxScorer(onnxPath);
        float[] actual = scorer.PositiveProbabilities(rows);

        float maxDiff = actual.Zip(expected, (a, e) => Math.Abs(a - e)).Max();
        Console.WriteLine($"{rows.Length} rows, max |p_onnx - p_sklearn| = {maxDiff:E2} (tolerance {Tolerance:E0})");
        return maxDiff <= Tolerance ? 0 : 1;
    }
}
```

```powershell
# in python/
uv run python -m clf.train; uv run python -m clf.export_onnx
# in csharp/
dotnet run --project src/ClassicalMl -- onnx-check "${PWD}/models/clf.onnx"
```

On the built versions (skl2onnx 1.20, ONNX Runtime 1.30) this prints `114 rows, max |p_onnx - p_sklearn| = 1.19E-007 (tolerance 1E-005)`.

`models/` is in both `.gitignore` and `Dockerfile.dockerignore`, so this path is local-only by design. In production the `.onnx` file is a versioned artifact in S3 that the service downloads at startup, just like `model.joblib`.

## Cross-check the two

Run `evaluate` on both sides, then send the same `/predict` request to both services. Locally (Python on 8000, C# on 8001 as above) or in containers:

```powershell
docker run --rm clf-py uv run --no-sync python -m clf.evaluate
docker run --rm clf-cs evaluate
```

Build the request from the first 5 test rows. Let Python write the file, rather than redirecting with `>`: Windows PowerShell 5.1 writes redirected output as UTF-16, which neither server parses.

```powershell
# from python/
uv run python -c "import json, pathlib, numpy as np; r = np.loadtxt('../fixtures/breast_cancer_test.csv', delimiter=',', skiprows=1); pathlib.Path('sample.json').write_text(json.dumps({'rows': r[:5, :-1].tolist()}))"

curl.exe -s localhost:8000/predict -H "content-type: application/json" -d '@sample.json'   # Python
curl.exe -s localhost:8001/predict -H "content-type: application/json" -d '@sample.json'   # C#
curl.exe -s -w ' %{http_code}' localhost:8000/predict -H "content-type: application/json" -d '{"rows": [[1, 2]]}'   # 400
curl.exe -s -w ' %{http_code}' localhost:8001/predict -H "content-type: application/json" -d '{"rows": [[1, 2]]}'   # 400
```

Quote `'@sample.json'`: unquoted, pwsh reads `@sample` as splatting and refuses to parse the line. The inline JSON relies on pwsh 7.3 or later, which passes the inner double quotes through to `curl.exe`; Windows PowerShell 5.1 strips them. (*bash / WSL / Git Bash*: `-d @sample.json` works unquoted.)

What should agree, and how closely:

- **Row counts and the split** must match **exactly**: 455 train, 114 test. Both sides read the same rows. A mismatch means the fixtures are stale or the split arguments drifted.
- **The `/health` and `/predict` JSON shape** must match exactly. Same field names, same types, so one client works against both.
- **Error behavior** must match: a row with the wrong feature count, or no rows at all, is a 400 with a `detail` message from both. The one difference left is the framework's own: a body that isn't valid JSON at all gets FastAPI's 422 and ASP.NET Core's 400.
- **Retrained metrics** (CV AUC, test confusion matrix, precision/recall) should be **close, not identical**. Expect test AUC within about 0.01, and maybe a borderline row or two landing in a different cell. The algorithm is the same (L2 logistic regression via L-BFGS), but the regularization is scaled differently, convergence tolerances differ, ML.NET works in `float32`, and its CV folds aren't the same (or stratified). If the gap is large, check the normalizer first: `NormalizeMeanVariance` with the default `fixZero: true` doesn't centre the data, so it isn't `StandardScaler`. On the built versions the test matrices matched and the five sample probabilities agreed to about 0.003.
- **The ONNX route** should give **identical labels** and probabilities within about `1e-5` (the built run showed `1.2e-7`). It's the same fitted model; the only difference is `float32` inside ONNX vs `float64` in scikit-learn. Anything above `1e-3` is a bug, not noise: the conversion went wrong (a lost scaler, columns in a different order).

| Concern | Python | C# / .NET |
|---|---|---|
| Library | scikit-learn | ML.NET (`Microsoft.ML`) |
| Dataset | `load_breast_cancer()` (bundled) | CSV fixtures exported from Python |
| Pipeline | `Pipeline([...])`, one object before and after `fit` | `IEstimator<ITransformer>` chain via `.Append`, `Fit` returns `ITransformer` |
| Scaling | `StandardScaler` | `NormalizeMeanVariance(fixZero: false)` |
| Model | `LogisticRegression` (lbfgs) | `LbfgsLogisticRegression` (`FastTree` for boosting) |
| Cross-validation | `cross_val_score` (stratified for classifiers) | `BinaryClassification.CrossValidate` (not stratified) |
| Metrics | `sklearn.metrics` | `BinaryClassification.Evaluate` → `CalibratedBinaryClassificationMetrics` |
| Persistence | `joblib` (pickle: loading it runs code) | `model.zip` via `ml.Model.Save` |
| Serving | FastAPI + Pydantic, explicit 400 | minimal API + `PredictionEnginePool`, explicit 400 |
| Same model in both | n/a | `skl2onnx` → `Microsoft.ML.OnnxRuntime` |
| Tests | `pytest` + `TestClient` | NUnit (`Assert.That`, `[TestCase]`) |

## Optional exercise: measure "not everything should be an LLM"

This module argues that an embedding plus logistic regression beats an LLM call for many classification jobs. That's a claim, and module 09 taught you not to trust claims you haven't measured. This exercise is optional, Python only, and builds nothing later modules need.

Write `compare_llm.py` (an exercise, so it's not shown) that runs two classifiers over the same small labeled **text** set, for example two categories of `sklearn.datasets.fetch_20newsgroups` (a one-time download), or 200 rows you label yourself:

1. **Embed + logistic regression.** Embed each text (module 07's embedder, or Ollama's embeddings endpoint with `OLLAMA_EMBED_MODEL`), then reuse this module's pipeline on the vectors: split, cross-validate, fit, score the test rows.
2. **LLM classifier.** Add module 04's client as a path dependency (`uv add --editable ../../04-llm-client/python`), call `client_from_env()`, and ask for exactly one label per text. Parse the reply strictly; an unparseable reply counts as wrong.

Score both on the same test rows with a module 09-style scorecard: accuracy and macro-F1, p50/p95 latency per item, and cost per 1,000 items (the 04 client's `llm_call` log gives you the tokens). Run it with `$env:LLM_BACKEND = 'ollama'` for real numbers. On `stub` the LLM column is meaningless: the stub echoes, so it only proves the plumbing. Its acceptance test runs on `stub` with `$env:LLM_STUB_REPLY` set to one of the labels, and asserts the scorecard has a row per system with every metric filled in.

Expect the classical row to be close on quality and orders of magnitude ahead on latency and cost. If the LLM wins clearly on quality, that's a finding too: it tells you the task needs more than the embedding captures.

## Moving to AWS

Two honest paths, and the cheaper one is right more often than beginners think:

- **Just package the model in a container (usually enough).** Your `serve.py` image is already an ECS/Fargate task or a container-image Lambda. Store the `model.joblib` in **S3**, download it at container start (or bake a pinned version in), and you have a scalable prediction service with the deployment story from module 12. For most classical models this is all you need — the model is a few megabytes and inference is a CPU microsecond.
- **SageMaker** when you want the managed ML platform. **SageMaker Training** runs your `train.py` on managed instances and drops the artifact in S3; **SageMaker Endpoints** host it behind a managed, autoscaling HTTPS endpoint with A/B traffic splitting and monitoring. The cost is more moving parts and a steeper learning curve. **SageMaker Batch Transform** is the right tool when you don't need real-time answers — score a giant file overnight and write results back to S3, far cheaper than a live endpoint you poll.

The senior decision: don't reach for SageMaker because it's the "ML service." Reach for it when you need managed training on big data, managed autoscaling endpoints, or its monitoring — otherwise your plain container on ECS is simpler, cheaper, and something your team already knows how to operate. (Check current AWS docs for exact SageMaker SDK shapes; they change.)

Per language:

- **Python:** the container path above, or SageMaker. SageMaker's training and hosting SDK is Python-first, and its built-in scikit-learn containers expect a Python model.
- **C#:** the container path works the same. The `clf-cs` image is an ECS/Fargate task, and `model.zip` lives in S3, downloaded at startup with the `AWSSDK.S3` package before the `PredictionEnginePool` loads it. There's no first-class SageMaker story for ML.NET (you'd bring your own container), so the common split in a .NET shop is to **train in Python** (locally or on SageMaker Training), **export to ONNX**, and **serve from the .NET service** with ONNX Runtime. That keeps the model in the ecosystem built for training and the serving code in the one your team already operates.

## How experts think / pitfalls

- **Baseline first, always.** Before any fancy model, get logistic regression (or even "predict the majority class") working end to end with real evaluation. If your gradient-boosted monster can't beat the baseline, the problem is your features or your data, not your model.
- **Accuracy is a trap on imbalanced data.** Fraud, churn, defects — the interesting class is rare. Always look at the confusion matrix and pick precision/recall/AUC per the cost of each error.
- **Leakage is the silent killer.** If your offline numbers are suspiciously great, suspect leakage before celebrating. Common culprits: fitting scalers before splitting, a feature that encodes the answer (a "closed_date" column when predicting whether a ticket will close), or time-series data split randomly instead of by time.
- **`fit` on train, `transform` on both.** Say it in your sleep. The `Pipeline` enforces it; hand-rolled preprocessing does not.
- **Don't tune against the test set.** The moment you make decisions based on the test score, it's no longer a held-out estimate — it's just another validation set you've overfit to. Tune with cross-validation; spend the test set once.
- **Simpler and explainable often wins the argument.** A regulator, a customer-success team, or an incident review will thank you for a model whose decisions you can explain. "The LLM said so" is a bad answer in a compliance meeting.
- **Reproducibility: set `random_state`.** Splits, model initialization, and CV all have randomness. Pin the seed so runs are comparable and bugs are reproducible.
- **Share the model, not the recipe, when the numbers must match.** Retraining "the same pipeline" in another library gives you a sibling model, not a copy. Defaults differ in ways you won't spot by reading the code (ML.NET's normalizer doesn't centre by default; regularization scales differ). If two services must give the same answer, ship one trained artifact (ONNX) and run it in both. A pickle is code that runs on load. ONNX and `model.zip` are just data, which is one more reason to prefer them across a trust boundary.
- **`PredictionEngine` is not thread-safe.** Making it a singleton in a web app works on your machine and corrupts results under load. Use `PredictionEnginePool`. It's the ML.NET version of "don't share a `DbContext` across requests."

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Cross-check:** verify the track's `agreement.py` against `sklearn.metrics.cohen_kappa_score` on your label files.
- **Reframe:** your review labels are a classification problem. Build a confusion matrix of you vs the LLM judge and see which label pairs they confuse; those are your rubric's ambiguous lines.
- **Watch for:** data leakage in agent-written pipelines (fitting the scaler before the split). It's the classical-ML cousin of reward hacking: a great score that measures nothing.
- **C#-specific watch:** ML.NET changed a lot before 1.0, and agents still mix in pre-1.0 APIs: `LearningPipeline`, `Microsoft.ML.Legacy`, `ml.BinaryClassification.Trainers.LogisticRegression()` (now `LbfgsLogisticRegression`), `StochasticDualCoordinateAscent` (now `SdcaLogisticRegression` / `SdcaNonCalibrated`). Also check for a singleton `PredictionEngine` in web code, normalizer defaults (`fixZero`), and invented metric property names on `CalibratedBinaryClassificationMetrics`. On the Python side of the ONNX bridge, `skl2onnx` option names (`zipmap`) and output names are easy to get confidently wrong. Print `InferenceSession.OutputMetadata` rather than trusting them. The code in this doc is no exception: verify it.

## Checkpoint

You're ready for module 15 when you can, without looking things up:

- Given a product ask, argue whether it's a classical-ML problem or an LLM problem, and name the algorithm you'd baseline with.
- Explain supervised vs unsupervised and classification vs regression with an example of each.
- Describe data leakage, give a concrete example, and explain how a scikit-learn `Pipeline` prevents it.
- Explain `fit` / `predict` / `transform` and why a `Pipeline` is itself an estimator.
- Look at a confusion matrix and say what precision, recall, and F1 each measure and when you'd optimize which.
- Explain overfitting, and how cross-validation gives an honest quality estimate.
- Explain how an embedding becomes a feature vector for a classical classifier, and why you'd do that.
- Name three places classical ML supports an LLM system (routing, guardrails, reranking, triage).
- Serve a trained model behind FastAPI in Docker, and describe when you'd use SageMaker vs a plain container on AWS.
- Run `evaluate` and `/predict` through both the Python and C# containers. Say which numbers must match exactly (split, JSON shape, ONNX labels), which only approximately (retrained ML.NET metrics), and why.
- Send both services a row with the wrong number of features, get a 400 from each, and explain why a 500 there would be the wrong contract.
- Explain the difference between `IEstimator` and `ITransformer` in ML.NET, why a web app needs `PredictionEnginePool`, and when you'd ship an ONNX file instead of retraining in .NET.

## Going deeper

Search terms and topics when you want more (verify against current docs — libraries move):

- "scikit-learn user guide" — the whole thing is well written; the "Pipeline and composite estimators" and "model evaluation" sections especially.
- "XGBoost" / "LightGBM" docs — the gradient-boosting libraries you'll reach for on real tabular data.
- "imbalanced-learn" (the `imblearn` library) — resampling and techniques for rare-class problems.
- "SHAP values" — the standard modern way to explain *why* a tree model made a prediction (feature attributions).
- "scikit-learn ColumnTransformer" — applying different preprocessing to numeric vs categorical columns inside one pipeline.
- "cross-validation strategies" — `StratifiedKFold`, `TimeSeriesSplit` (crucial for time-ordered data — never split it randomly).
- "SageMaker Python SDK" — training jobs, endpoints, and batch transform, when you outgrow a plain container.
- "ML.NET binary classification tutorial" and "ML.NET data transforms": the official walkthroughs, and the reference for normalizer options like `fixZero`.
- "Microsoft.Extensions.ML PredictionEnginePool": thread-safe ML.NET prediction in ASP.NET Core, including model reload from a file or URI.
- "skl2onnx supported scikit-learn converters" and "ONNX Runtime C# API": which pipelines convert cleanly, and how to run them from .NET.

The math you *could* go learn but don't need to start: the sigmoid and log-loss behind logistic regression, information gain behind tree splits, gradient boosting's functional-gradient view. Name them, park them, revisit only if a specific problem forces you to.

*Last verified: 2026-10-05. Built: Python (pytest 7 passed, pyright and ruff clean; `train`, `evaluate`, `export_fixtures` and `export_onnx` run) and C# (dotnet test 6 passed; `train`, `evaluate` and `onnx-check` run) in a throwaway build, with scikit-learn 1.9.1, skl2onnx 1.20.0, ML.NET 5.0.0 and ONNX Runtime 1.30.0. Both services were served locally and the `/predict` cross-check matched (same labels for the 5 sample rows, 400 from both for bad rows). Read-only: the Docker images (Docker wasn't running) and the optional LLM-comparison exercise.*

**Verify on first build:**

- That ML.NET and ONNX Runtime load their native pieces in the `aspnet:10.0` image (`docker run --rm clf-cs evaluate`, then `onnx-check` if you mount `models/`). If a trainer's native library is missing, see the `libgomp1` note above.
- Whether pytest warns that Starlette's `TestClient` wants a different HTTP client package than `httpx`. The built version (FastAPI with Starlette current in 2026-10) printed a deprecation warning naming `httpx2`; the tests still pass. If your version has moved on, follow the warning and update the dev dependency.

Next: [15 — Deep learning intuition](15-deep-learning-intuition.md).
