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

The judgment: reach for classical ML when the task is a well-defined prediction over structured or embeddable inputs, you can get labeled data, and you need it cheap, fast, or explainable. Reach for the LLM when the task genuinely needs open-ended language generation or reasoning.

## The build project

**`projects/14-classical-ml/`** — train a classifier on a bundled tabular dataset with a proper scikit-learn `Pipeline`, evaluate it honestly (train/test split + cross-validation + a confusion matrix), and serve `predict` behind a small FastAPI endpoint. All in Docker. We use the classic **breast-cancer** dataset bundled with scikit-learn so there's no data to download and the example is fully reproducible — swap in your own CSV later.

### Layout

```
projects/14-classical-ml/
├── pyproject.toml
├── Dockerfile
├── README.md
├── src/
│   └── clf/
│       ├── __init__.py
│       ├── train.py        # build pipeline, cross-validate, fit, save model
│       ├── evaluate.py     # confusion matrix + report on held-out test set
│       └── serve.py        # FastAPI app loading the saved model
└── tests/
    └── test_train.py
```

### `pyproject.toml`

```toml
[project]
name = "clf"
version = "0.1.0"
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
dev = ["pytest>=8.2", "ruff>=0.5", "pyright>=1.1.370", "httpx>=0.27"]

[tool.pyright]
typeCheckingMode = "standard"   # sklearn's stubs are imperfect; "strict" fights you here
```

> Pythonism flag: scikit-learn's type stubs are incomplete, so unlike module 01 we run pyright in `standard` mode, not `strict`. This is a real-world compromise — the library predates modern typing. Keep your *own* code strictly typed.

### `src/clf/train.py`

```python
"""Build a leakage-safe pipeline, cross-validate it, fit it, and save it."""
from __future__ import annotations

from pathlib import Path

import joblib
import numpy as np
from sklearn.datasets import load_breast_cancer
from sklearn.model_selection import cross_val_score, train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

MODEL_PATH = Path("model.joblib")


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
    data = load_breast_cancer()
    return data.data, data.target


def main() -> None:
    X, y = load_data()

    # Split BEFORE touching the data for anything else. stratify keeps the
    # class balance the same in train and test.
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

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

### `src/clf/evaluate.py`

```python
"""Touch the test set ONCE, here, to get the honest final numbers."""
from __future__ import annotations

import joblib
from sklearn.metrics import (
    ConfusionMatrixDisplay,
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

    # Optional: write a PNG of the confusion matrix if matplotlib is present.
    try:
        import matplotlib.pyplot as plt  # noqa: PLC0415

        ConfusionMatrixDisplay.from_predictions(y_test, preds)
        plt.savefig("confusion_matrix.png", bbox_inches="tight")
        print("Wrote confusion_matrix.png")
    except ImportError:
        pass


if __name__ == "__main__":
    main()
```

### `src/clf/serve.py`

```python
"""Serve predict behind FastAPI. The model is loaded once at startup."""
from __future__ import annotations

import joblib
from fastapi import FastAPI
from pydantic import BaseModel, Field

from clf.train import MODEL_PATH

app = FastAPI(title="Tumor classifier")
_bundle = joblib.load(MODEL_PATH)
_pipe = _bundle["pipeline"]
_N_FEATURES = int(_pipe.named_steps["scale"].n_features_in_)


class PredictRequest(BaseModel):
    # A list of feature vectors; each must have exactly _N_FEATURES numbers.
    rows: list[list[float]] = Field(..., min_length=1)


class PredictResponse(BaseModel):
    labels: list[int]
    probabilities: list[float]


@app.get("/health")
def health() -> dict[str, str | int]:
    return {"status": "ok", "expected_features": _N_FEATURES}


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest) -> PredictResponse:
    labels = _pipe.predict(req.rows)
    proba = _pipe.predict_proba(req.rows)[:, 1]
    return PredictResponse(
        labels=[int(x) for x in labels],
        probabilities=[float(p) for p in proba],
    )
```

### `tests/test_train.py`

```python
from clf.train import build_pipeline, load_data
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score


def test_pipeline_beats_coin_flip() -> None:
    X, y = load_data()
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
```

> Note the test style from module 09: we assert a *quality floor* (`> 0.9`), not an exact number. Model outputs vary slightly across library versions and platforms; pinning an exact score makes a brittle test.

### Run it locally

```bash
cd projects/14-classical-ml
uv sync
uv run python -m clf.train        # prints CV score, saves model.joblib
uv run python -m clf.evaluate     # prints confusion matrix + report
uv run pytest
uv run uvicorn clf.serve:app --port 8000
# in another shell:
curl -s localhost:8000/health
```

### `Dockerfile`

```dockerfile
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY src/ ./src/
RUN uv sync --frozen

