# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a **learning repository** for a senior/staff-level .NET engineer becoming an AI engineer. The goal is practical AI engineering skill — building real, working systems — **without** requiring a deep math or theoretical-ML background. Favor intuition, working code, and "why this matters in practice" over derivations and proofs.

### Learner profile & how to work with them

- **Background:** senior/staff-level .NET engineer. Assume strong software-engineering fundamentals — architecture, testing, CI, API design, debugging, source control. You do **not** need to explain those; you *can* explain new AI concepts by analogy to them.
- **Python:** the learner is language-agnostic and wants to *improve* Python, since it's the lingua franca of AI work. Prefer Python for AI/ML code and treat idiomatic Python (typing, virtualenvs, packaging, tooling) as something worth teaching in passing, not assuming.
- **Polyglot from module 03:** every project is built twice, Python first (the spec), then C#/.NET (a second, idiomatic implementation with the same behavior). The learner wants to be fully fluent in both. Don't port Python line by line into C#; write idiomatic .NET. See the "Two languages" section of [`docs/00-how-to-use-these-docs.md`](docs/00-how-to-use-these-docs.md).
- **Math/theory:** keep it light. Introduce a concept when it's needed to make a decision or debug something, at the level a working engineer needs — not a course in it.

### The curriculum

The learning path lives in [`docs/`](docs/README.md) — a build-first curriculum of 18 modules (00–17) taking the learner from Python foundations to a deployed, evaluated capstone, plus a parallel track **R — Reviewing AI-written code** ([`docs/R-reviewing-ai-written-code.md`](docs/R-reviewing-ai-written-code.md)) that runs alongside the modules; its long-lived project is `projects/review-lab/`. Start at [`docs/README.md`](docs/README.md). Each module ends with a hands-on project that belongs in `projects/<NN>-<name>/`. When helping with a module or its project, read that module's doc first so your guidance matches the curriculum's approach and vocabulary.

### Learning approach (important)

- **Learn by building.** Every topic should land as an actual project with **checked-in code**, not notebooks-as-scratch or throwaway snippets. Commit real, runnable examples.
- **Local first, then "pretend prod" in the cloud.** Develop and iterate **locally with Docker** for fast, cheap, reproducible loops. Once something works, the exercise is to **move it to AWS as a stand-in for production** — so treat deployability, packaging, and cloud services as part of the learning, not an afterthought.
- Prefer explaining trade-offs and pointing out where a decision matters, since the learner can handle depth on the engineering side.

## Current state

The curriculum docs (00–17 plus the R track) are written and **hardened** (branch `docs/hardening`, 2026-10). A full review ([`docs/readiness-checklist.md`](docs/readiness-checklist.md)) found ~120 issues; they're fixed or moved to a module's *Verify on first build* list.

- **Rules:** [`docs/conventions.md`](docs/conventions.md) is the single source for cross-module rules (backends, env vars, ports, compose, Docker, PyTorch wheels, shell commands, what a doc must show, module readiness). Module docs link to it instead of restating it. Decisions behind it are in [`docs/adr/`](docs/adr/) (ADR-001 backend contract, 002 runnable-spec rule, 003 module 12 deploys real RAG, 004 verification strategy).
- **How the module code was verified:** each module's code was built in a throwaway scratch project (never in `projects/`; the learner types every project), tests passing in both languages on `LLM_BACKEND=stub`, and the doc's code blocks were regenerated from the built files. Each module doc ends with a `Last verified:` line saying what was built vs read-only (Docker images, live models, AWS and model training were not run) and a **Verify on first build** list of API details no build covered.
- **When you change a module's code:** keep Python and C# in step, keep the stub cross-check exact, update its `Last verified:` line, and run the lint: `uv run --project tools/doccheck doccheck --strict`.
- **Module 07's service contract** (modules 08–12 and 17 call it via `RAG_URL`): `GET /health`, `POST /ingest[?folder=]`, `POST /ask {question, k}` → `{answer, citations: [{tag, source, chunk_id}]}`, 422 on a bad request. Ports: Python 8000; C# 8080 in the container, 8001 published. Seams: `LLM_BACKEND`, `EMBED_BACKEND` (`hashing` offline), `VECTOR_STORE` (`memory` offline; `baked` from module 12). Module 11 fronts it with guardrails on 8010/8011. Ollama sits behind a compose profile and is reached at `${OLLAMA_BASE_URL:-http://host.docker.internal:11434}`.
- **Module 04's library is shared:** every later project reuses its backend factory (`client_from_env` / `AddLlmClient`); module 12 adds `bedrock` to it, module 13 a per-call `model=` override. `LLM_TEMPERATURE` sets a default temperature (09's judge uses 0).

