# AI Engineering — a build-first curriculum

A structured path from senior/staff **.NET engineer** to **AI engineer**, without a deep math or ML-research background. The bet: you already know how to build and ship software. What you need is the AI-specific layer — models, retrieval, agents, evaluation, and the ops to run them — learned the way you learned everything else: **by building real, checked-in projects** and moving them from **local Docker** to **AWS as pretend prod**.

> New here? Read [00 — How to use these docs](00-how-to-use-these-docs.md) first. It explains the format, the tooling, and how to actually get to expert instead of just reading.

## What "expert AI engineer" means here

Not "good at prompting." Not "can wire up a chatbot from a tutorial." By the end you should be able to:

- Take a vague product ask and decide **whether it needs AI at all**, and if so, whether it's prompting, RAG, an agent, fine-tuning, or classical ML.
- Build the thing, **measure whether it's actually good** with real evals (not vibes), and iterate on the number.
- Ship it to production with observability, guardrails, cost control, and a rollback story.
- Debug it when it's wrong, slow, or expensive — and know *which* of those three you're even looking at.
- Read a model card, a paper's abstract, or a new framework's docs and slot it into your mental model in minutes.

## The path

Work through these in order. Each builds on the last, and each ends with a project you commit to this repo.

### Phase 1 — Foundations
| # | Module | You'll be able to… |
|---|--------|--------------------|
| 01 | [Python for .NET engineers](01-python-for-dotnet-engineers.md) | Write idiomatic, typed, tested Python and run the modern toolchain (uv, ruff, pytest) without fighting it. |
| 02 | [The AI engineering landscape](02-ai-engineering-landscape.md) | Place yourself in the stack: AI engineer vs ML researcher vs data scientist, and the shape of a real AI system. |
| 03 | [LLM fundamentals for engineers](03-llm-fundamentals-for-engineers.md) | Reason about tokens, context windows, sampling, and embeddings well enough to make design and cost decisions. |

### Phase 2 — Working with models
| # | Module | You'll be able to… |
|---|--------|--------------------|
| 04 | [Calling models: APIs & SDKs](04-calling-models-apis-sdks.md) | Call hosted and local models correctly — streaming, retries, timeouts, cost/latency accounting. |
| 05 | [Prompt engineering as engineering](05-prompt-engineering-as-engineering.md) | Treat prompts as versioned, tested artifacts driven by evals, not trial-and-error. |
| 06 | [Structured outputs & tool calling](06-structured-outputs-and-tool-calling.md) | Get reliable JSON out of models and let them call your code safely. |

### Phase 3 — Building systems
| # | Module | You'll be able to… |
|---|--------|--------------------|
| 07 | [Retrieval-augmented generation (RAG)](07-retrieval-augmented-generation.md) | Build a real RAG pipeline: chunking, embeddings, a vector store, and retrieval you can measure. |
| 08 | [Agents & orchestration](08-agents-and-orchestration.md) | Build multi-step, tool-using agents — and know when *not* to. |
| 09 | [Evaluation & testing](09-evaluation-and-testing.md) | **The core skill.** Build eval sets, LLM-as-judge, and regression tests so quality is a number, not a feeling. |

### Phase 4 — Production / LLMOps
| # | Module | You'll be able to… |
|---|--------|--------------------|
| 10 | [Serving & inference (local)](10-serving-and-inference-local.md) | Run and serve open models locally in Docker; understand quantization and throughput. |
| 11 | [Observability & guardrails](11-observability-and-guardrails.md) | Trace, log, and monitor AI systems; add input/output guardrails and safety checks. |
| 12 | [Deploying to AWS](12-deploying-to-aws.md) | Ship a system to AWS (Bedrock, ECS/Lambda, IaC) as a stand-in for production. |
| 13 | [Cost, scaling & security](13-cost-scaling-and-security.md) | Control spend, cache, scale, and defend against prompt injection and data leaks. |

### Phase 5 — Depth & capstone
| # | Module | You'll be able to… |
|---|--------|--------------------|
| 14 | [Classical ML foundations](14-classical-ml-foundations.md) | Do the non-LLM ML that still wins (classification, regression, embeddings) with scikit-learn. |
| 15 | [Deep learning intuition](15-deep-learning-intuition.md) | Read and modify a PyTorch training loop; understand what training actually does. |
| 16 | [Fine-tuning & adaptation](16-fine-tuning-and-adaptation.md) | Decide when to fine-tune and do a LoRA fine-tune end to end. |
| 17 | [Capstone & portfolio](17-capstone-and-portfolio.md) | Ship one substantial, evaluated, deployed system that proves the whole stack. |

## How the projects stack up

Each module's project is small on its own, but they compound. By Phase 3 you're assembling earlier pieces; the capstone (17) pulls the whole thing together into one deployed, evaluated system you can show people.

## Conventions

- Projects live in `projects/<NN>-<name>/` at the repo root (each self-contained: its own `pyproject.toml`, `Dockerfile`, tests, README).
- Every project runs **locally in Docker first**, then has notes on **moving it to AWS**.
- Secrets go in `.env` (git-ignored); commit a `.env.example`.
- Python is the default language for AI code; see module 01 for the toolchain.
