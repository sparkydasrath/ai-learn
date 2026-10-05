# 00 — How to use these docs

> **Background for this whole series.** You're a senior/staff-level .NET engineer becoming an AI engineer. These docs assume you're excellent at software engineering — architecture, testing, CI, APIs, debugging, git — and they will *not* re-teach that. They teach the AI-specific layer on top, using analogies to things you already know. Math stays light and just-in-time: introduced only when you need it to make a decision or debug something. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default language, and improving your Python is part of the point. From module 03 on, each project is also rebuilt in C#, so you come out fluent in both.

This doc is the meta-guide: how the series is structured, how to work through it, and how to actually reach expert level instead of just accumulating reading.

## The shape of every module

Each numbered doc follows the same pattern so you always know where you are:

1. **Background box** (like the one above) — restates who you are and how to read it, so any doc stands alone.
2. **Where this fits** — prerequisites and what you'll be able to do afterward.
3. **Concepts** — explained for an engineer, with .NET/SWE analogies. Just enough theory to be dangerous.
4. **The build project** — the point of the module. Concrete, checked into `projects/`, runs locally in Docker, with notes on moving to AWS. From module 03 on it's built twice, in Python and then in C# (see below), and it ends with a **cross-check** that runs the same inputs through both.
5. **How experts think / common pitfalls** — the judgment that separates an AI engineer from someone pasting prompts.
6. **Review track sync** — what to review from the [R track](R-reviewing-ai-written-code.md) before moving on, including a *C#-specific watch* list of API mistakes agents make.
7. **Checkpoint** — an honest self-test. If you can't do these, don't move on.
8. **Going deeper** (optional) — where to read more when you want the theory.

Each module doc ends with a *Last verified* line saying how its code was checked: `read-only` (reviewed against the conventions) or `built` (built and run).

## How to actually get to expert

Reading these will make you *conversant*. Building the projects — and getting the evals green — is what makes you *good*. Some rules:

- **Type the code, don't paste it.** You learned .NET by writing it. Same here.
- **Break things on purpose.** Feed a RAG system a question it can't answer. Give an agent a tool that fails. Watch what happens. AI systems fail in ways deterministic code doesn't, and you need reps.
- **Measure before you optimize.** From module 09 onward, "is it better?" should always be answerable with a number. Resist the urge to tune prompts by feel.
- **Keep a lab notebook.** A `NOTES.md` per project: what you tried, what the eval said, what surprised you. This is your real learning artifact.
- **Run the review track alongside.** [R — Reviewing AI-written code](R-reviewing-ai-written-code.md) is a parallel track, not a numbered module. Every module doc has a **Review track sync** section just before its Checkpoint, telling you what to review, what to watch for and what to finish before moving on.
- **Don't skip Phase 3's evaluation module (09).** It's the single biggest difference between an AI engineer and a vibe coder. If you only deeply learn one thing here, learn to evaluate.

## Two languages: Python first, then C#

From module 03 on, every build project is done **twice**: Python first, then C#/.NET. Python is the main language of AI work, so it goes first and it's where you learn the concept. The C# version comes second. It makes you rebuild the idea without Python's libraries doing the work, and it gives you the .NET skills you'd use to ship AI features in a real .NET shop. Modules 01–02 are Python-only on purpose. They're about Python fluency and the landscape.

The layout:

```
projects/<NN>-<name>/
├── fixtures/   # committed datasets both languages read (labeled sets, eval sets, corpora)
├── python/     # uv project: pyproject.toml, src/, tests/ (pytest), Dockerfile
└── csharp/     # .NET solution: <Name>.slnx, src/, tests/ (NUnit), Dockerfile
```

Shared data lives once, in `fixtures/` at the project root. Both languages read it through a `FIXTURES_DIR` setting. One copy means the two sides can't drift. It's also the one place `.gitignore` lets datasets through: `data/` and `*.jsonl` are ignored everywhere else.