Projects built so far:

| Project | Layout | Notes |
|---|---|---|
| `projects/01-python-warmup/` | Python only, at the project root | Modules 01–02 are Python-only by design |
| `projects/02-landscape-map/` | Python only, at the project root | |
| `projects/03-token-lab/python/` | Polyglot layout; `csharp/` not built yet | First polyglot module; library shape, CPU-only torch index |
| `projects/review-lab/` | Python, at the project root | R track; `journal/` is meant to be committed (`.gitignore` lets it through) |

## Layout & conventions

The full rules are in [`docs/conventions.md`](docs/conventions.md). Keep that file and this summary in step. From module 03 on, each project looks like this:

```
projects/<NN>-<name>/
├── fixtures/   # committed datasets BOTH languages read (labeled sets, eval sets, corpora)
├── python/     # uv project: pyproject.toml, uv.lock, src/ or app/, tests/ (pytest), Dockerfile, Dockerfile.dockerignore
└── csharp/     # .NET 10 solution: <Name>.slnx, Directory.Build.props, src/, tests/ (NUnit), Dockerfile, Dockerfile.dockerignore
```

- **Shared data** lives once in `fixtures/`. Both languages read it through a `FIXTURES_DIR` env var (default `../fixtures` relative to the language folder; in containers, wherever the Dockerfile copied it, set explicitly). Never copy datasets into each language folder.
- **`.gitignore` is data-hostile on purpose:** `data/`, `models/`, `outputs/`, `runs/`, `*.jsonl`, `*.csv`, model weights, etc. are ignored everywhere *except* under `fixtures/`, `samples/`, `test_data/` (re-included at the very end of `.gitignore`; that block must stay last). Code folders named `Models/`, `Data/`, `Processed/` (and `src/**/Adapter/`, `src/**/Build/`) under `src/**`, `app/**`, `eval/**` and `tests/**` are re-included, because git on Windows matches case-insensitively. `projects/review-lab/journal/` and `rubric/labels/` are re-included too. Put run outputs (plots, scorecards) in `outputs/`.
- **Cross-project reuse:** Python uses a uv path dependency (`uv add --editable ../../NN-x/python`); C# uses a `ProjectReference`. Either way the Docker build context widens to `projects/`. Every Dockerfile has a `Dockerfile.dockerignore` next to it with `**/` patterns (the scaffolds write it); BuildKit reads it whatever the context, so don't rely on a context-root `.dockerignore`.
- **Python project shapes:** *library* (`-Mode package`): `src/<module>/`, `[build-system]` (`uv_build`) in pyproject, Dockerfile `uv sync --frozen --no-install-project` → copy `README.md` + `src/` → `uv sync --frozen`. *Service* (`-Mode app`, which the script now scaffolds): `app/` at the `python/` root, no build system, `pythonpath = ["."]` for pytest, `uv run --no-sync`. Test deps are a dev group (`uv add --dev pytest`), never `.[dev]`. Python 3.12.
- **PyTorch:** any project depending on torch (incl. via sentence-transformers) lists `torch` as a *direct* dependency and pins it to the CPU index via `[tool.uv.sources]`. uv ignores sources for transitive deps, so without the direct listing Linux images get the multi-GB CUDA build.
- **Backends (ADR-001):** `LLM_BACKEND` = `stub` + `ollama` required in every module from 04 (both languages), `bedrock` from 12, `hosted` optional after 04. Unknown values fail loudly. The factory lives in module 04's library and later projects reuse it. Env vars are identical in both languages: `OLLAMA_BASE_URL` (server root, no `/v1`), `OLLAMA_MODEL`, `LLM_BASE_URL` (OpenAI-compatible, *with* `/v1`), `LLM_API_KEY`, `LLM_MODEL` (hosted only), `BEDROCK_MODEL_ID`, `AWS_REGION`, `JUDGE_MODEL` (09+). Ollama is used from module 04. Shared compose volume `ai-learn-ollama`.
- **Runnable-spec rule (ADR-002):** a module's Python side must run end to end with `LLM_BACKEND=stub` and pass pytest using only code shown in that doc plus declared path deps. No `NotImplementedError` on the happy path.
- **Shell:** the learner uses PowerShell 7. Every command in a doc has a pwsh form (`$env:VAR='x'; cmd`), or is labeled bash/WSL. Ports: Python 8000; C# listens on 8080 in the container, published on 8001 (from module 12 on, C# sets `ASPNETCORE_HTTP_PORTS=8000` so both images share one ECS task definition). Cross-project service URLs come from env vars (e.g. `RAG_URL`).
- **Reusing a service project from C#:** reference a class library, not the earlier web project (two top-level `Program` types break `WebApplicationFactory<Program>`).
- **Compose files** are `compose.yaml` and set a top-level `name:` (e.g. `rag-service-py` / `rag-service-cs`); otherwise every stack is named after its folder (`python`/`csharp`) and they collide. The app service uses `env_file: .env` plus `${VAR:-default}`, in both languages.
- **.NET library choices** (keep new work consistent): Microsoft.Extensions.AI (`IChatClient`) for model calls, OllamaSharp for local models, AWSSDK.Extensions.Bedrock.MEAI for Bedrock, ASP.NET Core minimal APIs for services, OpenTelemetry for tracing, Scriban for prompt templates, ML.NET (14), TorchSharp (15). NUnit for all C# tests (`Assert.That(x, Is.EqualTo(y))`). Fine-tuning (16) stays in Python; C# consumes and evaluates the tuned model.
- **Git:** `.gitattributes` normalizes to LF and forces LF for Dockerfiles/`*.sh`. `.vscode/{settings,tasks,launch,extensions}.json` (root and per project) and `ai-learn.code-workspace` are committed.

