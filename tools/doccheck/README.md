# doccheck

Lints `docs/*.md` against [docs/conventions.md](../../docs/conventions.md). From the repo root:

```bash
uv run --project tools/doccheck doccheck            # all docs; exit code 1 if any error
uv run --project tools/doccheck doccheck docs/07-retrieval-augmented-generation.md
uv run --project tools/doccheck doccheck --strict   # warnings fail too
uv run --project tools/doccheck pytest tools/doccheck/tests
```

| Rule | Level | What it catches |
|---|---|---|
| `link` | error | relative link to a missing file or anchor |
| `section` | error | a module doc (03–17) missing a required section, or Review track sync not just before Checkpoint |
| `stale-api` | error | pre-GA Microsoft.Extensions.AI names, the deprecated MEAI Ollama package, `.[dev]` extras, inside code blocks |
| `not-implemented` | error | `raise NotImplementedError` / `throw new NotImplementedException` in a code block ([ADR-002](../../docs/adr/002-runnable-spec-rule.md)) |
| `bash-env` | warning | `VAR=x cmd` in a code block without a pwsh form nearby |
| `layout` | warning | a file in a layout tree that no code block names (in a path comment on its first line, or in the prose just above it) and that isn't marked `exercise` or generated |
| `ollama-wiring` | warning | a compose block hard-coding `http://ollama:11434`, or an `.env.example` block setting `OLLAMA_BASE_URL` ([conventions](../../docs/conventions.md#ollama)) |
| `verified` | warning | a module doc with no `Last verified:` line |

Silence a rule for one code block by putting `<!-- doccheck: ignore=<rule> -->` on the line before it.
