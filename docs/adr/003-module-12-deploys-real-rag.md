# ADR-003: Module 12 deploys the real RAG service with a baked-in index

**Status:** accepted, 2026-10-05

## Context

Module 12 said it deployed module 07's RAG service, but what it deployed was a bare `/ask` proxy to Bedrock. It had no vector store, no fixtures and a different contract. Module 07 uses Chroma as a separate container and sentence-transformers in-process.

The options considered:

1. **Honest proxy:** deploy the minimal proxy, say so, and leave RAG-on-AWS to the capstone.
2. **Chroma sidecar** in the Fargate task, or a second service.
3. **Baked index:** compute the corpus embeddings at image build time and load them into an in-memory index at startup. Only the query is embedded at runtime.
4. **Managed vector store** (OpenSearch Serverless, pgvector on RDS).

## Decision

Option 3. One container, one task definition, no service discovery, no EFS, and no second container billing while idle. Module 07's C# side already has an `IVectorIndex` seam with an in-memory implementation, so "swap the index behind the interface" is the lesson.

Index and query must use the same embedding model. If the local sentence-transformers model doesn't fit the task size (512 CPU / 1024 MB), use Bedrock Titan embeddings (`BEDROCK_EMBED_MODEL_ID`) for *both* the baked index and the query. Never mix models across index and query.

A managed vector store (option 4) is the capstone's stretch goal.

## Consequences

- Module 12's `/ask` keeps module 07's contract (`question`, `k`, citations).
- The image build gains an embedding step, and the doc states the task size and image size it expects.
- The `/ask` endpoint is public, so module 12 restricts ALB ingress to the learner's IP in the same step that deploys it, not later in 13.
