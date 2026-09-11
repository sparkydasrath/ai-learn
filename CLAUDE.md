# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a **learning repository** for a senior/staff-level .NET engineer becoming an AI engineer. The goal is practical AI engineering skill — building real, working systems — **without** requiring a deep math or theoretical-ML background. Favor intuition, working code, and "why this matters in practice" over derivations and proofs.

### Learner profile & how to work with them

- **Background:** senior/staff-level .NET engineer. Assume strong software-engineering fundamentals — architecture, testing, CI, API design, debugging, source control. You do **not** need to explain those; you *can* explain new AI concepts by analogy to them.
- **Python:** the learner is language-agnostic and wants to *improve* Python, since it's the lingua franca of AI work. Prefer Python for AI/ML code and treat idiomatic Python (typing, virtualenvs, packaging, tooling) as something worth teaching in passing, not assuming.
- **Math/theory:** keep it light. Introduce a concept when it's needed to make a decision or debug something, at the level a working engineer needs — not a course in it.

### The curriculum

The learning path lives in [`docs/`](docs/README.md) — a build-first curriculum of 18 modules (00–17) taking the learner from Python foundations to a deployed, evaluated capstone. Start at [`docs/README.md`](docs/README.md). Each module ends with a hands-on project that belongs in `projects/<NN>-<name>/`. When helping with a module or its project, read that module's doc first so your guidance matches the curriculum's approach and vocabulary.

### Learning approach (important)

- **Learn by building.** Every topic should land as an actual project with **checked-in code**, not notebooks-as-scratch or throwaway snippets. Commit real, runnable examples.
- **Local first, then "pretend prod" in the cloud.** Develop and iterate **locally with Docker** for fast, cheap, reproducible loops. Once something works, the exercise is to **move it to AWS as a stand-in for production** — so treat deployability, packaging, and cloud services as part of the learning, not an afterthought.
- Prefer explaining trade-offs and pointing out where a decision matters, since the learner can handle depth on the engineering side.

## Current state

Fresh scaffold. As of the initial commit the repository contains only a `.gitignore` (standard .NET template — ignores `bin/`, `obj/`, `artifacts/`, `.env`, test results, etc.) and this file. No source code, solution, README, or CI config yet.

Despite the .NET-flavored `.gitignore`, expect the AI/ML work to be primarily **Python**. As projects land, add the equivalent Python ignores (`__pycache__/`, `.venv/`, `*.egg-info/`, etc.) and update the sections below.

## Update this file as the project grows

Once code exists, document here:

- **Build / run / test commands** — per project (e.g. how to create the venv and install deps, run the app, run tests and a single test).
- **Docker workflow** — how to build and run each project's container locally.
- **AWS / deployment** — how a given project is deployed to AWS and which services it uses.
- **Layout & architecture** — the project structure and any high-level design that isn't obvious from a single file.
