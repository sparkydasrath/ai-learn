# Hardening handoff (resume here)

**Complete (2026-10-06).** Every module (03–17) and the R track is hardened and committed; every checklist item is closed; `uv run --project tools/doccheck doccheck --strict` is clean on all docs. This file is kept as the record of how the pass was done. What's left is optional: a PR to `main`, and, when Docker, Ollama and AWS are available, building the images and running the live-model and deploy paths each module's `Last verified` line lists as read-only.

## Done and committed

| Layer | Status |
|---|---|
| Foundation: conventions, ADR-001 to 004, `tools/doccheck`, scaffold scripts, `.gitignore`, `03-token-lab` | committed |
| 03–16 and R (everything except 17) | committed, each with a `Last verified:` line. 04–13 and 16 were built for real in a throwaway scratch build; 14 and 15 partly. |
| Ollama compose profile pattern across 04–07, 10, 16; `.env.example` leaves `OLLAMA_BASE_URL` commented | committed |
| doccheck `ollama-wiring` rule | committed |

`uv run --project tools/doccheck doccheck` reports no errors; the only warnings left are in 17. Checklist: every item is ticked except module 17's and the judge-temperature item.

## Modules 12 + 13 (last finished)

 12 deploys the real 07 service with a baked index (Titan embeddings for index and query), adds `bedrock` to module 04's library in both languages, and fixes every cost and security item; 13 shows `main.py` and `run_evals.py` in full. Built in scratch (04+bedrock: pytest 22 / dotnet 21; 07+baked: 29 / 28; 13: 35 / 24); Terraform and AWS are read-only (Terraform wasn't installed). Note for step 1 below: 13 added `client_from_env(model: str | None = None)` to 04's Python factory, and 04's C# library now references the AWS packages.

## What remained at the pause (all done since)


1. ~~**Judge temperature parity**~~ Done: optional `LLM_TEMPERATURE` in 04's factories (Python payload / Bedrock `inferenceConfig`; C# `ConfigureOptions`), and 09's judge borrows `LLM_TEMPERATURE=0`. Docs 04, 09, 12 and conventions updated from rebuilt code.
2. **Module 17 (capstone).** Open items are in the checklist (`17:256-260`, `17:493-513`, `17:216, 584`, `17:193`, `17:149`, `17:470-473`, plus doccheck warnings). Also:
   - Wire in the earlier projects with a table: which project feeds which component, and the reuse mechanism per language. The HTTP contracts to reuse are 07 `/ask`, 11 `/ask` + `/feedback` (ports 8010/8011), and the 08 CLI library API. 09's `evalkit` (Python) and `EvalHarness` library (C#) replace `run_evals.py`.
   - C# honours `LLM_BACKEND` via `AddLlmClient` (stub/ollama/bedrock); Dockerfile uses 12's pattern (`ASPNETCORE_HTTP_PORTS=8000`, `USER $APP_UID`, compose `8001:8000`).
   - Remove the test→src `ProjectReference` for the contract tests; pwsh forms; Last verified line.
3. **Final pass:**
   - `uv run --project tools/doccheck doccheck --strict` (warnings fail).
   - Update CLAUDE.md's "Current state" (hardening done; remove "in progress").
   - Close or mark everything left in the checklist.
   - Summarize for the user, and offer a PR to `main`.

## How the module passes were done

- Each module was handed to a background `general-purpose` agent with a brief. The essentials:
  - Follow conventions and the ADRs.
  - Build both languages in a scratch folder (never under `projects/`, since the learner types each project). Python must pass `uv run pytest` on `LLM_BACKEND=stub`; C# must pass `dotnet test`.
  - Regenerate the doc's code blocks from the built files, so the doc equals the verified code.
  - Use pwsh command forms, run doccheck, and add `Last verified:` plus `Verify on first build:` before `Next:`.
  - Edit only that module's doc; report checklist fragments fixed and requests for shared files.
- The coordinator reviews each report, applies shared-file changes (conventions, checklist, CLAUDE.md), and commits per module.
- The scratch builds and helper scripts (`BRIEF.md`, `gen_doc.py`, `tick.py`) lived in the session scratchpad and may be gone in a new session. Rebuild a module's prerequisites from their docs if needed: 04 and 07 are the spine.
- Docker Desktop was not running and no live Ollama or AWS was available, so images, live models and deployment are "read-only" in every `Last verified` line. If they're available next time, building the images is the next level of verification.
- Gotchas:
  - `rm -rf` and writing `.env*` files are blocked by permissions: make new folders instead, and show `.env.example` content inline in docs.
  - The scratch path was long enough to hit Windows' 260-character limit with `transformers`; use a short venv path.