# Train at build time so the image ships with a ready model.joblib.
# (For real work you'd train separately and COPY the artifact in — see below.)
RUN uv run python -m clf.train

EXPOSE 8000
CMD ["uv", "run", "uvicorn", "clf.serve:app", "--host", "0.0.0.0", "--port", "8000"]
```

```bash
docker build -t clf projects/14-classical-ml
docker run --rm -p 8000:8000 clf
```

> Baking `train` into the build keeps the demo one-command-simple, but it couples model version to image version. In real life, **training and serving are separate concerns**: train produces a versioned `model.joblib` artifact (stored in S3 or an artifact registry), and the serving image `COPY`s or downloads a specific version at deploy. Decoupling them lets you roll the model back without rebuilding the app — the same instinct as separating config from code.

### Moving to AWS

Two honest paths, and the cheaper one is right more often than beginners think:

- **Just package the model in a container (usually enough).** Your `serve.py` image is already an ECS/Fargate task or a container-image Lambda. Store the `model.joblib` in **S3**, download it at container start (or bake a pinned version in), and you have a scalable prediction service with the deployment story from module 12. For most classical models this is all you need — the model is a few megabytes and inference is a CPU microsecond.
- **SageMaker** when you want the managed ML platform. **SageMaker Training** runs your `train.py` on managed instances and drops the artifact in S3; **SageMaker Endpoints** host it behind a managed, autoscaling HTTPS endpoint with A/B traffic splitting and monitoring. The cost is more moving parts and a steeper learning curve. **SageMaker Batch Transform** is the right tool when you don't need real-time answers — score a giant file overnight and write results back to S3, far cheaper than a live endpoint you poll.

The senior decision: don't reach for SageMaker because it's the "ML service." Reach for it when you need managed training on big data, managed autoscaling endpoints, or its monitoring — otherwise your plain container on ECS is simpler, cheaper, and something your team already knows how to operate. (Check current AWS docs for exact SageMaker SDK shapes; they change.)

## How experts think / pitfalls

- **Baseline first, always.** Before any fancy model, get logistic regression (or even "predict the majority class") working end to end with real evaluation. If your gradient-boosted monster can't beat the baseline, the problem is your features or your data, not your model.
- **Accuracy is a trap on imbalanced data.** Fraud, churn, defects — the interesting class is rare. Always look at the confusion matrix and pick precision/recall/AUC per the cost of each error.
- **Leakage is the silent killer.** If your offline numbers are suspiciously great, suspect leakage before celebrating. Common culprits: fitting scalers before splitting, a feature that encodes the answer (a "closed_date" column when predicting whether a ticket will close), or time-series data split randomly instead of by time.
- **`fit` on train, `transform` on both.** Say it in your sleep. The `Pipeline` enforces it; hand-rolled preprocessing does not.
- **Don't tune against the test set.** The moment you make decisions based on the test score, it's no longer a held-out estimate — it's just another validation set you've overfit to. Tune with cross-validation; spend the test set once.
- **Simpler and explainable often wins the argument.** A regulator, a customer-success team, or an incident review will thank you for a model whose decisions you can explain. "The LLM said so" is a bad answer in a compliance meeting.
- **Reproducibility: set `random_state`.** Splits, model initialization, and CV all have randomness. Pin the seed so runs are comparable and bugs are reproducible.

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

## Going deeper

Search terms and topics when you want more (verify against current docs — libraries move):

- "scikit-learn user guide" — the whole thing is well written; the "Pipeline and composite estimators" and "model evaluation" sections especially.
- "XGBoost" / "LightGBM" docs — the gradient-boosting libraries you'll reach for on real tabular data.
- "imbalanced-learn" (the `imblearn` library) — resampling and techniques for rare-class problems.
- "SHAP values" — the standard modern way to explain *why* a tree model made a prediction (feature attributions).
- "scikit-learn ColumnTransformer" — applying different preprocessing to numeric vs categorical columns inside one pipeline.
- "cross-validation strategies" — `StratifiedKFold`, `TimeSeriesSplit` (crucial for time-ordered data — never split it randomly).
- "SageMaker Python SDK" — training jobs, endpoints, and batch transform, when you outgrow a plain container.

The math you *could* go learn but don't need to start: the sigmoid and log-loss behind logistic regression, information gain behind tree splits, gradient boosting's functional-gradient view. Name them, park them, revisit only if a specific problem forces you to.

Next: [15 — Deep learning intuition](15-deep-learning-intuition.md).
