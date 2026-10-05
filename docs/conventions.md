# Conventions

This is the one place the cross-module rules live. Module docs link here instead of restating them, so when a rule changes it changes once. The *why* behind the bigger rules is in the [decision records](adr/).

## Project layout

From module 03 on, every project is built twice: Python first (the spec), then idiomatic C#.

```
projects/<NN>-<name>/
├── fixtures/   # committed datasets BOTH languages read (labeled sets, eval sets, corpora)
├── python/     # uv project: pyproject.toml, uv.lock, Dockerfile, Dockerfile.dockerignore, tests/
└── csharp/     # .NET 10: <Name>.slnx, Directory.Build.props, src/, tests/ (NUnit), Dockerfile, Dockerfile.dockerignore
```

- **Fixtures live once**, in `fixtures/`. Both languages find them through `FIXTURES_DIR`. Locally it defaults to `../fixtures` (relative to the language folder). In a container it's wherever the Dockerfile copied them: `/app/fixtures` when the build context is the project root, or `/src/<NN>-<name>/fixtures` when the context widens to `projects/`. Set `FIXTURES_DIR` explicitly in the Dockerfile either way. For a C# *web* project, `dotnet run` uses the project folder (`src/<Name>`) as its working directory, so its relative default is `../../../fixtures`. Because of the local default, run each language's commands from its own folder (`python/` or `csharp/`), including during cross-checks.
- **Scaffold with the scripts**: `pwsh ./scripts/new-python-project.ps1 -ProjectName NN-name [-Mode app]` and `pwsh ./scripts/new-csharp-project.ps1 -ProjectName NN-name -Template console|classlib|webapi [-Name Pascal]`. See [project bootstrap automation](project-bootstrap-automation.md).

## Python project shapes

| | Library (`-Mode package`, default) | Service (`-Mode app`) |
|---|---|---|
| Code | `src/<module>/` | `app/` (plus e.g. `eval/`) at the `python/` root |
| Build system | `[build-system]` with `uv_build`, so the project installs itself | none, never installed |
| Tests import it via | the install | `[tool.pytest.ini_options] pythonpath = ["."]` (the script writes it) |
| Run | `uv run python -m <module>.cli` | `uv run --no-sync uvicorn app.main:app` |
| Dockerfile | `uv sync --frozen --no-install-project` → copy `README.md` and `src/` → `uv sync --frozen` | `uv sync --frozen --no-install-project` → copy code → `uv run --no-sync ...` |

`uv_build` needs the `README.md` that `pyproject.toml` names, so a library's Dockerfile copies it before the second sync.

Test tools are a **dev dependency group** (`uv add --dev pytest`), which `uv sync` installs by default. Never `pip install -e ".[dev]"`: that's an *extra*, so pytest never gets installed.

The package name drops the `NN-` prefix: `03-token-lab` → distribution `token-lab`, module `token_lab`. Python is 3.12 (`.python-version`, `requires-python = ">=3.12"`, `python:3.12-slim`).

## Model backends

The full rationale is in [ADR-001](adr/001-backend-contract.md). Every module that calls a model selects the backend with `LLM_BACKEND`, in both languages:

| `LLM_BACKEND` | Required from | What it is |
|---|---|---|
| `stub` | 04, every module after | Deterministic, offline, no network. What tests, CI and the cross-checks run on. |
| `ollama` | 04, every module after | A local model through Ollama. The default for interactive runs. |
| `hosted` | taught in 04; optional after | Any OpenAI-compatible hosted API. |
| `bedrock` | 12 on | Amazon Bedrock via the Converse API, credentials from the IAM role or the AWS profile. |

- **The backend factory lives in module 04's library.** Later projects reuse it: Python with a uv path dependency (`uv add --editable ../../04-llm-client/python`), C# with a `ProjectReference` to `LlmClient` (a class library). Module 12 adds `bedrock` to that same library. Projects don't grow their own model adapters.
- **An unknown value fails loudly** in both languages, with an error that lists the supported values. No silent fallback: answering from a local model when someone asked for Bedrock is a correctness bug, not a convenience.
- A module that genuinely supports fewer backends says so in one line, and still fails loudly on the others.

