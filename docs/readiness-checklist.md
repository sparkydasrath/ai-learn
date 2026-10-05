# Docs readiness checklist

A review of every doc (00–17, R, and the meta/bootstrap docs), done on 2026-10-05 after the polyglot (Python + C#) rewrite. Nothing was compiled or run. The findings come from reading the docs against [`CLAUDE.md`](../CLAUDE.md), the scripts and the projects that exist. Line numbers refer to the docs as of commit `ca562f6`.

Severity: **B** = blocker (the learner can't proceed or is told something wrong), **M** = major (confusion or rework), **m** = minor (polish). Tick items off as they're fixed.

## Cross-cutting themes

1. **The Python "spec" is thinner than the C# side.** Files that are referenced but never shown, missing pytest suites, and a stubbed `/ask` in 07 that 08, 09 and 11 depend on.
2. **Model settings don't match across languages.** C# often hard-codes Ollama and ignores `LLM_BACKEND`, uses its own env-var names, or hard-codes Bedrock (17).
3. **Windows realities.** `pwsh` isn't listed as a prerequisite, commands use bash-only `VAR=x cmd`, the WSL2/GPU advice is wrong, and the PyTorch wheel index (CPU vs CUDA) isn't handled.
4. **The conventions and the repo disagree.** `-Mode app` doesn't scaffold the Service shape, `.gitignore` swallows the Service-shape code and the R labels, the `.dockerignore` location is unclear, and the docs disagree on when Ollama starts.

## Plan

The cross-module rules now live in [conventions.md](conventions.md), with the decisions in [adr/](adr/). Work happens on branch `docs/hardening`, one commit per layer:

1. **Foundation**: scripts, `.gitignore`, `03-token-lab`, conventions, ADRs, `tools/doccheck`, and 00/README/CLAUDE.md pointing at the conventions.
2. **04**: the shared client, including `stub` ([ADR-001](adr/001-backend-contract.md)). Verified by a throwaway build.
3. **05–06**
4. **07**: verified by a throwaway build.
5. **08, 09, 11**, including how 09 and the R track converge.
6. **10**, including Windows/GPU.
7. **12–13** together, before any AWS spend. 12 deploys real RAG ([ADR-003](adr/003-module-12-deploys-real-rag.md)).
8. **14–17**
9. Remaining **m** items.

Rules for each pass:
- Apply the [shell-command rules](conventions.md#shell-commands) to each doc as it's touched, rather than as one sweep at the end.
- Add path comments to code blocks, so `doccheck`'s layout rule can see which files are shown.
- Finish each module doc with a `Last verified:` line.

## Priority changes after the advisor review

- **New B, 04:496 and 04:893**: both factories accept only `ollama | hosted`, so the `stub` backend promised by CLAUDE.md and doc 00 doesn't exist. Every later module's offline tests depend on it.
- **12:134, 511** (unauthenticated `/ask` on a public ALB) goes from M to **B**. Fix it in the same step as the deploy.
- **07:226** (sentence-transformers pulls CUDA torch) goes from m to **M**. Same root cause as 15:173; one recipe in [conventions](conventions.md#pytorch-wheels).
- **09:369-371** (the judge follows the system under test) goes from M to **B**. It invalidates the measurement in the module about measurement.
- **03:399-407** is folded into the 03 `pyproject` blocker (the same `uv_build` README issue).
- **"verify API X" items** (03:526, 05:520, 09:598, 12:750, 15 ScottPlot/TorchSharp, 13 `AsIEmbeddingGenerator`) aren't fix items. They become a *verify on first build* list in each module, and builds answer them where they happen.

---

## Foundation (meta, scripts, repo)

- [x] **B** `projects/03-token-lab/python/pyproject.toml`: no `[build-system]` and name `03-token-lab`, so `token_lab` is never installed and local `uv run pytest` fails to import. Docker only works because of `PYTHONPATH=/app/src`. Add `uv_build`, rename it to `token-lab`, drop the `PYTHONPATH` hack, recreate `.venv`, delete the leftover `main.py`, and fill in the empty `README.md`. *Done: uv_build, name token-lab, Python 3.12, CPU torch index, README, Dockerfile.dockerignore, test_tokens.py.*
- [x] **B** PowerShell 7 (`pwsh`) is required by the tasks (`.vscode/tasks.json:5,24`) and every scaffold command, but it isn't listed in `00:65-72` or module 01. Add `winget install Microsoft.PowerShell`. *Done: 00 tooling list, bootstrap doc, conventions.*
- [x] **M** `scripts/new-python-project.ps1:61`: `-Mode app` still creates `src/`, points pyright/VS Code at `src`, and never writes the pytest `pythonpath = ["."]`. Branch on `$Mode`. *Done: app/ + pythonpath + pyright/VS Code paths; tested in scratch.*
- [x] **M** `.gitignore:207-211`: the re-includes cover only `src/**` and `tests/**`, so `python/app/models/`, `app/data/`, `eval/data/`, `app/processed/` and `csharp/src/**/Build/` are ignored. Add re-includes and update CLAUDE.md. *Done: app/eval/src re-includes; verified with git check-ignore.*
- [x] **M** `.gitignore:195`: `projects/review-lab/rubric/labels/*.jsonl` is ignored, but R:118-120 and 391 say the labels stay in git. Add `!projects/review-lab/rubric/labels/**` to the final block.
- [x] **M** The Python scaffold writes no `.dockerignore`. `03-token-lab/python` has none, so `docker build` uploads the multi-GB `.venv`. Generate one (`.venv/`, `__pycache__/`, `outputs/`).
- [x] **M** The `.dockerignore` location is inconsistent: `00:43` says project root, CLAUDE.md says `<Dockerfile>.dockerignore`, and the C# script writes `csharp/.dockerignore`, which doesn't apply to a root or `projects/` context. Pick one and generate it. *Done: convention is Dockerfile.dockerignore with **/ patterns; module docs still to update as each is touched.*
- [x] **M** CLAUDE.md implies each language folder gets a generated multi-stage Dockerfile, but neither script writes one. Fix the wording or generate it.
- [x] **M** `docs/env-settings.md`: no doc links to it. Line 25/31 uses `--profile my-profile` but 39/81 uses `AWS_PROFILE=learn-profile`. Nothing reads `AI_LEARN_PROJECT`. Unify the profile name, link the page from 02 and the README, and explain or drop `AI_LEARN_PROJECT`. *Done: one profile `ai-learn`; linked from README; AI_LEARN_PROJECT documented as a marker nothing reads.*
- [x] **M** `00:71` says Ollama arrives "from module 10", but 04–07 already use it. Change it to "from module 04", and reword 10:45-56 to match. *Done: 00 fixed; 10's wording is handled in the 10 pass.*
- [x] **m** `00:9-17` ("shape of every module") doesn't list Review track sync or the cross-check step.
- [x] **m** `project-bootstrap-automation.md:90`: the caption says Python 3.12, the command passes 3.13.
- [x] **m** `-CreateVenv:$false` does nothing unless `-SkipPytest` is also passed (`ps1:87`), but the doc example at `:100` implies it works on its own.
- [x] **m** The C# script's README hard-codes `--filter SmokeTests` even with `-SkipTests` (`new-csharp-project.ps1:120`).
- [x] **m** The C# script adds a test→src `ProjectReference` (`:72`), which undercuts 17's "tests never use the API types". Mention it in 17. *Done: noted in the bootstrap doc; 17 still has to say it.*
- [x] **m** The VS Code C# task can't pass `-Name` or `-SkipTests`. *Done: documented: use the CLI.*
- [x] **m** Workspace registration round-trips `ai-learn.code-workspace` through `ConvertTo-Json`, which churns the whitespace. `projects/review-lab` is missing from the workspace. *Done: keeps tabs now; review-lab added.*
- [x] **m** Python versions disagree: ~~token-lab pins 3.11 with a 3.13 Dockerfile~~ (fixed); review-lab is 3.11; the convention is 3.12. *Done: review-lab stays as you built it; the R doc says how to move it to 3.12.*
- [x] **m** `.gitattributes` doesn't force LF for `Dockerfile.dockerignore`.
- [x] **m** `*.model` in `.gitignore:183` ignores tokenizer `.model` files outside `fixtures/`. Intended? *Done: intended: downloaded artifacts; commented in .gitignore.*
- [x] **m** CLAUDE.md says fixtures are at `/app/fixtures` in containers, but images built with a widened context use other paths (e.g. 05's `/src/05-prompt-lab/fixtures`). Document the exception. *Done: conventions: set FIXTURES_DIR explicitly in each Dockerfile.*

## 03 — LLM fundamentals

- [x] **M** `03:399-407` (also `04:597-602`): the Dockerfile copies only `pyproject.toml uv.lock` before `uv sync --frozen`. `uv_build` needs `README.md`. Copy it too. *Done: 03 and 04 both copy README.md.*
- [x] **m** `03:632` vs layout `236-237`: the prose pins a token count in pytest, but no `tests/test_tokens.py` exists in the layout.
- [x] **m** `03:617`: the "Generic math" comment is wrong. It's a static abstract interface member (`IParsable<T>`).
- [x] **verify on first build** `BertTokenizer.Create(path)`, the `EncodeToIds` overload, and the `results.First()` ONNX output order (526/534/547). *Done: moved to the doc's 'Verify on first build' list.*

## 04 — Calling models

- [x] **B** `04:496`, `04:893`: no `stub` backend in either factory, so the offline tests and cross-checks of 04–17 have nothing to run on ([ADR-001](adr/001-backend-contract.md)). Add `StubClient` (Python) and a stub `IChatClient` (C#), shown in full. *Done: StubClient / StubChatClient, shown in full and tested; the stub cross-check is exact.*
- [x] **M** `04:465-497`: `factory.py` imports `HostedClient` at the top, but `hosted.py` is never shown, so it raises ImportError even for Ollama. `demo.py`, `.env.example` and `__init__.py` aren't shown either. Show them, or import lazily. *Done: hosted.py, demo.py and .env.example shown; one OpenAICompatibleClient under Ollama and Hosted.*
- [x] **M** `04:487` vs `884/653`: `LLM_BASE_URL` excludes `/v1` in Python but includes it for the .NET OpenAI SDK, so the "one `.env` drives both" claim (902) is false. Define it once. *Done: LLM_BASE_URL includes /v1 on both sides (conventions).*
- [x] **m** `04:431-454`: Python `stream()` has no retry and no `llm_call` log line, so the log comparison differs (two lines in C#, one in Python). *Done: Python stream retries until it opens and logs usage, like C#.*
- [x] **m** `04:1199-1205`: the C# compose hard-codes `LLM_BACKEND: ollama` and has no `env_file`, so it can't flip to hosted. *Done: both composes use an optional env_file and ${LLM_BACKEND:-ollama}.*
- [x] **m** `04:1158`: the bash-only `VAR=x dotnet run` needs a `$env:` form. *Done: pwsh forms throughout.*
- [x] **m** `04:415-420`: `cost_usd=0.0` vs `0` means the output doesn't diff cleanly. Use the same format in both. *Done: cost_usd=:.6f / F6 on both sides; logs on stderr on both sides.*

## 05 — Prompt engineering

- [x] **M** `05:93-98, 464`: no content for `fixtures/labeled.jsonl`. Inline about 25-30 rows, including ambiguous and injection-flavoured ones. *Done: see the doc's Last verified line.*
- [x] **m** `05:114-116` vs `731-791`: C# has `ScoreTests` and an injection test; Python has only template tests. *Done: see the doc's Last verified line.*
- [x] **m** `05:485`: in pwsh, `mkdir prompts runs` creates `prompts/runs`. Use `mkdir prompts, runs`. *Done: see the doc's Last verified line.*
- [x] **m** `05:893`: `diff <(jq …)` is bash-only and needs jq. Give a pwsh/Python alternative. *Done: see the doc's Last verified line.*
- [x] **m** `05:360/700, 445/866`: the model label prefers `OLLAMA_MODEL` even when `LLM_BACKEND=hosted`. *Done: see the doc's Last verified line.*
- [x] **m** `05:863-866`: the C# compose can't run hosted; it also needs `UserSecretsId`. *Done: see the doc's Last verified line.*
- [x] **m** `05:202`: `PROMPT_DIR = parents[2]` assumes an editable install. Allow a `PROMPT_DIR` env var. *Done: see the doc's Last verified line.*
- [x] **verify on first build** `05:520`, the Scriban newline behaviour after `{{ # … }}`. *Done: answered by the build; golden render tests pin it on both sides.*

## 06 — Structured outputs & tool calling

- [x] **M** `06:107, 438`: `run.py` is listed and run in Docker but never shown. *Done: see the doc's Last verified line.*
- [x] **M** `06:319, 331`: the Python tool loop calls `client.complete_with_tools`, which 04's `LlmClient` doesn't have. Add it (OpenAI-compatible `tools`) or scope Python Part 2 explicitly. *Done: see the doc's Last verified line.*
- [x] **M** `06:376`: no Python tests (repair loop, step cap); `pytest-asyncio` is added but unused. Mirror `InvoiceExtractorTests` and `ToolLoopTests`. *Done: see the doc's Last verified line.*
- [x] **m** `06:490`: `JsonSerializerDefaults.Web` is case-insensitive while pydantic isn't. Set `PropertyNameCaseInsensitive = false` or add a cross-check case. *Done: see the doc's Last verified line.*
- [x] **m** `06:266`: pydantic v1 `class Config` → `model_config = ConfigDict(...)`. *Done: see the doc's Last verified line.*
- [x] **m** `06:327`: `str(result)` sends a Python repr. Use `json.dumps`. *Done: see the doc's Last verified line.*
- [x] **m** `06:425-427, 880-882, 1138-1140`: no `LLM_BACKEND` in compose; C# hard-wires Ollama. State it. *Done: see the doc's Last verified line.*

## 07 — RAG

- [x] **B** `07:384-395`: Python `/ask` raises `NotImplementedError`, which breaks this checkpoint and modules 08, 09 and 11. Add the 04 path dependency, widen the context to `projects/` with `Dockerfile.dockerignore`, and implement `call_model` via `client_from_env()` (or a local Ollama call plus a `stub` backend). *Done: see the doc's Last verified line.*
- [x] **M** `07:167, 1385-1387`: `tests/test_retriever.py` is listed but not shown. Add chunker, id and golden-prompt tests. *Done: see the doc's Last verified line.*
- [x] **M** `07:620-625, 1347-1349`: C# reads `Rag__OllamaBaseUrl`/`Rag__ChatModel`, not `OLLAMA_BASE_URL`/`OLLAMA_MODEL`, and has no `LLM_BACKEND`. *Done: see the doc's Last verified line.*
- [x] **M** `07:529` vs `1349`: Python defaults to `hosted`, C# to Ollama. Align them. *Done: see the doc's Last verified line.*
- [x] **m** `07:1298-1299, 1396`: pwsh equivalents for `VAR=x` commands. *Done: see the doc's Last verified line.*
- [x] **m** `07:548-549` vs `516`: `chroma_port` defaults to 8000, but compose publishes 8003. *Done: see the doc's Last verified line.*
- [x] **M** `07:226`: sentence-transformers pulls CUDA torch on Linux. Use a CPU index and an HF cache volume. *Done: see the doc's Last verified line.*
- [x] **m** `07:530`: `host.docker.internal` needs `extra_hosts: host-gateway` on Linux. *Done: see the doc's Last verified line.*
- [x] **m** `07:514, 1337`: pin the `chromadb/chroma` image tag to match the client and the v2 REST paths. *Done: see the doc's Last verified line.*
- [x] **m** `07:169-176`: the layout omits `uv.lock`/README; `docker-compose.yml` vs `compose.yaml` naming is inconsistent with 04-06. *Done: see the doc's Last verified line.*
- [x] **m** `07:881`: a missing `question` binds as null in C# but gives a 422 in FastAPI. Validate it. *Done: see the doc's Last verified line.*

## 08 — Agents

- [x] **M** `08:121-161`: no Python tests are shown. `input()` under pytest raises `OSError`, not `EOFError`. Add `test_agent.py` using `monkeypatch.setenv`. *Done: see the doc's Last verified line.*
- [x] **M** `08:328-339, 799-807`: the tools doc lists only names and descriptions, so the model never sees the argument names. Include the schema on both sides. *Done: see the doc's Last verified line.*
- [x] **M** `08:405-409`: Python skips the 04 client and only supports Ollama. Use the 04 path dependency (as 06 does) or require Ollama explicitly. *Done: see the doc's Last verified line.*
- [x] **M** `08:920-923, 1132`: C# silently ignores `LLM_BACKEND`. *Done: see the doc's Last verified line.*
- [x] **m** `08:296-302, 763-766`: the docstring says auto mode denies by default; the code prompts. *Done: see the doc's Last verified line.*
- [x] **m** `08:936-938`: an expired budget surfaces as an unhandled `OperationCanceledException`. Catch it. *Done: see the doc's Last verified line.*
- [x] **m** `08:1084-1091`: pwsh env-var form. *Done: see the doc's Last verified line.*
- [x] **m** `08:9`: says 06 is Phase 3; it's Phase 2. *Done: see the doc's Last verified line.*
- [x] **m** `08:625-629`: note the `1e3` input and `1E+16` formatting differences. *Done: see the doc's Last verified line.*
- [x] **m** `08:3`, `09:3`: the background box is missing the "rebuilt in C# from 03" sentence. *08 done; 09 pending.* *Done: see the doc's Last verified line.*

## 09 — Evaluation

- [x] **M** `09:124-126, 359, 715`: `systems/qa_system.py` (`build_system`) is never shown, so the Python gate can't run. *Done: see the doc's Last verified line.*
- [x] **B** `09:369-371, 397, 1218`: the Python judge comes from `system.judge_model`, so the judge changes with the system being judged, which 09:472 warns against. Build one fixed judge. *Done: see the doc's Last verified line.*
- [x] **M** `09:439-454, 1146-1158`: the Python compose and CI set only `MODEL_API_KEY`; C# uses a non-standard `JUDGE_MODEL`. Use the 04 env vars plus a shared `JUDGE_MODEL` on both sides. *Done: see the doc's Last verified line.*
- [x] **M** `09:470, 1270`: Python has no metric unit tests, and neither side excludes evals by default. Add `test_metrics.py`, pytest `addopts = "-m 'not eval'"`, and a C# `.runsettings`. *Done: see the doc's Last verified line.*
- [x] **M** `09:1272-1279` and `R:13, 415`: the R convergence is only a one-liner. Add a subsection mapping review + label → harness row, a rubric-judge variant emitting `{id,label}`, and the `projects/review-lab/rubric/agreement.py` command. *Done: see the doc's Last verified line.*
- [x] **m** `09:302`: the docstring says cost is measured; neither harness records tokens or cost. *Done: see the doc's Last verified line.*
- [x] **m** `09:1241`: the JSON scorecard and `SYSTEM_VERSION=frozen`/`EVAL_DATASET` exist only in C#. *Done: see the doc's Last verified line.*
- [x] **m** `09:451, 803, 1011`: `RAG_URL` → Python 07 returns 500 until 07 is fixed. *Done: see the doc's Last verified line.*
- [x] **m** `09:491`: `ProjectReference` to the `PromptLab` console app. Reference a class library instead. *Done: see the doc's Last verified line.*
- [x] **verify on first build** `09:598`, the `TryGetResult` `[NotNullWhen(true)]` nullability. *Done: compiles under warnings-as-errors in the scratch build.*
- [x] **m** `09:1016`: pwsh env-var form. *Done: see the doc's Last verified line.*

## 10 — Serving & inference (local)

- [x] **M** `10:126`: Docker Desktop + WSL2 doesn't need the NVIDIA Container Toolkit. Add a Windows note: WSL2 backend + current driver, or native Ollama via `host.docker.internal:11434`, and don't run both. *Done: see 10's Last verified line.*
- [x] **M** `10:482, 1063`: the checkpoint asks for eval scores per quant level with no recipe. Pull the quants, restart 07 with `OLLAMA_MODEL=<quant>`, run the 09 eval. *Done: see 10's Last verified line.*
- [x] **M** `10:213-224`: no Python tests (C# pins the JSON contract). Add a gateway test with `httpx.MockTransport`. *Done: see 10's Last verified line.*
- [x] **m** `10:413-449, 900`: port clashes on 11434/8000 with native Ollama or the 04/07 stacks; per-stack volumes re-download models. Reuse `ai-learn-ollama`. *Done: see 10's Last verified line.*
- [x] **m** `10:1029`: "module 04's `BedrockClient`" doesn't exist. *Done: see 10's Last verified line.*
- [x] **m** `10:302`: `import json` inside the loop. *Done: see 10's Last verified line.*
- [x] **m** `10:1001-1006`: a missing `prompt` gives a 422 in Python and a likely 500 in C#. *Done: see 10's Last verified line.*

## 11 — Observability & guardrails

- [x] **M** `11:807, 1085`: C# sends `LLM_MODEL` (default `gpt-4o-mini`) as `ChatOptions.ModelId` to Ollama, so the model isn't found. The prose says `MODEL`. Use `OLLAMA_MODEL` for Ollama. *Done: see the doc's Last verified line.*
- [x] **M** `11:460`: two of three "break it on purpose" steps are impossible (no `validate_output` call; spans have no content field). *Done: see the doc's Last verified line.*
- [x] **M** `11:128, 870`: `feedback.py` is listed, never shown; there is no Python `/feedback`. *Done: see the doc's Last verified line.*
- [x] **M** no Python `tests/test_guardrails.py`, although 1130 asks for one. *Done: see the doc's Last verified line.*
- [x] **m** `11:321-323` vs `488`: Python reuses 07 over HTTP, C# via a class library. Pick one approach. Port 8000 collides with 07. *Done: see the doc's Last verified line.*
- [x] **m** `11:455, 1360, 1374`: Git Bash path mangling (`MSYS_NO_PATHCONV=1`); pwsh has no `grep`; `"${PWD}:/data"`. *Done: see the doc's Last verified line.*
- [x] **m** `11:415`: put the `-Mode app` scaffold command at the top of the Python section. *Done: see the doc's Last verified line.*
- [x] **m** `11:1067, 1311`: backend support and defaults differ by language. State it. *Done: see the doc's Last verified line.*
- [x] **m** `11:1326`: verify the Aspire dashboard env-var name; OTLP port 18889 isn't published for a local `dotnet run`. *Done: see the doc's Last verified line.*
- [x] **m** `11:1077`: null `question` handling in C#. *Done: see the doc's Last verified line.*
- [x] **m** `11:108`: the brief promises tracing the real 07/08 service, but both sides stay stubbed. Add a "wire the real pipeline" step. *Done: see the doc's Last verified line.*

## 12 — Deploying to AWS

- [x] **B** `12:130, 132, 276`: says it deploys the 07 RAG service, but deploys a bare LLM proxy (no Chroma, no fixtures, a different contract). Either say so, or bake in an in-memory store or a Chroma sidecar. Check that sentence-transformers fits in 512 CPU / 1024 MB. *Done: see the doc's Last verified line.*
- [x] **M** `12:335`: ECR needs `force_delete = true` or `terraform destroy` fails. *Done: see the doc's Last verified line.*
- [x] **M** `12:387, 874` (and `13:116, 1161`): IAM scoping must cover inference-profile ARNs (`us.` IDs) plus the foundation-model ARNs in every routed region. Add an example `Resource` list. *Done: see the doc's Last verified line.*
- [x] **M** `12:439-453`: ALB gotchas: `target_type = "ip"`, `health_check_grace_period_seconds`, an ALB security group, health check path, and `output` blocks for the ECR URL and ALB DNS that `deploy.sh` needs. *Done: see the doc's Last verified line.*
- [x] **M** `12:851`: the CDK `ApplicationLoadBalancedFargateService` with no VPC creates NAT gateways that are billed while idle. Pass `NatGateways = 0` with `AssignPublicIp`. *Done: see the doc's Last verified line.*
- [x] **B** `12:134, 511`: `/ask` is unauthenticated on a public ALB. Restrict ingress to the learner's IP and point to 13. *Done: see the doc's Last verified line.*
- [x] **M** `12:454, 509`: no step creates the SSM parameter; the other vars are never passed. Add `aws ssm put-parameter` and `*.tfvars.example`. *Done: see the doc's Last verified line.*
- [x] **M** `12:508, 819`: `terraform workspace new` fails on reruns. Use `workspace select -or-create`. *Done: see the doc's Last verified line.*
- [x] **m** `12:40`: verify the model-access request flow (auto-enabled since 2025, plus the Anthropic first-use form). *Done: see the doc's Last verified line.*
- [x] **m** `12:484`: budgets and anomaly detection lag by hours. Add CloudWatch alarms on the Bedrock token metrics. *Done: see the doc's Last verified line.*
- [x] **m** `12:810`: the Graviton tip needs `runtime_platform { cpu_architecture = "ARM64" }`. *Done: see the doc's Last verified line.*
- [x] **m** `12:800, 804`: C# `docker run` publishes 8000 (the convention is 8001); there's no C# compose with `name:`. *Done: see the doc's Last verified line.*
- [x] **m** `12:586` vs `256`: C# rejects `stub`/`hosted`; Python silently falls back. *Done: see the doc's Last verified line.*
- [x] **m** `12:497, 510`: Windows: bash `deploy.sh`, `jq`, `VAR=x`; the SSO `~/.aws` mount for the non-root C# image. *Done: see the doc's Last verified line.*
- [x] **verify on first build** `12:750`, the `OptionsValidationException` wrapping in `WebApplicationFactory`. *Done: see the doc's Last verified line.*

## 13 — Cost, scaling & security

- [x] **B** `13:181-390`: the Python spec has no `app/main.py` (`/ask`, embed, model call, Redis, response shape), no `run_evals.py`, and no `uv add` line. Add `main.py` with an `OPTIMIZED` env toggle. *Done: see the doc's Last verified line.*
- [x] **B** `13:243, 546, 1099-1105`: the placeholder model names `small-cheap-model`/`large-expensive-model`; no `Router__*` env in the C# compose; no `LLM_BACKEND`/`OLLAMA_*` in the Python compose; no `ollama pull all-minilm`. Use real local models. *Done: see the doc's Last verified line.*
- [x] **M** `13:116, 1161`: SSM read is on the task role; module 12 correctly puts it on the execution role. Align them. *Done: see the doc's Last verified line.*
- [x] **M** `13:282, 297`: canaries: the learner is never told to plant `SYSTEM_PROMPT_MARKER`; `"sk-"` matches "risk-"; a substring match on attacker@evil.com is flaky. Use a regex and judge compliance. *Done: see the doc's Last verified line.*
- [x] **m** `13:735`: the per-user limiter sees the ALB's IP without `UseForwardedHeaders`. *Done: see the doc's Last verified line.*
- [x] **m** `13:1116-1120`: flush Redis between the baseline and optimized runs. *Done: see the doc's Last verified line.*
- [x] **m** `13:387, 1116, 1124`: pwsh env-var forms. *Done: see the doc's Last verified line.*
- [x] **m** add markdown-image/URL exfiltration as an injection channel. *Done: see the doc's Last verified line.*
- [x] **verify on first build** `AsIEmbeddingGenerator` on Bedrock, and that the `UseDistributedCache` keys include `ModelId`. *Done: see the doc's Last verified line.*

## 14 — Classical ML

- [x] **m** `14:1047`: the ONNX tolerance of 1e-6 is too strict after the float32 round-trip. Use about 1e-5, with "above 1e-3 is a bug". *Done: see the doc's Last verified line.*
- [x] **m** `14:1034`: the cross-check has no command for Python's `evaluate` in the container. Add `docker run --rm clf-py uv run --no-sync python -m clf.evaluate`. *Done: see the doc's Last verified line.*
- [x] **m** `14:448`: the Python exporter hard-codes `../fixtures`. Honour `FIXTURES_DIR`. *Done: see the doc's Last verified line.*
- [x] **m** `14:133, 146`: the "classical vs LLM" argument is never measured. Add an optional embed+logreg vs LLM-classifier exercise using the 09 harness. *Done: see the doc's Last verified line.*
- [x] **m** `14:1048` vs `389`: Python `/predict` returns a 500 on bad input, C# a 400. Make the 400 a step, with an httpx test. *Done: see the doc's Last verified line.*
- [x] **m** `14:1038-1041`: Windows: `MSYS_NO_PATHCONV`, `curl.exe`, UTF-16 redirection in PS 5.1. *Done: see the doc's Last verified line.*
- [x] **verify on first build** `14:579-582`, the `"0"/"1"` → bool label parse; assert both classes are present. *Done: see the doc's Last verified line.*

## 15 — Deep learning intuition

- [x] **M** `15:173-198, 493-516`: `torch` comes from PyPI with no index, so it's CPU-only on Windows and pulls the multi-GB CUDA stack into the Linux image. Show `[[tool.uv.index]]` for the CPU wheels plus a CUDA swap note. *Done: see the doc's Last verified line.*
- [x] **M** `15:536, 946-973`: `TorchSharp-cpu` bundles libtorch for every OS into the image. Restore and publish with `-r linux-x64`, or use `libtorch-cpu-linux-x64`, and state the image size. *Done: see the doc's Last verified line.*
- [x] **m** `15:375, 460`: PCA is fitted on all rows, including validation (leakage). Fit on train only, or comment on it. *Done: see the doc's Last verified line.*
- [x] **m** `15:302, 994-995`: no Python seed; the transfer tolerance of 1 point is too tight. Seed it, and use about 2 points. *Done: see the doc's Last verified line.*
- [x] **m** `15:542`: "module 16" should be "module 14". *Done: see the doc's Last verified line.*
- [x] **m** `15:837, 899-911`: reuse 14's `Fixtures.cs` walker instead of a cwd-relative `../fixtures`. *Done: see the doc's Last verified line.*
- [x] **m** `15:446`: honour `FIXTURES_DIR`. *Done: see the doc's Last verified line.*
- [x] **m** `15:990`: there's no container command for Python `transfer`. *Done: see the doc's Last verified line.*
- [x] **verify on first build** ScottPlot in `runtime:10.0` (SkiaSharp native assets, fonts); don't fail after the CSV is written. *Done: in 15's "Verify on first build" list.*
- [x] **verify on first build** TorchSharp Adam state vs dispose scopes; add a 2-epoch parameter-validity test. *Done: in 15's "Verify on first build" list.*

## 16 — Fine-tuning

- [x] **M** `16:300-304`: about a third of the eval rows are duplicates of training rows (same generator, 6 items). Dedupe or split by item set, and add a no-overlap test. *Done: see the doc's Last verified line.*
- [x] **M** `16:226-234, 486`: Windows `uv sync --extra train` gets CPU torch. Add a CUDA index source or recommend WSL2/Colab, plus VRAM and time numbers. *Done: see the doc's Last verified line.*
- [x] **M** `16:478-494, 1044`: Python never produces the base-vs-tuned scorecard or the `fixtures/generations/*.jsonl` the Checkpoint asks for. Add `ft.compare` with Ollama, or state that C# owns recording. *Done: see the doc's Last verified line.*
- [x] **m** `16:231-232`: `processing_class` needs `trl>=0.12`. *Done: see the doc's Last verified line.*
- [x] **m** `16:340`: `torch_dtype` → `dtype`; prefer bf16 or `"auto"`. *Done: see the doc's Last verified line.*
- [x] **m** `16:598`: the llama.cpp converter needs its own requirements install. *Done: see the doc's Last verified line.*
- [x] **m** `16:971`: `record` should create `fixtures/generations/`. *Done: see the doc's Last verified line.*
- [x] **m** `16:438`: Python raises ZeroDivisionError on an empty set; C# throws `ArgumentException`. Match them. *Done: see the doc's Last verified line.*
- [x] **m** `16:385, 1046`: the docstring claims a general-capability probe exists; it doesn't. *Done: see the doc's Last verified line.*

## 17 — Capstone

- [x] **M** `17:256-260`: C# is Bedrock-only and ignores `LLM_BACKEND`, so local contract and eval tests fail. Switch on the backend (Ollama/stub/Bedrock). *Done: see 17's Last verified line.*
- [x] **M** `17:493-513`: the C# image keeps 8080 with no `ASPNETCORE_HTTP_PORTS=8000` and no `USER $APP_UID`, which contradicts 12 and line 592. Reuse 12's Dockerfile, with compose `8001:8000`. *Done: see 17's Last verified line.*
- [x] **M** `17:216, 584`: never names or wires in the 07/08/09/11 projects. Add a table of which earlier project feeds which component, with the reuse mechanism per language. `run_evals.py` re-implements 09's harness. *Done: see 17's Last verified line.*
- [x] **m** `17:193`: ZeroDivisionError on an empty set (see 16). *Done: see 17's Last verified line.*
- [x] **m** `17:149`: no command is given for `run_evals.py`. *Done: see 17's Last verified line.*
- [x] **m** `17:470-473`: pwsh env-var form. *Done: see 17's Last verified line.*

## Found during hardening

- [x] **m** Compose files in 04, 05, 06 and 16 still run Ollama unconditionally at `http://ollama:11434`. Move them to the [profile pattern](conventions.md#ollama) that 07 and 10 use, so native Ollama works without editing the file. *Done: 04, 05, 06 moved; 07, 10, 16 already used it. .env.example files leave OLLAMA_BASE_URL commented.*

- [x] **M** Judge temperature parity: module 04's Python client can't send a temperature, so 09's Python judge samples at the server default while C# asks for 0 (09 documents the gap). Fix after 12 lands its `bedrock` change to the same factory: an optional `LLM_TEMPERATURE` read by both 04 factories (Python payload field; C# `ChatClientBuilder.ConfigureOptions`), then set it to 0 for 09's judge. *Done: LLM_TEMPERATURE in 04 (both languages, incl. 12's Bedrock); 09's judge borrows 0. Rebuilt: 04 pytest 18 / dotnet 18; 04+bedrock pytest 25 / dotnet 21; 09 pytest 39; 13 pytest 35.*

## R — Reviewing AI-written code

- [x] **M** `R:367-381`: `COPY . .` with no `.dockerignore`, so the Windows `.venv` clobbers the image's. Add one (`.venv/`, `__pycache__/`, `.pytest_cache/`, `mutants/`). *Done: see the doc's Last verified line.*
- [x] **m** `R:135`: `04-model-client` → `04-llm-client`. *Done: see the doc's Last verified line.*
- [x] **m** `R:295`: suggest reviewing each module's agent-written C#, not TypeScript. *Done: see the doc's Last verified line.*
- [x] **m** `R:362-364`: add `mutants/` to the ignore files. *Done: see the doc's Last verified line.*
- [x] **m** `projects/review-lab` is behind its doc (Python 3.11; no `package=false`, `hypothesis`, `mutmut`, `test_median_strong.py`, Dockerfile, `rubric/`/`reviews/`/`comparisons/`/`model_notes/`; empty README; leftover `main.py`). Expected for its stage; the README should say so. *Done: see the doc's Last verified line.*
