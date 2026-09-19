FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
ENV PYTHONPATH=/app/src
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project
COPY /src ./src
RUN uv sync --frozen
ENTRYPOINT ["uv", "run", "python","-m", "hello_model.main"]