### Environment variables

The names are identical in both languages. C# reads them through `IConfiguration`, which includes environment variables, so `config["OLLAMA_MODEL"]` works without a prefix. Use these exact names, not `Section__Key` variants.

| Variable | Used by | Meaning |
|---|---|---|
| `LLM_BACKEND` | all | `stub` / `ollama` / `hosted` / `bedrock` |
| `OLLAMA_BASE_URL` | `ollama` | Server root, **without** `/v1`, e.g. `http://localhost:11434`. OpenAI-compatible clients append `/v1` themselves. |
| `OLLAMA_MODEL` | `ollama` | Chat model tag, e.g. `llama3.2` |
| `OLLAMA_EMBED_MODEL` | `ollama` embeddings | e.g. `all-minilm` |
| `LLM_BASE_URL` | `hosted` | OpenAI-compatible base URL, **including** `/v1`, e.g. `https://api.openai.com/v1`. Clients append `/chat/completions`. |
| `LLM_API_KEY` | `hosted` | The key. Python: `.env` (git-ignored). C#: user-secrets. Never committed. |
| `LLM_MODEL` | `hosted` | Hosted model name. Ignored by the other backends: the Ollama model is `OLLAMA_MODEL`, the Bedrock one `BEDROCK_MODEL_ID`. |
| `Rates__InputPerMTok`, `Rates__OutputPerMTok` | `hosted` | $ per million tokens. The `__` is .NET's env-var spelling of `Rates:InputPerMTok`; Python reads the same names. |
| `LLM_TEMPERATURE` | `ollama`, `hosted`, `bedrock` | Optional sampling temperature for every call (e.g. `0` for an eval judge). Unset means the server's default. In C#, a call's own `ChatOptions.Temperature` wins. |
| `LLM_STUB_REPLY` | `stub` | Optional fixed reply. Without it the stub answers `stub: <last user message>`. |
| `BEDROCK_MODEL_ID` | `bedrock` | Model ID or inference-profile ID, e.g. `us.anthropic.claude-...`. See module 12 for IAM scoping. |
| `BEDROCK_EMBED_MODEL_ID` | `bedrock` embeddings | e.g. `amazon.titan-embed-text-v2:0` |
| `AWS_REGION` | `bedrock` | e.g. `us-east-1` |
| `EMBED_BACKEND` | 07 on | `hashing` (deterministic, offline: tests and cross-checks), `sentence-transformers` (Python 07), `ollama` (C# 07; both languages in 13), `bedrock` (Titan, 12 on) |
| `VECTOR_STORE` | 07 on | `memory` (offline; empty after restart, so `/ingest` first), `chroma`, or `baked` (12 on: a prebuilt index file at `INDEX_PATH`, made at image build time with the same embedding model as the queries) |
| `CHROMA_URL`, `CHROMA_COLLECTION` | `VECTOR_STORE=chroma` | e.g. `http://localhost:8003`, `docs` |
| `EVAL_DATASET`, `EVAL_OUT_DIR` | 09 on | Eval set to run (default the module's `fixtures/` set) and where scorecards are written (default `outputs/`) |
| `SYSTEM_VERSION` | 09 on | Which system the eval harness runs: `v1`, `v2`, or `frozen` (recorded outputs, no service needed) |
| `INDEX_PATH` | `VECTOR_STORE=baked` | The baked index file |
| `CACHE_STORE`, `REDIS_URL` | 13 | `memory` (offline) or `redis`, and its URL |
| `ROUTER_CHEAP_MODEL`, `ROUTER_STRONG_MODEL` | 13 | The two models the router picks between, e.g. `llama3.2:1b` and `llama3.2` |
| `AGENT_AUTO_APPROVE` | 08 on | `never` denies every approval-gated tool call without prompting (tests, CI). Unset means ask on the console. Any other value fails at startup. |
| `RETRIEVER` | 11, 17 | `stub` (canned context, offline) or `rag` (module 07's `/ask` at `RAG_URL`) |
| `MODEL_VERSION` | 11 on, optional | The exact model build deployed; recorded on spans |
| `CAPSTONE_URL` | 17 | The capstone service the contract and eval suites call. No default in C# (unset skips those suites); `http://localhost:8000` in `run_evals.py`. |
| `JUDGE_MODEL` | 09 on | The judge model, set separately from the system under test so the judge stays fixed while the system changes |
| `FIXTURES_DIR` | any project with `fixtures/` | See [Project layout](#project-layout) |
| `<NAME>_URL` | cross-project calls | e.g. `RAG_URL`. A project that calls another project's service takes its URL from an env var and never assumes a port. |

Commit a `.env.example` listing every variable a project reads, with safe defaults and no secrets. Leave `OLLAMA_BASE_URL` commented out in it: compose interpolates `${OLLAMA_BASE_URL:-...}` from `.env`, so a `localhost` value there would point the container at itself.

## Ollama

Ollama is used from **module 04** on. Module 10 then looks inside it: quantization, throughput and serving.

Run it one of two ways, and **only one at a time**, because both want port 11434:

- **Native on Windows** (simplest, and it uses your GPU directly): install from ollama.com, then `ollama pull llama3.2`. Containers reach it at `http://host.docker.internal:11434`.
- **In compose**: the `ollama/ollama` image with the shared named volume below, so each model downloads once across every stack:

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]
volumes:
  ollama:
    name: ai-learn-ollama   # fixed name: shared by every stack
```

A project's own compose file puts its `ollama` service behind an opt-in profile (`profiles: [ollama]`) and points the app at `${OLLAMA_BASE_URL:-http://host.docker.internal:11434}`. Then one file works both ways: `docker compose up` uses native Ollama, and `docker compose --profile ollama up` starts the container. Module 10 shows the pattern.

On Linux hosts `host.docker.internal` doesn't resolve by default. Add `extra_hosts: ["host.docker.internal:host-gateway"]` to the service that needs it. It's harmless on Docker Desktop.

**GPU on Windows:** Docker Desktop with the WSL2 backend passes an NVIDIA GPU through with just a current Windows NVIDIA driver. You don't install the NVIDIA Container Toolkit; that's for native Linux hosts. Add `gpus: all` (or the `deploy.resources.reservations.devices` block) to the compose service. Native Ollama on Windows uses the GPU with no Docker involved.

## Ports

| | Local / compose | In the container |
|---|---|---|
| Python service | 8000 | 8000 |
| C# service, modules 03–11 | 8001 | 8080 (the `aspnet` image default) |
| C# service, module 12 on | 8001 | 8000 (`ENV ASPNETCORE_HTTP_PORTS=8000`, so both images share one ECS task definition) |
| Module 11 (guardrail layer in front of 07) | Python 8010, C# 8011 | 8000 / 8080 |
| Ollama | 11434 | 11434 |

Two stacks that publish the same host port can't run together. Stop one first (`docker compose down`), or override the port.

## Compose

- Every compose file sets a top-level `name:` (`rag-service-py`, `rag-service-cs`). Otherwise every stack is named after its folder (`python` / `csharp`) and they collide.
- The file is `compose.yaml`.
- The app service uses `env_file: .env` (so `LLM_BACKEND=hosted` in `.env` works) and sets defaults with `${VAR:-default}` under `environment:`. That applies to **both** languages: a C# compose that hard-codes `LLM_BACKEND: ollama` can't be switched.

## Docker

- **Ignore file:** each Dockerfile has a `Dockerfile.dockerignore` next to it. BuildKit reads `<Dockerfile>.dockerignore` from beside the Dockerfile, whatever the build context, and its `**/` patterns match at any depth. So the same file works whether the context is the language folder, the project root (to reach `fixtures/`) or `projects/` (to reach another project). The scaffolds write it. Don't rely on a `.dockerignore` at the context root.
- **Build commands:** `-f` resolves from your current directory, not from the context: `docker build -f projects/07-rag-service/python/Dockerfile projects/07-rag-service`.
- **Image tags** end in `-py` / `-cs`.
- **C# images:** a multi-stage `sdk:10.0` build with a `test` target that runs `dotnet test`, and a `runtime:10.0` (console) or `aspnet:10.0` (web) final stage that runs as `USER $APP_UID`.

## PyTorch wheels

Any project that depends on torch, directly or through sentence-transformers or transformers, pins the wheel index. From PyPI, torch is the CUDA build on Linux (several GB in a Docker image) and a CPU-only build on Windows. Neither is what you want by default.

```toml
[project]
dependencies = [
    "sentence-transformers>=...",
    "torch>=...",              # direct, even if only a transitive need: see below
]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[tool.uv.sources]
torch = [{ index = "pytorch-cpu" }]
```

- **List torch as a direct dependency.** `[tool.uv.sources]` only applies to direct dependencies. If torch comes in only through sentence-transformers, the source is silently ignored and Linux gets CUDA anyway. Check with `grep -A2 'name = "torch"' uv.lock`: the source should be `download.pytorch.org/whl/cpu`.
- **Want your NVIDIA GPU on Windows** (modules 15 and 16)? Swap the index URL for the CUDA one PyTorch's install page gives (e.g. `.../whl/cu130` for torch 2.14; older CUDA indexes stop at older torch versions), and keep the CPU index for the Docker image. Modules 15 and 16 show the per-platform form.

**Windows path length.** Keep the repo near the drive root (`C:
eposi-learn` is fine). Deep paths plus a `.venv` can exceed Windows' 260-character limit, and packages like `transformers` then install with missing files.

## Shell commands

The learner's shell is **PowerShell 7** (`pwsh`). Docs follow these rules:

- **Setting an env var for one command:** bash's `VAR=x cmd` doesn't work in PowerShell. Show the pwsh form:
  ```powershell
  $env:LLM_BACKEND = 'stub'; dotnet run --project src/Agent
  ```
  If a doc shows a bash form too, it's labeled *bash / WSL / Git Bash*.
- **No bash-only tools without an alternative:** `jq`, `diff <(...)`, `grep` and `sed` get a pwsh or `uv run python -c` alternative.
- **`curl`** means `curl.exe` (real curl ships with Windows). In Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`. Use pwsh 7.
- **Volume mounts:** pwsh `-v "${PWD}/outputs:/app/outputs"`. In Git Bash, prefix `MSYS_NO_PATHCONV=1` or the container path gets rewritten.
- **`mkdir a b`** in pwsh creates `a/b`. Write `mkdir a, b`.

## What a module doc must show

The rule, and its reasoning, is [ADR-002](adr/002-runnable-spec-rule.md): the Python side of every module runs end to end with `LLM_BACKEND=stub`, and `uv run pytest` passes, using only code shown in full in that doc plus its declared path dependencies.

- **Must be shown in full:** anything on the path to a documented run command or the Checkpoint, and anything a later module imports.
- **May be an exercise:** a *second* implementation of an interface already shown in full (`hosted.py` after `ollama.py`). The factory imports it lazily, so the shown path never fails on an import, and the exercise names the test it must pass.
- **Never:** `raise NotImplementedError` on the module's own happy path, or a file in the layout tree that a documented command needs but the doc doesn't show.
- **The C# side** matches the Python behaviour (same commands or endpoints, inputs, outputs, env vars), and any difference is stated in the cross-check section.

## Module readiness

A module doc is ready when:

1. The layout tree matches the files the doc shows. Exercises are labeled, each with its acceptance test.
2. The Python side runs end to end on `stub`, and pytest is green.
3. Both sides read the same env-var names, fail loudly on an unknown backend, and have a compose file with `name:` and `env_file`. (Modules whose build calls no model, 14 and 15, can skip the backend and compose items.)
4. Every command has a pwsh form, or is labeled bash/WSL.
5. The cross-check names both exact commands and the tolerance.
6. Every Checkpoint item has a command or step in the doc.
7. `uv run --project tools/doccheck doccheck` is clean.
8. It ends with a *Last verified* line: `read-only` (reviewed against these conventions) or `built` (the code was built and run).