## Bootstrapping a project

Run from the repo root (or use the VS Code tasks **AI Learn: Bootstrap New Python Project / C# Project**). Details: [`docs/project-bootstrap-automation.md`](docs/project-bootstrap-automation.md).

```bash
pwsh ./scripts/new-python-project.ps1 -ProjectName 04-llm-client    # -> projects/04-llm-client/python/
pwsh ./scripts/new-csharp-project.ps1 -ProjectName 04-llm-client    # -> projects/04-llm-client/csharp/
```

The Python script accepts `-Mode package|app` (library vs service shape) and writes `pyrightconfig.json`, `Dockerfile.dockerignore`, pytest as a dev group and `.vscode/settings.json`. The C# script accepts `-Template console|classlib|webapi`, `-Name <PascalCase>` and `-Framework net10.0`, and generates the `.slnx`, an NUnit test project with a smoke test, `Directory.Build.props` (nullable, warnings as errors), `Dockerfile.dockerignore`, README and `.vscode/settings.json`, then runs `dotnet build`. Neither writes a Dockerfile (each module's doc gives one) or `fixtures/`. Both scripts register the language folder in `ai-learn.code-workspace` (keeping its tab indentation) and set the `AI_LEARN_PROJECT` user env var, which nothing in the repo reads; it's a marker for the learner's own shell. Both need PowerShell 7.

## Build / run / test

Python (from a project's `python/` folder, or the project root for 01, 02, review-lab). The bootstrap script defaults to Python 3.12 and names the package without the `NN-` prefix (`03-token-lab` → module `token_lab`):

```bash
uv sync
uv run pytest
uv run pytest tests/test_cost.py::test_estimate_cost_zero    # single test
uv run python -m <package>.cli ...
```

C# (from a project's `csharp/` folder):

```bash
dotnet build
dotnet test
dotnet test --filter "FullyQualifiedName~CostTests"           # single class/test
dotnet run --project src/<Name> -- <args>
```

Docs lint (from the repo root):

```bash
uv run --project tools/doccheck doccheck                         # all docs; non-zero exit on errors
uv run --project tools/doccheck doccheck docs/07-retrieval-augmented-generation.md
uv run --project tools/doccheck pytest tools/doccheck/tests
```

Docker: each language folder has its own multi-stage Dockerfile (C#: `sdk:10.0` build, a `test` target running `dotnet test`, `runtime`/`aspnet:10.0` final). Image tags use `-py` / `-cs` suffixes. When the build context is the project root or `projects/`, run `docker build -f <path-from-cwd>/Dockerfile <context>`: `-f` resolves from the current directory, not the context.

## AWS / deployment

Not deployed yet. Module 12 deploys module 07's RAG service to ECS Fargate (Terraform in `infra/`, one workspace per language; an optional CDK C# stack), with Bedrock via IAM task roles (`bedrock:InvokeModel` covers `Converse`). The vector index is baked into the image at build time with Titan embeddings, used for both index and query (ADR-003). Cost safety is part of the module: a budget first, ALB ingress limited to the learner's IP, no NAT gateways, `force_delete` on ECR, and a teardown section. Per-machine AWS setup (profile `ai-learn`, credential mounts) is in [`docs/env-settings.md`](docs/env-settings.md). Document real deployments here as they land.

## Keep this file current

As projects land, update the project table above and add any per-project commands, architecture or deployment details that aren't obvious from a single file.
