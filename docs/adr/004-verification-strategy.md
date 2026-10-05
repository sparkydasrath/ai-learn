# ADR-004: How the docs are verified

**Status:** accepted, 2026-10-05

## Context

The module docs hold about 19,000 lines, most of them code that was never compiled or run. The options for hardening them were:

1. **Doc-only edits**, by reading against the conventions.
2. **Build every module** in both languages inside `projects/`. This gives the highest confidence, but it's huge, and it takes the build away from the learner, who is meant to type each project.
3. **Extract and compile every snippet.** The snippets are partial files with elisions and helpers defined elsewhere, so most of the errors would be artifacts of the extraction.

## Decision

A hybrid:

- **Build the dependency spine for real, in a scratch folder, then throw it away.** That's modules 04 (model client) and 07 (RAG service), both languages. Modules 05, 06, 08, 09, 11, 12, 13 and 17 build on them. Nothing is committed under `projects/`, so the learner still builds every project.
- **Lint everything mechanically** with `tools/doccheck`: links and anchors, required sections, layout tree vs shown files, bash-only env syntax, stale API names.
- **Don't build-verify 14–16.** torch, TorchSharp and ML.NET setup costs more than it would catch, and nothing downstream depends on those modules.
- **"Verify this API" items** that no build covers become a per-module *verify on first build* list. The learner's Review-track journal records the answers.

## Consequences

- Verification isn't reproducible from the repo alone. Each module records how it was checked in a *Last verified* line (`read-only` or `built`, with a date).
- The scratch builds also confirm package versions; the docs pin to what built.
