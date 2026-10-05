# token-lab (Python)

Module 03 build project ([docs/03](../../../docs/03-llm-fundamentals-for-engineers.md)): count tokens, estimate cost, and compare embeddings from the command line.

```bash
uv sync
uv run pytest
uv run python -m token_lab.cli count "How many tokens is this sentence?"
uv run python -m token_lab.cli cost --in-tokens 4000 --out-tokens 500 --in-price 0.003 --out-price 0.015
uv run python -m token_lab.cli sim "a cat sat on the mat" "the feline rested on the rug"
```

Docker:

```bash
docker build -t token-lab-py .
docker run --rm token-lab-py count "How many tokens is this sentence?"
docker run --rm --entrypoint uv token-lab-py run --no-sync pytest
```