The detailed rules every module follows live in one place, **[Conventions](conventions.md)**, so module docs link to it instead of restating it:

- [the two Python project shapes](conventions.md#python-project-shapes): *library* (`src/`, installed) and *service* (`app/`, never installed)
- [model backends and env vars](conventions.md#model-backends): `LLM_BACKEND=stub|ollama|hosted|bedrock`, the same names in both languages. `stub` runs offline, and it's what the tests and cross-checks use.
- [Ollama](conventions.md#ollama), [ports](conventions.md#ports), [compose](conventions.md#compose), [Docker](conventions.md#docker) and [PyTorch wheels](conventions.md#pytorch-wheels)
- [shell commands](conventions.md#shell-commands): every command works in PowerShell 7
- [what a module doc must show](conventions.md#what-a-module-doc-must-show): the Python side of every module runs end to end with `LLM_BACKEND=stub`, using only code the doc shows

The bigger decisions behind those rules, with the alternatives that were rejected, are in [decision records](adr/).

Each language folder is self-contained. It has its own Dockerfile, its own tests, and its own README with run commands, and it builds without the other one. Scaffold each side with its bootstrap script, `scripts/new-python-project.ps1` and `scripts/new-csharp-project.ps1` (see [project bootstrap automation](project-bootstrap-automation.md)).

The two sides share *behavior*: same CLI commands or endpoints, same inputs, same outputs (within tolerance). Treat the Python version as the spec and the C# version as a second implementation of it. When they disagree, that's a lesson, not just a bug. Usually one library is doing something the other one isn't. Every module's build project ends by cross-checking the two.

Rules of thumb for the C# side:

- **Don't port line by line.** Write idiomatic .NET: records, `decimal` for money, `IParsable<T>`, `Span<T>`, DI-friendly interfaces. The point is fluency in both languages, not Python written in C#.
- **Reach for the .NET AI building blocks:** `Microsoft.ML.Tokenizers` (tokenizers), `System.Numerics.Tensors` (SIMD vector math, the `numpy` stand-in), `Microsoft.ML.OnnxRuntime` (running local models), `Microsoft.Extensions.AI` (provider-neutral `IChatClient` / `IEmbeddingGenerator` abstractions), and the AWS SDK for .NET (Bedrock).
- **Expect the .NET side to be closer to the metal.** Python libraries often hide a whole pipeline behind one call. In .NET you'll often build that pipeline yourself. That's extra work, and it's also where a lot of the learning happens.
- **Test with NUnit.** `Assert.That(actual, Is.EqualTo(expected))` and `[TestCase]` are the counterparts of pytest's `assert` and `parametrize`.

## Tooling you'll set up in module 01

- **PowerShell 7** (`pwsh`). Windows ships only Windows PowerShell 5.1, and the scaffold scripts and VS Code tasks need 7: `winget install Microsoft.PowerShell`. Commands in these docs are written for it.
- **Python 3.12+** managed with `uv` (fast, handles venvs and installs).
- **Ruff** for lint+format, **pytest** for tests, **mypy/pyright** for type checking.
- **.NET 10 SDK** for the C# side (from module 03), with **NUnit** for tests and C# Dev Kit in VS Code.
- **Docker Desktop** (WSL2 backend) for every project's local runtime.
- **Ollama** for local models (from module 04; see [Ollama](conventions.md#ollama)), and optionally an **API key** for a hosted model provider.
- An **AWS account** for the "pretend prod" deployments (spend a little, set a budget alarm — module 13 covers cost control).

## A note on the AI landscape moving fast

Specific model names, prices, and framework versions in these docs will age. The *mental models* — tokens, retrieval, evaluation, serving, cost — do not. When a doc names a specific tool, treat it as "an example of this category," and check current docs before you pin a version. Module 02 gives you the durable map; the rest hang details off it.

Next: [01 — Python for .NET engineers](01-python-for-dotnet-engineers.md).
