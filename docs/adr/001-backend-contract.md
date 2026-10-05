# ADR-001: Model-backend contract

**Status:** accepted, 2026-10-05

## Context

Before this decision, modules disagreed on how a project picks a model:

- CLAUDE.md and doc 00 declared `LLM_BACKEND=ollama|hosted|bedrock|stub`, but module 04's factory, which every later module reuses, only accepted `ollama | hosted`. `stub` didn't exist anywhere.
- C# implementations often hard-coded Ollama and ignored `LLM_BACKEND` (06, 07, 08), used their own setting names (`Rag__OllamaBaseUrl` in 07), sent a hosted model name to Ollama (11), or were Bedrock-only (17), so they couldn't run locally.
- Python fell back to Ollama on unknown values in some modules and raised in others.
- Modules 07, 08 and 11 wrote their own model adapters instead of reusing 04's.

The result: the Python/C# cross-checks couldn't run like for like, and tests needed a live model.

## Decision

1. **Two tiers.** `stub` and `ollama` are required in every module from 04 on, in both languages. `bedrock` is required from module 12 on. `hosted` is taught in full in 04 and optional after that.
2. **`stub` is the load-bearing backend.** It's deterministic and offline, and it's what pytest, NUnit, CI and the cross-checks run on.
3. **One factory, in module 04's library.** Python projects reuse it with a uv editable path dependency; C# projects reference the `LlmClient` class library. Module 12 adds `bedrock` to that library as an optional extra (`boto3` / `AWSSDK.Extensions.Bedrock.MEAI`) instead of adding per-module adapters.
4. **Unknown values fail loudly**, in both languages, with the list of supported values. No silent fallback.
5. **One set of env-var names**, identical in both languages ([conventions](../conventions.md#environment-variables)). `LLM_BASE_URL` includes `/v1`, while `OLLAMA_BASE_URL` doesn't.

## Consequences

- Module 04 grows a `StubClient` (Python) and a stub `IChatClient` (C#), shown in full.
- Every later module's compose file gets `env_file` and `${LLM_BACKEND:-ollama}`, on both sides.
- Modules 07, 08 and 11 switch to the 04 library, which widens their Docker build context to `projects/`.
- Module 12 changes 04's library, so learners revisit a project they finished. That's deliberate: extending a shared library is the realistic lesson.
