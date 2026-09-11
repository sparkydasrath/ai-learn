# 00 — How to use these docs

> **Background for this whole series.** You're a senior/staff-level .NET engineer becoming an AI engineer. These docs assume you're excellent at software engineering — architecture, testing, CI, APIs, debugging, git — and they will *not* re-teach that. They teach the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time: introduced only when you need it to make a decision or debug something. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default language, and improving your Python is part of the point.

This doc is the meta-guide: how the series is structured, how to work through it, and how to actually reach expert level instead of just accumulating reading.

## The shape of every module

Each numbered doc follows the same pattern so you always know where you are:

1. **Background box** (like the one above) — restates who you are and how to read it, so any doc stands alone.
2. **Where this fits** — prerequisites and what you'll be able to do afterward.
3. **Concepts** — explained for an engineer, with .NET/SWE analogies. Just enough theory to be dangerous.
4. **The build project** — the point of the module. Concrete, checked into `projects/`, runs locally in Docker, with notes on moving to AWS.
5. **How experts think / common pitfalls** — the judgment that separates an AI engineer from someone pasting prompts.
6. **Checkpoint** — an honest self-test. If you can't do these, don't move on.
7. **Going deeper** (optional) — where to read more when you want the theory.

## How to actually get to expert

Reading these will make you *conversant*. Building the projects — and getting the evals green — is what makes you *good*. Some rules:

- **Type the code, don't paste it.** You learned .NET by writing it. Same here.
- **Break things on purpose.** Feed a RAG system a question it can't answer. Give an agent a tool that fails. Watch what happens. AI systems fail in ways deterministic code doesn't, and you need reps.
- **Measure before you optimize.** From module 09 onward, "is it better?" should always be answerable with a number. Resist the urge to tune prompts by feel.
- **Keep a lab notebook.** A `NOTES.md` per project: what you tried, what the eval said, what surprised you. This is your real learning artifact.
- **Don't skip Phase 3's evaluation module (09).** It's the single biggest difference between an AI engineer and a vibe coder. If you only deeply learn one thing here, learn to evaluate.

## Tooling you'll set up in module 01

- **Python 3.12+** managed with `uv` (fast, handles venvs and installs).
- **Ruff** for lint+format, **pytest** for tests, **mypy/pyright** for type checking.
- **Docker** for every project's local runtime.
- An **API key** for a hosted model provider (for early modules) and **Ollama** for local models (from module 10).
- An **AWS account** for the "pretend prod" deployments (spend a little, set a budget alarm — module 13 covers cost control).

## A note on the AI landscape moving fast

Specific model names, prices, and framework versions in these docs will age. The *mental models* — tokens, retrieval, evaluation, serving, cost — do not. When a doc names a specific tool, treat it as "an example of this category," and check current docs before you pin a version. Module 02 gives you the durable map; the rest hang details off it.

Next: [01 — Python for .NET engineers](01-python-for-dotnet-engineers.md).
