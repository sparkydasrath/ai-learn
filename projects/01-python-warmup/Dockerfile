# Pin a specific Python; :latest drift bites you the same way in every ecosystem.
FROM python:3.13-slim

# uv ships as a tiny static binary; copy it from the official image.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Copy dependency manifests first so this layer caches unless deps change
# (same instinct as copying .csproj before the rest for `dotnet restore`).
# Include README.md here because hatchling validates the project metadata and
# requires it to exist in the build context before `uv sync` can build the package.
COPY pyproject.toml README.md uv.lock ./
RUN uv sync --frozen --no-install-project

# Copy src
COPY src/ ./src/
COPY tests/ ./tests/
RUN uv sync --frozen

ENTRYPOINT ["uv", "run", "textstats"]
