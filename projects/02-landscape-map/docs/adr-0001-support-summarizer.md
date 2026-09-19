# ADR 0001 - Summarize support tickets with an LLM

## Status
Proposed

## Context
Support agents spend ~2min/ticket writing summary for handoff.
~4000 tickets/week. We want auto-generated draft summaries.

## Decision
Use a hosted LLM (via AWS Bedrock) behind our exisiting ticketing service.
Prompt-only to start (no fine-tuning, no RAG) - a summary needs only the ticket text already in the request.

## Options considered
1. Deterministic extractive summary (first + last sentence). Cheap, no model.
Rejected: quality too low for handoff.
2. Hosted LLM, prompt-only. Chosen: fast to ship, quality high, low volume.
3. Self-hosted open model. Rejected for now: 4k/week doesn't justify GPU ops.
4. Fine-tuned model. Rejected: no evidence prompting is insufficient yet.

## How we'll know it's good (the AI-specific section)
- Eval set: 50 tickets with human-written reference summaries.
- Metric: LLM-as-judge for faithfulness + a length check. Target >= 90% "faithful" with no hallucinated facts. (Module 09 builds this for real.)
- Guardrail: never emit PII not present in the source ticket.

## Consequences
- New probabilistic dependency; outputs vary run to run - test by eval not equality.
- Per-token cost ≈ tracked per ticket; alarm if weekly spend exceed $X.
- Provider can update model; the eval set is our regression suite.