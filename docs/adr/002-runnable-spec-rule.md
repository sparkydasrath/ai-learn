# ADR-002: The runnable-spec rule

**Status:** accepted, 2026-10-05

## Context

The curriculum calls the Python implementation "the spec" and the C# one "a second implementation". But a 2026-10 review ([readiness checklist](../readiness-checklist.md)) found the Python side was often the *less* complete one:

- Files appeared in the layout tree, or were imported by a documented command, but were never shown: `hosted.py`/`demo.py` (04), `run.py` (06), `systems/qa_system.py` (09), `feedback.py` (11), `app/main.py` (13).
- Module 07's `/ask` raised `NotImplementedError`, which broke 07's checkpoint and modules 08, 09 and 11.
- pytest suites were missing while the C# NUnit suites were complete.

Some omissions were deliberate exercises; others were gaps. There was no rule for telling them apart.

## Decision

> The Python side of every module must run end to end with `LLM_BACKEND=stub`, and `uv run pytest` must pass, using only code shown in full in that doc plus its declared path dependencies.

From that:

- **Must be shown in full:** anything on the path to a documented run command or the Checkpoint, and anything a later module imports.
- **May be an exercise:** a second implementation of an interface already shown in full. The factory imports it lazily so the shown path never fails on an import, and the exercise names the acceptance test it must pass.
- **Never:** `NotImplementedError` on the module's own happy path, or a layout-tree file that a documented command needs but the doc doesn't show.

The C# side meets the same bar with `dotnet test`, and any behavioural difference is stated in the cross-check section.

## Consequences

- Docs get longer where the gaps were. Each added file is one the learner types anyway; it's just no longer a guess.
- `tools/doccheck` enforces the mechanical part: every file in a layout tree is either shown or marked as an exercise.
