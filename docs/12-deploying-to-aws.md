# 12 — Deploying to AWS

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. These docs assume you're excellent at software engineering — architecture, testing, CI/CD, containers, IaC, cloud — and won't re-teach that. They teach the AI-specific layer on top, using analogies to what you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default language; Python-isms are flagged.

## Where this fits

You have a working RAG service ([07](07-retrieval-augmented-generation.md)), measured by evals ([09](09-evaluation-and-testing.md)), servable locally ([10](10-serving-and-inference-local.md)), and instrumented and guarded ([11](11-observability-and-guardrails.md)). Now you ship it to AWS as **pretend production**: module 07's service itself, same `/ask` contract and citations, running on ECS Fargate with Bedrock as the model ([ADR-003](adr/003-module-12-deploys-real-rag.md)).

You already know CI/CD, containers and IaC, so this module doesn't teach Docker or Terraform. It teaches the **AI-specific deployment decisions**: which compute fits an LLM workload, how Bedrock works as a backend, where the vector index lives when there's no Chroma, how IAM scoping works for models that hop regions, and how to stop a per-token service from billing you while you sleep.

The build project *is* the AWS move. The single most important instruction: **set a budget before you deploy anything.**

After this module you'll be able to:

- Pick a deployment target (Lambda / ECS Fargate / EKS / EC2-GPU) for a given AI workload and defend it.
- Add a Bedrock backend to module 04's shared client in both languages, authenticated by IAM, through the `Converse` API.
- Bake a RAG index into an image so one container serves retrieval with no vector database.
- Push to ECR and run on ECS Fargate behind an ALB that only your IP can reach, with secrets from SSM.
- Express the stack as code (Terraform, or CDK in C#), deploy it with a script, and tear it down completely.
- Run the identical image locally, offline and then against Bedrock, before it ever reaches AWS.
- Deploy the C# image to the same stack and know when .NET on Lambda (cold starts, Native AOT) makes sense.

## Deployment target choices for AI apps

Most AI apps are **web services that call a model**, so the usual compute reasoning applies, with one twist: **latency is dominated by the model call (often seconds), not your code.**

- **AWS Lambda**: spiky, light, event-driven work. Good for async jobs, webhooks, batch scoring and low-traffic endpoints. Watch the **request/timeout ceiling** (long generations hit it; API Gateway and Lambda both cap duration) and **cold starts** (a cold container plus a multi-second model call is a slow first request). Scales to zero.
- **ECS Fargate**: always-on containerized HTTP services. **The default for a chat/RAG API.** No EC2 to manage, autoscaling, works with an ALB and streaming. The build project lands here.
- **EKS**: Fargate's power without the ceiling, for teams already on Kubernetes or needing fine-grained scheduling (including GPUs). More ops.
- **EC2 GPU** (`g`/`p` families): only when you **self-host the model** ([10](10-serving-and-inference-local.md)). If the model lives in Bedrock or a hosted API, your service is CPU-bound glue. GPUs for an app that calls Bedrock is the most common expensive misconfiguration.

Rule of thumb: **always-on API → Fargate; spiky/async → Lambda; self-hosting the model → EC2-GPU/EKS.**

## Bedrock as the model backend

Amazon **Bedrock** is AWS's managed, per-token model service. It removes the two hardest parts of self-hosting, GPUs and scaling, and it authenticates the way the rest of your AWS stack does.

- **Auth via IAM, not API keys.** The Fargate **task role** gets `bedrock:InvokeModel`, and the AWS SDK signs requests with the role's temporary credentials. No key to store or rotate. Locally, the same SDK code uses your `ai-learn` profile ([environment settings](env-settings.md)).
- **`Converse`, the model-agnostic API.** One request shape (system prompt, user/assistant turns, `inferenceConfig`) across model families, so your code doesn't speak each vendor's JSON dialect. It's the same "program against the interface" instinct as module 04's `LlmClient`. The lower-level `InvokeModel` takes a model-specific body; this module uses it only for Titan embeddings, which have no Converse equivalent. IAM authorizes `Converse` with the `bedrock:InvokeModel` action; there's no `bedrock:Converse` action.
- **Inference profiles.** Many models can't be invoked on demand by their base ID in every region. A **cross-region inference profile** (`us.amazon.nova-micro-v1:0`: the model ID with a geography prefix) routes each request to one of several regions. That matters for IAM: the policy needs the profile's ARN *and* the foundation-model ARN in every region the profile can route to (step 5 builds that list).
- **Model access.** Amazon retired the per-model access page for most serverless models: an IAM principal allowed `bedrock:InvokeModel` can call them in any region where they're offered. Two exceptions: Anthropic models need a one-time first-use form (company and use case) per account, and models sold through AWS Marketplace subscribe on the first call, which needs Marketplace permissions on whoever calls first. This module defaults to Amazon's own Nova Micro (chat) and Titan Text Embeddings V2, which need neither.
- **Look up IDs; don't remember them.** Availability changes by region and month. `aws bedrock list-inference-profiles` and `aws bedrock list-foundation-models` are the source of truth, not a blog post (or this doc).

## Containerizing → ECR → ECS Fargate behind an ALB

1. **Containerize** with the service Dockerfile you already have, built for `linux/amd64`, or `linux/arm64` for Graviton (cheaper). The model doesn't live in the image; Bedrock does.
2. **Push to ECR**, AWS's private registry.
3. **An ECS service** runs N tasks from that image. The **task definition** declares CPU and memory, the image, env vars, secrets, log config (→ CloudWatch, module [11](11-observability-and-guardrails.md)) and two roles. The **task role** is what your code runs as (Bedrock). The **execution role** is what ECS uses to *start* the task: pull from ECR, write logs, and resolve the `secrets` block from SSM.
4. **An ALB** in front. Fargate tasks run in `awsvpc` mode and register **by IP**, so the target group's `target_type` is `ip`. It health-checks `/health`, which must stay cheap: a health check that calls Bedrock bills you on every probe.

The service is CPU-light and latency is the Bedrock call, so autoscale on **request count or concurrency**, not CPU: a task waiting on a model barely moves the CPU needle ([13](13-cost-scaling-and-security.md) goes deeper).

## Secrets — never in the image

**No secrets in the Dockerfile, image layers or committed env files.** They persist in layers and in ECR.

- **SSM Parameter Store**: free for standard parameters, `String` or `SecureString`. The default for config and most secrets.
- **Secrets Manager**: rotation and cross-account sharing, for things that must rotate (database credentials, third-party API keys).
- ECS injects either into the container as env vars through the task definition's `secrets` block, at launch. ECS resolves them *before your code runs*, so the permission belongs on the **execution role**, not the task role: `ssm:GetParameters` on exactly those parameters, plus `kms:Decrypt` if a `SecureString` uses a customer-managed key (`secretsmanager:GetSecretValue` for Secrets Manager).

With Bedrock there's often **no model API key at all**, because IAM is the auth. This build still keeps the chat model ID in SSM, as a `String`: it's not a secret, but it's config you want to change without editing code, and it shows the `secrets` mechanism end to end.

## Infrastructure as code — pick one

- **AWS CDK**: infrastructure in a real language, including **C#**, with types and IntelliSense. Higher-level constructs collapse Fargate-behind-ALB into a few lines. AWS-only; compiles to CloudFormation.
- **Terraform**: declarative HCL, cloud-agnostic, a huge ecosystem, and explicit state.

The build project uses **Terraform** as the main path, because every resource is visible and that's the point of a first deployment. An optional section gives the same stack in **CDK C#**, for comparison and for when you'd rather stay in .NET. Pick one per stack, not both.

## CI/CD to deploy

GitHub Actions → ECR → ECS mirrors any container pipeline you've built:

1. On push to `main`, run the tests **and the [09](09-evaluation-and-testing.md) evals**: quality is a release gate.
2. Build the image, tag it with the git SHA, push it to ECR.
3. Roll the ECS service onto it (the ALB drains old tasks).
4. Authenticate with **OIDC** (a federated role), never long-lived access keys in repository secrets.

`deploy/deploy.ps1` below does steps 2 and 3. GitHub's Ubuntu runners ship PowerShell 7, so the same script runs in CI.

## Env parity between local Docker and cloud

The failure mode is "works in my container, breaks on Fargate". Keep parity by:

- **One image**: the one you run locally is the one you push.
- **Config through env vars with the same names everywhere** (compose or `.env` locally, the task definition in AWS).
- **The backend is the only difference**, and it's an env var. Locally, Ollama or the stub; in AWS, Bedrock.
- **Run the exact image against Bedrock locally first**, with your credentials mounted. IAM, model access and region mistakes show up on your laptop instead of as a task that never turns healthy.

## The build project

**`projects/12-aws-deploy/`** deploys module 07's RAG service to ECS Fargate, with Bedrock for both chat and embeddings, an index baked into the image, Terraform for the infrastructure, and a deploy script. It changes two earlier projects, on purpose ([ADR-001](adr/001-backend-contract.md)): module 04's library gains the `bedrock` backend, and module 07 gains a third vector store, `baked`. Extending shared code is the realistic lesson.

Both languages expose module 07's contract unchanged: `GET /health` → `{"status": "ok"}`, `POST /ask` with `{"question", "k"}` → `{"answer", "citations": [{"tag", "source", "chunk_id"}]}`. Both listen on 8000 in the container and read the same env vars, so **one task definition, one target group and one deploy script serve either image**. Only the folder the image is built from changes.

### What gets deployed, and the embedding decision

Module 07 keeps its vectors in Chroma, a second container. On Fargate that would mean a sidecar or a second service, plus storage. Instead, the image build **embeds the corpus once and writes the vectors to a file**, and the service loads that file into module 07's in-memory index at startup (`VECTOR_STORE=baked`). Only the *question* is embedded at runtime. One container, no database, nothing billing while idle except the task itself.

The rule from module 07 still holds: **the index and the questions must be embedded by the same model.** So which model, given a 512 CPU / 1024 MB task?

| Option | Fits the task? | Verdict |
|---|---|---|
| `sentence-transformers` in the image (07's Python default) | Python: CPU PyTorch plus MiniLM is several hundred MB of RAM and a ~1.5 GB image. C# has no in-process MiniLM: module 07's C# embeds through Ollama. | Tight in Python, not possible in C# without an ONNX port |
| An Ollama sidecar for embeddings | A second container and a model in a 1 GB task | No |
| **Titan Text Embeddings V2 on Bedrock** for the index *and* the questions | An HTTPS call; the corpus costs fractions of a cent to embed | **Yes** |

So the index is built with Titan (`EMBED_BACKEND=bedrock`, `BEDROCK_EMBED_MODEL_ID=amazon.titan-embed-text-v2:0`) on your machine with your profile, and the deployed task embeds each question with the same model through its task role. Titan returns the same vectors whichever language calls it, so either language's builder produces an index either image can load. The index file records which model made it, and the service refuses to start if its `EMBED_BACKEND` names a different one. A MiniLM index queried with Titan vectors wouldn't fail; it would return confident nonsense, so the check is not optional.

Without PyTorch the images are small: about 350 MB for Python (`python:3.12-slim` plus FastAPI, NumPy, boto3 and the Chroma client) and about 260 MB for C# (`aspnet:10.0` plus the app), with memory use far below 1 GB. For offline runs, the same build step bakes a `hashing` index instead, and the container runs with no AWS at all.

**Security, in the same step as the deploy.** `/ask` spends money on every call and has no authentication, so the ALB's security group admits **only your IP** (`allowed_cidr`). That's the minimum for pretend production. Module [13](13-cost-scaling-and-security.md) adds per-client rate limiting, a token budget and, in AWS, WAF in front of the ALB; real production adds TLS (an ACM certificate on an HTTPS listener) and authentication (Cognito or OIDC on the ALB).

**Cost.** Each deployed stack has its own ALB and Fargate task, and both bill by the hour even when idle: roughly $1.50 a day per stack in `us-east-1` at the time of writing (step 7 itemizes it). Deploy one language, verify it, tear it down, then deploy the other.

### Layout

```
projects/
├── 04-llm-client/                       # module 04, extended in step 1
│   ├── python/
│   │   ├── pyproject.toml               # + the optional [bedrock] extra (boto3)
│   │   ├── src/llm_client/
│   │   │   ├── bedrock.py               # NEW: BedrockClient, Converse
│   │   │   └── factory.py               # + LLM_BACKEND=bedrock
│   │   └── tests/test_bedrock.py        # NEW: botocore Stubber
│   └── csharp/
│       ├── src/LlmClient/
│       │   ├── LlmClient.csproj         # + AWSSDK.Extensions.Bedrock.MEAI, AWSSDK.SSO, AWSSDK.SSOOIDC
│       │   └── ServiceCollectionExtensions.cs   # + "bedrock"
│       └── tests/LlmClient.Tests/BedrockTests.cs   # NEW: a fake runtime
├── 07-rag-service/                      # module 07, extended in step 2
│   ├── python/
│   │   ├── app/
│   │   │   ├── config.py                # + INDEX_PATH, BEDROCK_EMBED_MODEL_ID, AWS_REGION
│   │   │   ├── embeddings.py            # + BedrockEmbedder (Titan), embedder_id()
│   │   │   ├── store.py                 # + VECTOR_STORE=baked, InMemoryIndex.rows()
│   │   │   ├── baked.py                 # NEW: save_index / load_index
│   │   │   └── build_index.py           # NEW: the build-time embedding step
│   │   └── tests/test_baked.py          # NEW
│   └── csharp/
│       ├── src/RagService/
│       │   ├── RagOptions.cs            # + the same settings, EmbedderId
│       │   ├── VectorIndex.cs           # + InMemoryVectorIndex.Rows()
│       │   ├── BakedIndex.cs            # NEW: SaveAsync / LoadAsync
│       │   └── Program.cs               # + bedrock embeddings, baked store, build-index
│       └── tests/RagService.Tests/BakedIndexTests.cs   # NEW
└── 12-aws-deploy/                       # new: packaging, infrastructure, deploy
    ├── NOTES.md                         # what bit you, latency, image sizes
    ├── index/
    │   └── rag-index.json               # generated by build_index; don't commit it
    ├── python/
    │   ├── Dockerfile                   # build context: projects/
    │   ├── Dockerfile.dockerignore
    │   ├── compose.yaml
    │   └── .env.example
    ├── csharp/
    │   ├── Dockerfile                   # build context: projects/
    │   ├── Dockerfile.dockerignore
    │   └── compose.yaml
    ├── infra/                           # Terraform, shared by both languages (one workspace each)
    │   ├── main.tf                      # ECR, IAM, ECS
    │   ├── network.tf                   # default VPC, security groups, ALB
    │   ├── alarms.tf                    # Bedrock token alarm
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── terraform.tfvars.example     # copy to terraform.tfvars (git-ignored)
    ├── infra-cdk/                       # optional: the same stack in CDK C#
    │   ├── cdk.json                     # from `cdk init`
    │   └── src/InfraCdk/
    │       ├── InfraCdk.csproj
    │       ├── AwsDeployStack.cs
    │       └── Program.cs
    └── deploy/
        ├── budget.json                  # step 0
        ├── budget-notifications.json
        └── deploy.ps1                   # bake → build → push → roll
```

`.gitignore` already ignores `.terraform/`, `*.tfvars` (but not `*.tfvars.example`) and `cdk.out/`. Add `projects/12-aws-deploy/index/` to it: the index is a build artifact, and its embedding model is a deploy-time choice.

### Step 0: the budget, before anything else

Bedrock bills per token, so a loop bug or a leaked endpoint runs up a bill silently: there's no crash to stop it. Create a monthly budget with email alerts now, before any other resource. It lives outside the Terraform stack on purpose, so `terraform destroy` never removes it.

`deploy/budget.json` and `deploy/budget-notifications.json` (put your address in the second file):

```json
{
  "BudgetName": "ai-learn-monthly",
  "BudgetLimit": { "Amount": "20", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
```

```json
[
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 50, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "you@example.com" }]
  },
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "you@example.com" }]
  },
  {
    "Notification": { "NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN", "Threshold": 100, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "you@example.com" }]
  }
]
```

From `projects/12-aws-deploy`:

```powershell
$account = aws sts get-caller-identity --profile ai-learn --query Account --output text
aws budgets create-budget --profile ai-learn --account-id $account `
    --budget file://deploy/budget.json --notifications-with-subscribers file://deploy/budget-notifications.json
```

A budget is a slow smoke detector. Billing data reaches it a few times a day, so an alert can arrive many hours after the spending started. That's why the stack also gets a **CloudWatch alarm on Bedrock's own token metric** (step 5), which reacts in minutes. Turn on **Cost Anomaly Detection** in the Billing console too; it's free and catches patterns a fixed threshold misses.

### Step 1: add `bedrock` to module 04's library

Every service built on module 04 gets Bedrock from this one change, in both languages. Same rules as the other paid backend, `hosted`: `BEDROCK_MODEL_ID` and `AWS_REGION` are required, and so are the `Rates__*` prices, because a cost log that says $0 for a paid model is wrong. An unknown `LLM_BACKEND` still fails loudly, and the error now lists four values.

#### Python

boto3 is an *optional* extra: a project that never uses Bedrock doesn't install it. The tests need it, so it's in the dev group too. From `projects/04-llm-client/python`:

```powershell
uv add --optional bedrock boto3
uv add --dev boto3
```

`BedrockClient` implements the same `LlmClient` protocol as the others. Converse takes the system prompt separately from the turns, so `_request` splits them. boto3 is synchronous, so each call runs on a worker thread, and there's no `with_backoff`: botocore already retries throttling and 5xx with its own retry mode, and a second layer would multiply the attempts.

```python
# src/llm_client/bedrock.py
import asyncio
import time
from collections.abc import AsyncIterator, Sequence
from typing import Any

import boto3

from .costs import Rates, cost_usd, log_call
from .types import Completion, Message, Usage

# Converse's stopReason, in the OpenAI-style words the other backends log.
FINISH = {
    "end_turn": "stop",
    "stop_sequence": "stop",
    "max_tokens": "length",
    "tool_use": "tool_calls",
    "guardrail_intervened": "content_filter",
    "content_filtered": "content_filter",
}


class BedrockClient:
    """Amazon Bedrock through the Converse API: one request shape for every model family.

    No API key. boto3's default credential chain finds the ECS task role in AWS, or your
    AWS_PROFILE locally. boto3 is synchronous, so each call runs on a worker thread.
    There's no with_backoff here: botocore already retries throttling and 5xx with its
    own retry mode, and a second layer would multiply the attempts (and the bill).
    """

    def __init__(
        self, model_id: str, region: str, rates: Rates, *,
        temperature: float | None = None, client: Any = None,
    ):
        # model_id is a model ID or an inference-profile ID (us.amazon.nova-micro-v1:0).
        self._client = client or boto3.client("bedrock-runtime", region_name=region)
        self._model = model_id
        self._rates = rates
        self._temperature = temperature   # None: the model's default

    def _request(self, messages: Sequence[Message], max_tokens: int) -> dict[str, Any]:
        # Converse takes the system prompt separately; the turns must be user/assistant.
        system = [{"text": m.content} for m in messages if m.role == "system"]
        turns: list[dict[str, Any]] = []
        for m in messages:
            if m.role == "system":
                continue
            if m.role not in ("user", "assistant"):
                raise ValueError(f"BedrockClient can't send a {m.role!r} message as plain text")
            turns.append({"role": m.role, "content": [{"text": m.content}]})
        inference: dict[str, Any] = {"maxTokens": max_tokens}
        if self._temperature is not None:
            inference["temperature"] = self._temperature
        request: dict[str, Any] = {
            "modelId": self._model,
            "messages": turns,
            "inferenceConfig": inference,
        }
        if system:
            request["system"] = system
        return request

    async def complete(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> Completion:
        t0 = time.perf_counter()
        resp = await asyncio.to_thread(self._client.converse, **self._request(messages, max_tokens))
        usage = Usage(resp["usage"]["inputTokens"], resp["usage"]["outputTokens"])
        text = "".join(block.get("text", "") for block in resp["output"]["message"]["content"])
        reason: str = resp["stopReason"]
        finish = FINISH.get(reason, reason)
        cost = cost_usd(usage, self._rates)
        log_call(self._model, usage, cost, (time.perf_counter() - t0) * 1000, finish)
        return Completion(text, usage, model=self._model, finish_reason=finish, cost_usd=cost)

    async def stream(
        self, messages: Sequence[Message], *, max_tokens: int = 512
    ) -> AsyncIterator[str]:
        # Needs bedrock:InvokeModelWithResponseStream in IAM, on top of bedrock:InvokeModel.
        t0 = time.perf_counter()
        resp = await asyncio.to_thread(self._client.converse_stream, **self._request(messages, max_tokens))
        events = iter(resp["stream"])
        usage, finish = Usage(0, 0), "stop"
        # Pull each event on a worker thread too: next() blocks on the network.
        while (event := await asyncio.to_thread(next, events, None)) is not None:
            if "contentBlockDelta" in event:
                if text := event["contentBlockDelta"]["delta"].get("text"):
                    yield text
            elif "messageStop" in event:
                stop: str = event["messageStop"]["stopReason"]
                finish = FINISH.get(stop, stop)
            elif "metadata" in event:   # usage arrives last, as in the OpenAI stream
                u = event["metadata"]["usage"]
                usage = Usage(u["inputTokens"], u["outputTokens"])
        log_call(self._model, usage, cost_usd(usage, self._rates), (time.perf_counter() - t0) * 1000, finish)
```

The factory imports it lazily, so `stub`, `ollama` and `hosted` never need boto3, and gives a clear error when the extra is missing. The `Rates__*` lookup moves into a helper the two paid backends share:

```python
# src/llm_client/factory.py
import os

from .costs import Rates
from .hosted import HostedClient
from .ollama import OllamaClient
from .stub import StubClient
from .types import LlmClient

BACKENDS = ("stub", "ollama", "hosted", "bedrock")


def _rates_from_env() -> Rates:
    # .NET's env-var spelling of Rates:InputPerMTok, so one .env drives both sides.
    # Required for every paid backend: a cost log that says $0 for Bedrock would be wrong.
    return Rates(
        input_per_mtok=float(os.environ["Rates__InputPerMTok"]),
        output_per_mtok=float(os.environ["Rates__OutputPerMTok"]),
    )


def _temperature_from_env() -> float | None:
    """LLM_TEMPERATURE, if set (e.g. 0 for an eval judge). Unset means the server's default."""
    value = os.environ.get("LLM_TEMPERATURE")
    return float(value) if value else None


def client_from_env() -> LlmClient:
    """Pick the backend from LLM_BACKEND (docs/conventions.md#model-backends)."""
    backend = os.environ.get("LLM_BACKEND", "ollama")
    if backend == "stub":
        reply = os.environ.get("LLM_STUB_REPLY")
        return StubClient([reply] if reply else [])
    if backend == "ollama":
        return OllamaClient(
            base_url=os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434"),  # no /v1
            model=os.environ.get("OLLAMA_MODEL", "llama3.2"),
            temperature=_temperature_from_env(),
        )
    if backend == "hosted":
        return HostedClient(
            base_url=os.environ["LLM_BASE_URL"],  # includes /v1
            api_key=os.environ["LLM_API_KEY"],
            model=os.environ["LLM_MODEL"],
            temperature=_temperature_from_env(),
            rates=_rates_from_env(),
        )
    if backend == "bedrock":
        try:
            from .bedrock import BedrockClient   # lazy: boto3 is the optional [bedrock] extra
        except ModuleNotFoundError as e:
            raise RuntimeError('LLM_BACKEND=bedrock needs boto3: install "llm-client[bedrock]"') from e
        return BedrockClient(
            model_id=os.environ["BEDROCK_MODEL_ID"],   # a model ID or an inference-profile ID
            region=os.environ["AWS_REGION"],
            rates=_rates_from_env(),
            temperature=_temperature_from_env(),
        )
    raise ValueError(f"unknown LLM_BACKEND {backend!r} (expected one of: {' | '.join(BACKENDS)})")
```

The tests run against a **real boto3 client** with botocore's `Stubber` attached: no network, but the request is checked against `expected_params`, so the Converse mapping itself is under test. The Stubber can't fake `converse_stream`'s event stream, so the streaming test uses a duck-typed fake. The numbers (12 input tokens, 5 output, $1 and $4 per million) are the same in the C# tests.

```python
# tests/test_bedrock.py
import boto3
import pytest
from botocore.stub import Stubber

from llm_client.bedrock import BedrockClient
from llm_client.costs import Rates
from llm_client.factory import client_from_env
from llm_client.types import Message

MESSAGES = [Message("system", "You are terse."), Message("user", "Name three colors.")]
MODEL = "us.amazon.nova-micro-v1:0"


def stubbed() -> tuple[BedrockClient, Stubber]:
    # A real boto3 client with fake credentials; the Stubber answers instead of AWS, and it
    # checks the request against expected_params, so the Converse mapping is under test.
    raw = boto3.client(
        "bedrock-runtime", region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
    )
    return BedrockClient(MODEL, "us-east-1", Rates(1.0, 4.0), client=raw), Stubber(raw)


@pytest.mark.asyncio
async def test_complete_maps_messages_to_converse_and_reads_usage():
    client, stub = stubbed()
    stub.add_response(
        "converse",
        {
            "output": {"message": {"role": "assistant", "content": [{"text": "Red, green, blue."}]}},
            "stopReason": "end_turn",
            "usage": {"inputTokens": 12, "outputTokens": 5, "totalTokens": 17},
            "metrics": {"latencyMs": 120},
        },
        expected_params={
            "modelId": MODEL,
            "system": [{"text": "You are terse."}],
            "messages": [{"role": "user", "content": [{"text": "Name three colors."}]}],
            "inferenceConfig": {"maxTokens": 64},
        },
    )
    with stub:
        result = await client.complete(MESSAGES, max_tokens=64)
    stub.assert_no_pending_responses()
    assert result.text == "Red, green, blue."
    assert (result.usage.prompt_tokens, result.usage.completion_tokens) == (12, 5)
    assert result.finish_reason == "stop"
    assert result.cost_usd == pytest.approx(12 / 1e6 * 1.0 + 5 / 1e6 * 4.0)



@pytest.mark.asyncio
async def test_temperature_goes_into_inference_config():
    raw = boto3.client(
        "bedrock-runtime", region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
    )
    client, stub = BedrockClient(MODEL, "us-east-1", Rates(1.0, 4.0), temperature=0.0, client=raw), Stubber(raw)
    stub.add_response(
        "converse",
        {
            "output": {"message": {"role": "assistant", "content": [{"text": "ok"}]}},
            "stopReason": "end_turn",
            "usage": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
            "metrics": {"latencyMs": 1},
        },
        expected_params={
            "modelId": MODEL,
            "system": [{"text": "You are terse."}],
            "messages": [{"role": "user", "content": [{"text": "Name three colors."}]}],
            "inferenceConfig": {"maxTokens": 64, "temperature": 0.0},
        },
    )
    with stub:
        await client.complete(MESSAGES, max_tokens=64)
    stub.assert_no_pending_responses()


@pytest.mark.asyncio
async def test_max_tokens_stop_reason_is_reported_as_length():
    client, stub = stubbed()
    stub.add_response("converse", {
        "output": {"message": {"role": "assistant", "content": [{"text": "Red,"}]}},
        "stopReason": "max_tokens",
        "usage": {"inputTokens": 12, "outputTokens": 1, "totalTokens": 13},
        "metrics": {"latencyMs": 50},
    })
    with stub:
        assert (await client.complete(MESSAGES, max_tokens=1)).finish_reason == "length"


@pytest.mark.asyncio
async def test_access_denied_surfaces_as_a_client_error():
    client, stub = stubbed()
    stub.add_client_error("converse", "AccessDeniedException", "not authorized to invoke this model")
    with stub, pytest.raises(Exception, match="AccessDeniedException"):
        await client.complete(MESSAGES)


class FakeStreamingRuntime:
    """converse_stream returns an event stream, which Stubber can't fake. A duck-typed client can."""

    def converse_stream(self, **request):
        self.request = request
        return {"stream": [
            {"messageStart": {"role": "assistant"}},
            {"contentBlockDelta": {"delta": {"text": "Red,"}, "contentBlockIndex": 0}},
            {"contentBlockDelta": {"delta": {"text": " green"}, "contentBlockIndex": 0}},
            {"messageStop": {"stopReason": "end_turn"}},
            {"metadata": {"usage": {"inputTokens": 12, "outputTokens": 2, "totalTokens": 14}}},
        ]}


@pytest.mark.asyncio
async def test_stream_yields_text_deltas():
    fake = FakeStreamingRuntime()
    client = BedrockClient(MODEL, "us-east-1", Rates(1.0, 4.0), client=fake)
    assert [c async for c in client.stream(MESSAGES)] == ["Red,", " green"]
    assert fake.request["system"] == [{"text": "You are terse."}]


def test_factory_builds_bedrock_from_env(monkeypatch, tmp_path):
    # boto3 resolves credentials when it builds a client. Fake keys in the environment win the
    # default chain, and empty config files keep your own ~/.aws profile out of the test.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.setenv("AWS_CONFIG_FILE", str(tmp_path / "config"))
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", str(tmp_path / "credentials"))
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    monkeypatch.setenv("LLM_BACKEND", "bedrock")
    monkeypatch.setenv("BEDROCK_MODEL_ID", MODEL)
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("Rates__InputPerMTok", "0.035")
    monkeypatch.setenv("Rates__OutputPerMTok", "0.14")
    assert isinstance(client_from_env(), BedrockClient)   # building the client makes no AWS call


def test_factory_requires_a_model_id_for_bedrock(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "bedrock")
    monkeypatch.delenv("BEDROCK_MODEL_ID", raising=False)
    with pytest.raises(KeyError, match="BEDROCK_MODEL_ID"):
        client_from_env()
```

```powershell
uv run pytest    # 22 passed: module 04's 16 plus these 6
```

`test_factory_builds_bedrock_from_env` points boto3 at empty config files because boto3 resolves credentials when it *builds* a client. Without that, the test would read your own `~/.aws` profile, and a profile that uses SSO or `aws login` fails there unless `botocore[crt]` is installed (see step 4).

#### C#

From `projects/04-llm-client/csharp`:

```powershell
dotnet add src/LlmClient package AWSSDK.Extensions.Bedrock.MEAI
dotnet add src/LlmClient package AWSSDK.SSO        # only needed for SSO profiles; the SDK loads them by name
dotnet add src/LlmClient package AWSSDK.SSOOIDC
```

`AWSSDK.Extensions.Bedrock.MEAI` turns an `IAmazonBedrockRuntime` into an `IChatClient` with `AsIChatClient(modelId)`, so the rest of the pipeline (cost logging included) doesn't change. The Bedrock branch reads its settings **at registration**, so a task without its model ID dies at startup instead of on the first request: on ECS, that's a task that never turns healthy, with the reason in the logs. It also uses an `IAmazonBedrockRuntime` from DI when one is registered, which is how the tests swap in a fake and how module 07 shares one client between chat and embeddings.

```csharp
// src/LlmClient/ServiceCollectionExtensions.cs
using System.ClientModel;
using System.ClientModel.Primitives;
using System.Globalization;
using Amazon;
using Amazon.BedrockRuntime;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OllamaSharp;
using OpenAI;

namespace LlmClient;

public static class ServiceCollectionExtensions
{
    public static readonly string[] Backends = ["stub", "ollama", "hosted", "bedrock"];

    /// <summary>
    /// Registers IChatClient for the backend named by LLM_BACKEND (docs/conventions.md#model-backends),
    /// wrapped in cost logging. App code only ever asks for IChatClient.
    /// </summary>
    public static ChatClientBuilder AddLlmClient(this IServiceCollection services, IConfiguration config)
    {
        string backend = config["LLM_BACKEND"] ?? "ollama";
        if (!Backends.Contains(backend))
            throw new InvalidOperationException(
                $"unknown LLM_BACKEND '{backend}' (expected one of: {string.Join(" | ", Backends)})");

        Rates rates = backend is "stub" or "ollama"
            ? Rates.Free
            : config.GetSection("Rates").Get<Rates>()
              ?? throw new InvalidOperationException("Rates:InputPerMTok and Rates:OutputPerMTok are required");

        float? temperature = config["LLM_TEMPERATURE"] is { Length: > 0 } t
            ? float.Parse(t, CultureInfo.InvariantCulture)
            : null;

        Func<IServiceProvider, IChatClient> create;
        if (backend == "bedrock")
        {
            // Read now, so a task without its model ID fails at startup, not on the first request.
            string modelId = Required(config, "BEDROCK_MODEL_ID");   // a model ID or an inference-profile ID
            RegionEndpoint region = RegionEndpoint.GetBySystemName(Required(config, "AWS_REGION"));
            // No key: the SDK's default credential chain finds the ECS task role in AWS, or AWS_PROFILE locally.
            // The SDK retries throttling and 5xx itself, so the "llm" resilience handler isn't on this path.
            create = sp => (sp.GetService<IAmazonBedrockRuntime>()   // tests register a fake runtime
                            ?? new AmazonBedrockRuntimeClient(region))
                .AsIChatClient(modelId);
        }
        else
        {
            services.AddHttpClient("llm", c => c.Timeout = Timeout.InfiniteTimeSpan) // the resilience handler owns timeouts
                .AddStandardResilienceHandler(LlmResilience.Configure);
            create = sp => CreateBackend(backend, config, sp.GetRequiredService<IHttpClientFactory>().CreateClient("llm"));
        }

        return services
            .AddChatClient(create)
            .Use((inner, sp) => new CostLoggingChatClient(
                inner, rates, sp.GetRequiredService<ILogger<CostLoggingChatClient>>()))
            // LLM_TEMPERATURE, if set (e.g. 0 for an eval judge), is every call's default; a call that sets its own wins.
            .ConfigureOptions(o => o.Temperature ??= temperature);
    }

    private static IChatClient CreateBackend(string backend, IConfiguration config, HttpClient http)
    {
        switch (backend)
        {
            case "stub":
                // An empty value means "not set", as in Python: .env files often carry LLM_STUB_REPLY= blank.
                return new StubChatClient(config["LLM_STUB_REPLY"] is { Length: > 0 } reply ? [reply] : null);

            case "ollama":
                // OLLAMA_BASE_URL is the server root; OllamaSharp calls the native /api/chat under it.
                http.BaseAddress = new Uri(config["OLLAMA_BASE_URL"] ?? "http://localhost:11434");
                return new OllamaApiClient(http, config["OLLAMA_MODEL"] ?? "llama3.2");

            default: // "hosted"
                // Any OpenAI-compatible endpoint; LLM_BASE_URL includes /v1. Route it through our HttpClient
                // and turn the SDK's own retries off, so attempts don't multiply (SDK retries x handler retries).
                var options = new OpenAIClientOptions
                {
                    Endpoint = new Uri(Required(config, "LLM_BASE_URL")),
                    Transport = new HttpClientPipelineTransport(http),
                    RetryPolicy = new ClientRetryPolicy(maxRetries: 0),
                };
                return new OpenAIClient(new ApiKeyCredential(Required(config, "LLM_API_KEY")), options)
                    .GetChatClient(Required(config, "LLM_MODEL"))
                    .AsIChatClient();
        }
    }

    private static string Required(IConfiguration config, string key) =>
        config[key] is { Length: > 0 } value ? value : throw new InvalidOperationException($"missing config value '{key}'");
}
```

`Required` now treats an empty value as missing, which matters once values come from env vars that can be set but blank.

The SDK's client methods are `virtual`, so the fake is a real `AmazonBedrockRuntimeClient` (anonymous credentials, never used) with `ConverseAsync` overridden. The MEAI adapter above it runs for real:

```csharp
// tests/LlmClient.Tests/BedrockTests.cs
using Amazon;
using Amazon.BedrockRuntime;
using Amazon.BedrockRuntime.Model;
using Amazon.Runtime;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using NUnit.Framework;

namespace LlmClient.Tests;

/// <summary>
/// A real AmazonBedrockRuntimeClient with ConverseAsync overridden: the SDK's client methods are virtual,
/// so this fakes one call without implementing the whole IAmazonBedrockRuntime interface. The MEAI
/// adapter above it runs for real, so the ChatMessage-to-Converse mapping is what's under test.
/// </summary>
public sealed class FakeBedrockRuntime(ConverseResponse response)
    : AmazonBedrockRuntimeClient(new AnonymousAWSCredentials(), RegionEndpoint.USEast1)
{
    public List<ConverseRequest> Requests { get; } = [];

    public override Task<ConverseResponse> ConverseAsync(ConverseRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        return Task.FromResult(response);
    }
}

/// <summary>The test_bedrock.py twin: same messages, same numbers.</summary>
public class BedrockTests
{
    private const string Model = "us.amazon.nova-micro-v1:0";

    private static readonly ChatMessage[] Messages =
        [new(ChatRole.System, "You are terse."), new(ChatRole.User, "Name three colors.")];

    private static ConverseResponse Reply(string text, StopReason stop, int input, int output) => new()
    {
        Output = new ConverseOutput
        {
            Message = new Message { Role = ConversationRole.Assistant, Content = [new ContentBlock { Text = text }] },
        },
        StopReason = stop,
        Usage = new TokenUsage { InputTokens = input, OutputTokens = output, TotalTokens = input + output },
    };

    private static IServiceCollection Services(FakeBedrockRuntime? fake, params (string Key, string Value)[] overrides)
    {
        var settings = new Dictionary<string, string?>
        {
            ["LLM_BACKEND"] = "bedrock", ["BEDROCK_MODEL_ID"] = Model, ["AWS_REGION"] = "us-east-1",
            ["Rates:InputPerMTok"] = "1.0", ["Rates:OutputPerMTok"] = "4.0",
        };
        foreach (var (key, value) in overrides) settings[key] = value;
        IConfiguration config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        var services = new ServiceCollection().AddLogging();
        if (fake is not null) services.AddSingleton<IAmazonBedrockRuntime>(fake);
        services.AddLlmClient(config);
        return services;
    }

    [Test]
    public async Task Maps_messages_to_Converse_and_reads_usage()
    {
        var fake = new FakeBedrockRuntime(Reply("Red, green, blue.", StopReason.End_turn, 12, 5));
        IChatClient chat = Services(fake).BuildServiceProvider().GetRequiredService<IChatClient>();

        ChatResponse result = await chat.GetResponseAsync(Messages, new ChatOptions { MaxOutputTokens = 64 });

        ConverseRequest sent = fake.Requests.Single();
        Assert.That(sent.ModelId, Is.EqualTo(Model));
        Assert.That(sent.System.Single().Text, Is.EqualTo("You are terse."));
        Assert.That(sent.Messages.Single().Role, Is.EqualTo(ConversationRole.User));
        Assert.That(sent.Messages.Single().Content.Single().Text, Is.EqualTo("Name three colors."));
        Assert.That(sent.InferenceConfig.MaxTokens, Is.EqualTo(64));

        Assert.That(result.Text, Is.EqualTo("Red, green, blue."));
        Assert.That(result.Usage?.InputTokenCount, Is.EqualTo(12));
        Assert.That(result.Usage?.OutputTokenCount, Is.EqualTo(5));
        Assert.That(result.FinishReason, Is.EqualTo(ChatFinishReason.Stop));
        Assert.That(result.AdditionalProperties?[CostLoggingChatClient.CostKey], Is.EqualTo(12 / 1e6m * 1.0m + 5 / 1e6m * 4.0m));
    }

    [Test]
    public async Task Max_tokens_stop_reason_is_reported_as_length()
    {
        var fake = new FakeBedrockRuntime(Reply("Red,", StopReason.Max_tokens, 12, 1));
        IChatClient chat = Services(fake).BuildServiceProvider().GetRequiredService<IChatClient>();
        ChatResponse result = await chat.GetResponseAsync(Messages, new ChatOptions { MaxOutputTokens = 1 });
        Assert.That(result.FinishReason, Is.EqualTo(ChatFinishReason.Length));
    }

    [Test]
    public void Missing_model_id_fails_when_registering_not_on_the_first_call()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => Services(null, ("BEDROCK_MODEL_ID", "")));
        Assert.That(ex!.Message, Does.Contain("BEDROCK_MODEL_ID"));
    }

    [Test]
    public void Bedrock_needs_rates_like_any_paid_backend()
    {
        IConfiguration config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["LLM_BACKEND"] = "bedrock", ["BEDROCK_MODEL_ID"] = Model, ["AWS_REGION"] = "us-east-1",
        }).Build();
        Assert.Throws<InvalidOperationException>(() => new ServiceCollection().AddLlmClient(config));
    }
}
```

```powershell
dotnet test    # 21 passed: module 04's 17 plus these 4
```

If the build fails with `CS8032` or `CS8034` and "An Application Control policy has blocked this file", Windows Smart App Control or a WDAC policy is refusing to load the AWS SDK's Roslyn analyzers (unsigned DLLs inside the NuGet packages). They only lint property assignments. Drop them for local builds with a `Directory.Build.targets` in `projects/` (the Linux Docker build doesn't need it):

```xml
<Project>
  <!-- Windows Application Control blocks the AWS SDK's unsigned Roslyn analyzer DLLs (CS8032 / CS8034).
       The analyzers only lint property assignments; dropping them doesn't change the compiled code. -->
  <Target Name="DropAwsSdkAnalyzers" BeforeTargets="CoreCompile">
    <ItemGroup>
      <Analyzer Remove="@(Analyzer)" Condition="$([System.String]::Copy('%(Analyzer.FullPath)').Contains('awssdk.'))" />
    </ItemGroup>
  </Target>
</Project>
```

### Step 2: bake the index into module 07

Module 07 gets a third store, `VECTOR_STORE=baked`, and a third embedder, `EMBED_BACKEND=bedrock`. Its contract, its prompt and its tests don't change.

| Setting | Values | Notes |
|---|---|---|
| `VECTOR_STORE` | `chroma`, `memory`, **`baked`** | `baked` needs `INDEX_PATH` |
| `INDEX_PATH` | a file path | the file the build step wrote |
| `EMBED_BACKEND` | Python: `sentence-transformers`, `hashing`, **`bedrock`**. C#: `ollama`, `hashing`, **`bedrock`** | must match the model that baked the index |
| `BEDROCK_EMBED_MODEL_ID` | default `amazon.titan-embed-text-v2:0` | |
| `AWS_REGION` | default `us-east-1` | |

The index file is plain JSON, the same in both languages: a format version, the embedder's name, the dimension count, and every chunk with its vector, ordered by chunk id. The embedder's name is `hashing-256`, `sentence-transformers:<model>`, `ollama:<model>` or `bedrock:<model id>`, computed the same way on both sides, so either language loads the other's file.

#### Python

From `projects/07-rag-service/python`. The Bedrock embedder needs boto3 directly, and if your `ai-learn` profile uses IAM Identity Center (SSO) or `aws login`, botocore also needs its CRT extra to read those credentials:

```powershell
uv add boto3
uv add "botocore[crt]"   # only for SSO / aws login profiles
```

Three settings join `Settings`:

```python
# app/config.py
from pathlib import Path

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Each field reads the environment variable of the same name, case-insensitively
    (VECTOR_STORE, CHROMA_URL, ...). The model backend isn't here: LLM_BACKEND and
    OLLAMA_* belong to module 04's client_from_env()."""

    vector_store: str = "chroma"                     # chroma | memory | baked
    chroma_url: str = "http://localhost:8003"        # where compose.yaml publishes Chroma
    chroma_collection: str = "docs"
    index_path: Path | None = None                   # VECTOR_STORE=baked: the file build_index wrote
    embed_backend: str = "sentence-transformers"     # sentence-transformers | hashing | bedrock
    embed_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    bedrock_embed_model_id: str = "amazon.titan-embed-text-v2:0"
    aws_region: str = "us-east-1"
    # The shared corpus and labeled set: ../fixtures from python/; the Dockerfile sets the container path.
    fixtures_dir: Path = Path("../fixtures")
```

`BedrockEmbedder` calls Titan through `InvokeModel`, one text per request (Titan has no batch call), sending just `inputText` so Titan's defaults apply (1024 dimensions, normalized). `embedder_id()` names the model for the index file:

```python
# app/embeddings.py
from __future__ import annotations

import json
import re
from collections.abc import Sequence
from typing import TYPE_CHECKING, Any, Protocol

from app.config import Settings

if TYPE_CHECKING:
    from sentence_transformers import SentenceTransformer

EMBED_BACKENDS = ("sentence-transformers", "hashing", "bedrock")


class Embedder(Protocol):
    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...


class SentenceTransformerEmbedder:
    """EMBED_BACKEND=sentence-transformers: a real embedding model, in-process on CPU.
    Loaded on first use, because importing torch and loading the model takes seconds."""

    def __init__(self, model_name: str) -> None:
        self._name = model_name
        self._model: SentenceTransformer | None = None

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(self._name)   # downloads once, into the HF cache
        return self._model.encode(list(texts), convert_to_numpy=True).tolist()


class HashingEmbedder:
    """EMBED_BACKEND=hashing: each word is hashed into one of `dimensions` buckets.
    Lexical, not semantic, but deterministic, offline and instant: what the tests and
    the stub cross-check use. FNV-1a, not hash(), which Python salts per process."""

    def __init__(self, dimensions: int = 256) -> None:
        self._dims = dimensions

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [self._one(t) for t in texts]

    def _one(self, text: str) -> list[float]:
        v = [0.0] * self._dims
        for word in re.findall(r"[a-z0-9]+", text.lower()):
            v[fnv1a(word) % self._dims] += 1.0
        return v


class BedrockEmbedder:
    """EMBED_BACKEND=bedrock: Amazon Titan Text Embeddings through bedrock-runtime InvokeModel.
    Credentials come from boto3's default chain: the task role on ECS, AWS_PROFILE locally.
    Titan embeds one text per request, so a batch is a loop."""

    def __init__(self, model_id: str, region: str, client: Any = None) -> None:
        if client is None:
            import boto3   # only this backend needs it

            client = boto3.client("bedrock-runtime", region_name=region)
        self._client = client
        self._model = model_id

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        vectors = []
        for text in texts:
            resp = self._client.invoke_model(
                modelId=self._model,
                body=json.dumps({"inputText": text}),   # Titan v2 defaults: 1024 dimensions, normalized
                contentType="application/json",
                accept="application/json",
            )
            vectors.append(json.loads(resp["body"].read())["embedding"])
        return vectors


def fnv1a(word: str) -> int:
    """32-bit FNV-1a over the UTF-8 bytes: the same number in every process, and in C#."""
    h = 0x811C9DC5
    for b in word.encode("utf-8"):
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def embedder_from_env(settings: Settings) -> Embedder:
    """Pick the embedder from EMBED_BACKEND. Index and query must use the same one."""
    if settings.embed_backend == "sentence-transformers":
        return SentenceTransformerEmbedder(settings.embed_model)
    if settings.embed_backend == "hashing":
        return HashingEmbedder()
    if settings.embed_backend == "bedrock":
        return BedrockEmbedder(settings.bedrock_embed_model_id, settings.aws_region)
    raise ValueError(
        f"unknown EMBED_BACKEND {settings.embed_backend!r} (expected one of: {' | '.join(EMBED_BACKENDS)})"
    )


def embedder_id(settings: Settings) -> str:
    """Names the embedding model, so a baked index can refuse a service that embeds questions
    with a different one. C#'s RagOptions.EmbedderId gives the same string for the same model."""
    return {
        "hashing": "hashing-256",
        "sentence-transformers": f"sentence-transformers:{settings.embed_model}",
        "bedrock": f"bedrock:{settings.bedrock_embed_model_id}",
    }.get(settings.embed_backend, settings.embed_backend)
```

In `app/store.py`, add `baked` to the list, give `InMemoryIndex` a way to list its rows, and load the file in `index_from_env`. The import is inside the branch, because `baked.py` imports `store.py`:

```python
# app/store.py: the list of stores
VECTOR_STORES = ("chroma", "memory", "baked")
```

```python
# app/store.py: InMemoryIndex, a new method
    def rows(self) -> list[tuple[Chunk, list[float]]]:
        """Every chunk with its vector, ordered by id: what a baked index file holds."""
        return [(c, v.tolist()) for c, v in sorted(self._rows.values(), key=lambda r: r[0].id)]
```

```python
# app/store.py: index_from_env, a new branch
    if settings.vector_store == "baked":
        from app.baked import load_index        # module 12: the corpus embedded at image build time
        from app.embeddings import embedder_id

        if settings.index_path is None:
            raise ValueError("VECTOR_STORE=baked needs INDEX_PATH: the file app.build_index wrote")
        return load_index(settings.index_path, embedder_id(settings))
```

The file format and the model check:

```python
# app/baked.py
"""VECTOR_STORE=baked: the corpus is embedded once, when the image is built, and loaded
into the in-memory index at startup. Only the question is embedded at runtime."""
from __future__ import annotations

import json
from pathlib import Path

from app.store import Chunk, InMemoryIndex

FORMAT = 1   # bump it if the file layout changes; the loader refuses versions it doesn't know


def save_index(path: Path, index: InMemoryIndex, embedder: str) -> int:
    """Write every chunk and its vector, plus the name of the model that made the vectors."""
    rows = index.rows()
    doc = {
        "format": FORMAT,
        "embedder": embedder,
        "dimensions": len(rows[0][1]) if rows else 0,
        "chunks": [{"id": c.id, "source": c.source, "text": c.text, "vector": v} for c, v in rows],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc), encoding="utf-8")
    return len(rows)


def load_index(path: Path, embedder: str) -> InMemoryIndex:
    """Load a baked file, refusing one made by a different embedding model: vectors from two
    models live in different spaces, so mixed retrieval returns confident nonsense."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    if doc.get("format") != FORMAT:
        raise ValueError(f"{path}: index format {doc.get('format')!r}, expected {FORMAT}")
    if doc["embedder"] != embedder:
        raise ValueError(
            f"{path} was embedded with {doc['embedder']!r}, but this service embeds questions with "
            f"{embedder!r}. Rebuild the index, or set EMBED_BACKEND to match it."
        )
    index = InMemoryIndex()
    rows = doc["chunks"]
    index.upsert([Chunk(r["id"], r["text"], r["source"]) for r in rows], [r["vector"] for r in rows])
    return index
```

The build step reuses `ingest_folder`, so the baked chunks are byte-for-byte the ones `/ingest` would make:

```python
# app/build_index.py
"""Embed the corpus and write the file VECTOR_STORE=baked loads. Runs before `docker build`:

    uv run python -m app.build_index --out ../../12-aws-deploy/index/rag-index.json

EMBED_BACKEND picks the model, and the deployed service must embed questions with the same one."""
from __future__ import annotations

import argparse
from pathlib import Path

from app.baked import save_index
from app.config import Settings
from app.embeddings import embedder_from_env, embedder_id
from app.ingest import ingest_folder
from app.store import InMemoryIndex


def main() -> None:
    parser = argparse.ArgumentParser(description="Embed the corpus into a baked index file.")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    settings = Settings()
    index = InMemoryIndex()
    ingest_folder(settings.fixtures_dir / "corpus", embedder_from_env(settings), index)
    count = save_index(args.out, index, embedder_id(settings))
    print(f"baked {count} chunks into {args.out} ({embedder_id(settings)})")


if __name__ == "__main__":
    main()
```

Tests, on hashing, so they're offline: a round trip retrieves like the original, `/ask` answers from a baked file with no `/ingest`, a mismatched model or a missing `INDEX_PATH` stops startup, and the Titan request body is pinned with the Stubber.

```python
# tests/test_baked.py
import io
import json
import sys

import boto3
import pytest
from botocore.response import StreamingBody
from botocore.stub import Stubber
from fastapi.testclient import TestClient

from app import build_index
from app.baked import load_index, save_index
from app.embeddings import BedrockEmbedder, HashingEmbedder
from app.ingest import ingest_folder
from app.retriever import retrieve
from app.store import InMemoryIndex


@pytest.fixture
def baked_file(tmp_path, fixtures_dir):
    index = InMemoryIndex()
    ingest_folder(fixtures_dir / "corpus", HashingEmbedder(), index)
    path = tmp_path / "rag-index.json"
    assert save_index(path, index, "hashing-256") == 3
    return path


def test_a_loaded_index_retrieves_like_the_one_it_was_saved_from(baked_file):
    loaded = load_index(baked_file, "hashing-256")
    hits = retrieve("How do I roll back a deploy?", 3, HashingEmbedder(), loaded)
    assert [h.id for h in hits] == ["oncall.md#0", "oncall.md#1", "billing.md#0"]   # as test_retrieval.py


def test_the_file_is_ordered_by_chunk_id_and_names_its_model(baked_file):
    doc = json.loads(baked_file.read_text(encoding="utf-8"))
    assert (doc["format"], doc["embedder"], doc["dimensions"]) == (1, "hashing-256", 256)
    assert [c["id"] for c in doc["chunks"]] == ["billing.md#0", "oncall.md#0", "oncall.md#1"]


def test_load_refuses_an_index_from_a_different_model(baked_file):
    with pytest.raises(ValueError, match="embedded with 'hashing-256'"):
        load_index(baked_file, "bedrock:amazon.titan-embed-text-v2:0")


def test_ask_answers_from_the_baked_index_without_ingest(offline_app, monkeypatch, baked_file):
    monkeypatch.setenv("VECTOR_STORE", "baked")
    monkeypatch.setenv("INDEX_PATH", str(baked_file))
    with TestClient(offline_app) as api:
        body = api.post("/ask", json={"question": "How do I roll back a deploy?", "k": 2}).json()
    assert body["citations"] == [
        {"tag": "S1", "source": "oncall.md", "chunk_id": "oncall.md#0"},
        {"tag": "S2", "source": "oncall.md", "chunk_id": "oncall.md#1"},
    ]


def test_baked_store_without_index_path_fails_at_startup(offline_app, monkeypatch):
    monkeypatch.setenv("VECTOR_STORE", "baked")
    monkeypatch.delenv("INDEX_PATH", raising=False)
    with pytest.raises(ValueError, match="INDEX_PATH"), TestClient(offline_app):
        pass


def test_build_index_cli_writes_the_file(monkeypatch, tmp_path, fixtures_dir):
    out = tmp_path / "index" / "rag-index.json"
    monkeypatch.setenv("EMBED_BACKEND", "hashing")
    monkeypatch.setenv("FIXTURES_DIR", str(fixtures_dir))
    monkeypatch.setattr(sys, "argv", ["build_index", "--out", str(out)])
    build_index.main()
    assert len(json.loads(out.read_text(encoding="utf-8"))["chunks"]) == 3


def test_bedrock_embedder_sends_one_titan_request_per_text():
    raw = boto3.client("bedrock-runtime", region_name="us-east-1",
                       aws_access_key_id="test", aws_secret_access_key="test")
    stub = Stubber(raw)
    for text, vector in [("first", [0.1, 0.2]), ("second", [0.3, 0.4])]:
        payload = json.dumps({"embedding": vector}).encode()
        stub.add_response(
            "invoke_model",
            {"body": StreamingBody(io.BytesIO(payload), len(payload)), "contentType": "application/json"},
            expected_params={
                "modelId": "amazon.titan-embed-text-v2:0",
                "body": json.dumps({"inputText": text}),
                "contentType": "application/json",
                "accept": "application/json",
            },
        )
    with stub:
        vectors = BedrockEmbedder("amazon.titan-embed-text-v2:0", "us-east-1", client=raw).embed(["first", "second"])
    assert vectors == [[0.1, 0.2], [0.3, 0.4]]
```

```powershell
uv run pytest    # 29 passed: module 07's 22 plus these 7
$env:EMBED_BACKEND = 'hashing'; uv run python -m app.build_index --out ../../12-aws-deploy/index/rag-index.json
```

The last line bakes an offline index for step 4: `baked 3 chunks into ..\..\12-aws-deploy\index\rag-index.json (hashing-256)`.

#### C#

The settings, with the same names and the same embedder ids:

```csharp
// src/RagService/RagOptions.cs
using Microsoft.Extensions.Configuration;

namespace RagService;

/// <summary>
/// The service's own settings, read from the same environment variables as the Python Settings class.
/// [ConfigurationKeyName] maps each property to its flat name. The chat model isn't here:
/// LLM_BACKEND and OLLAMA_MODEL belong to module 04's AddLlmClient.
/// </summary>
public sealed class RagOptions
{
    public static readonly string[] VectorStores = ["chroma", "memory", "baked"];
    public static readonly string[] EmbedBackends = ["ollama", "hashing", "bedrock"];

    [ConfigurationKeyName("VECTOR_STORE")]
    public string VectorStore { get; set; } = "chroma";

    [ConfigurationKeyName("CHROMA_URL")]
    public string ChromaUrl { get; set; } = "http://localhost:8002";       // where compose.yaml publishes Chroma

    [ConfigurationKeyName("CHROMA_COLLECTION")]
    public string ChromaCollection { get; set; } = "docs-cs";              // Python's is "docs": see the cross-check

    [ConfigurationKeyName("INDEX_PATH")]
    public string? IndexPath { get; set; }                                 // VECTOR_STORE=baked: the file build-index wrote

    [ConfigurationKeyName("EMBED_BACKEND")]
    public string EmbedBackend { get; set; } = "ollama";

    [ConfigurationKeyName("OLLAMA_BASE_URL")]
    public string OllamaBaseUrl { get; set; } = "http://localhost:11434";  // the server root, no /v1

    [ConfigurationKeyName("OLLAMA_EMBED_MODEL")]
    public string OllamaEmbedModel { get; set; } = "all-minilm";           // all-MiniLM-L6-v2, as in Python

    [ConfigurationKeyName("BEDROCK_EMBED_MODEL_ID")]
    public string BedrockEmbedModelId { get; set; } = "amazon.titan-embed-text-v2:0";

    [ConfigurationKeyName("AWS_REGION")]
    public string AwsRegion { get; set; } = "us-east-1";

    // `dotnet run` starts a web project in its own folder (src/RagService), so the default climbs three levels.
    [ConfigurationKeyName("FIXTURES_DIR")]
    public string FixturesDir { get; set; } = "../../../fixtures";

    /// <summary>/ingest may only read below this folder.</summary>
    public string CorpusRoot => Path.Combine(Path.GetFullPath(FixturesDir), "corpus");

    /// <summary>Names the embedding model; the same string as embedder_id() in Python for the same model.</summary>
    public string EmbedderId => EmbedBackend switch
    {
        "hashing" => "hashing-256",
        "ollama" => $"ollama:{OllamaEmbedModel}",
        "bedrock" => $"bedrock:{BedrockEmbedModelId}",
        _ => EmbedBackend,
    };

    /// <summary>Unknown values fail at startup with the valid list, like LLM_BACKEND.</summary>
    public RagOptions Validate()
    {
        Check("VECTOR_STORE", VectorStore, VectorStores);
        Check("EMBED_BACKEND", EmbedBackend, EmbedBackends);
        if (VectorStore == "baked" && string.IsNullOrEmpty(IndexPath))
            throw new InvalidOperationException("VECTOR_STORE=baked needs INDEX_PATH: the file build-index wrote");
        return this;
    }

    private static void Check(string name, string value, string[] allowed)
    {
        if (!allowed.Contains(value))
            throw new InvalidOperationException(
                $"unknown {name} '{value}' (expected one of: {string.Join(" | ", allowed)})");
    }
}
```

`InMemoryVectorIndex` gets the same `Rows()` as Python's `rows()`:

```csharp
// src/RagService/VectorIndex.cs: InMemoryVectorIndex, a new method
    /// <summary>Every chunk with its vector, ordered by id: what a baked index file holds.</summary>
    public IReadOnlyList<(Chunk Chunk, float[] Vector)> Rows() =>
        [.. _rows.Values.OrderBy(r => r.Chunk.Id, StringComparer.Ordinal)];
```

```csharp
// src/RagService/BakedIndex.cs
using System.Text.Json;

namespace RagService;

/// <summary>
/// VECTOR_STORE=baked, the baked.py twin: the corpus is embedded once, when the image is built,
/// and loaded into the in-memory index at startup. Same file format as Python, so either side
/// can load the other's file.
/// </summary>
public static class BakedIndex
{
    public const int Format = 1;   // bump it if the layout changes; the loader refuses versions it doesn't know

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public sealed record Row(string Id, string Source, string Text, float[] Vector);
    public sealed record IndexFile(int Format, string Embedder, int Dimensions, IReadOnlyList<Row> Chunks);

    /// <summary>Write every chunk and its vector, plus the name of the model that made the vectors.</summary>
    public static async Task<int> SaveAsync(string path, InMemoryVectorIndex index, string embedder, CancellationToken ct = default)
    {
        var rows = index.Rows();
        var file = new IndexFile(Format, embedder, rows.Count > 0 ? rows[0].Vector.Length : 0,
            [.. rows.Select(r => new Row(r.Chunk.Id, r.Chunk.Source, r.Chunk.Text, r.Vector))]);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        await using FileStream stream = File.Create(path);
        await JsonSerializer.SerializeAsync(stream, file, Json, ct);
        return rows.Count;
    }

    /// <summary>Load a baked file, refusing one made by a different embedding model: vectors from two
    /// models live in different spaces, so mixed retrieval returns confident nonsense.</summary>
    public static async Task<InMemoryVectorIndex> LoadAsync(string path, string embedder, CancellationToken ct = default)
    {
        await using FileStream stream = File.OpenRead(path);
        IndexFile file = await JsonSerializer.DeserializeAsync<IndexFile>(stream, Json, ct)
                         ?? throw new InvalidOperationException($"{path} is empty");
        if (file.Format != Format)
            throw new InvalidOperationException($"{path}: index format {file.Format}, expected {Format}");
        if (file.Embedder != embedder)
            throw new InvalidOperationException(
                $"{path} was embedded with '{file.Embedder}', but this service embeds questions with '{embedder}'. " +
                "Rebuild the index, or set EMBED_BACKEND to match it.");

        var index = new InMemoryVectorIndex();
        await index.UpsertAsync(
            [.. file.Chunks.Select(r => new Chunk(r.Id, r.Text, r.Source))],
            [.. file.Chunks.Select(r => new ReadOnlyMemory<float>(r.Vector))],
            ct);
        return index;
    }
}
```

`Program.cs` changes in three places. When embeddings come from Bedrock, it registers one `IAmazonBedrockRuntime`, which module 04's `AddLlmClient` then reuses for chat. `AsIEmbeddingGenerator(modelId)` is the embedding twin of `AsIChatClient`. The baked index loads before the app is built, so a missing or mismatched file stops startup. And `build-index` is a command-line mode of the same program: it builds the services, runs the ingestor into a fresh in-memory index, writes the file and exits without starting Kestrel.

```csharp
// src/RagService/Program.cs
using System.Text.Json;
using Amazon;
using Amazon.BedrockRuntime;
using LlmClient;
using Microsoft.Extensions.AI;
using OllamaSharp;
using RagService;

var builder = WebApplication.CreateBuilder(args);

// Same env-var names as the Python service. Read once, here, because they decide what gets registered.
RagOptions rag = (builder.Configuration.Get<RagOptions>() ?? new()).Validate();
builder.Services.AddSingleton(rag);

// snake_case on the wire, so requests and responses match the Python service field for field.
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);

// One Bedrock client for embeddings and chat: AddLlmClient uses a registered IAmazonBedrockRuntime if there is one.
if (rag.EmbedBackend == "bedrock")
    builder.Services.AddSingleton<IAmazonBedrockRuntime>(
        _ => new AmazonBedrockRuntimeClient(RegionEndpoint.GetBySystemName(rag.AwsRegion)));

// Chat model: module 04's library picks stub | ollama | hosted | bedrock from LLM_BACKEND, with cost logging.
builder.Services.AddLlmClient(builder.Configuration);

// Embeddings: the same model at ingest and query, whatever it is.
builder.Services.AddSingleton<IEmbeddingGenerator<string, Embedding<float>>>(sp => rag.EmbedBackend switch
{
    "hashing" => new HashingEmbeddingGenerator(),
    "bedrock" => sp.GetRequiredService<IAmazonBedrockRuntime>().AsIEmbeddingGenerator(rag.BedrockEmbedModelId),
    _ => new OllamaApiClient(new Uri(rag.OllamaBaseUrl), rag.OllamaEmbedModel),
});

// Store seam.
if (rag.VectorStore == "memory")
    builder.Services.AddSingleton<IVectorIndex, InMemoryVectorIndex>();
else if (rag.VectorStore == "baked")   // loaded now: a missing or mismatched file stops startup
    builder.Services.AddSingleton<IVectorIndex>(await BakedIndex.LoadAsync(rag.IndexPath!, rag.EmbedderId));
else
    builder.Services.AddHttpClient<IVectorIndex, ChromaVectorIndex>(c => c.BaseAddress = new Uri(rag.ChromaUrl));

builder.Services.AddTransient<Ingestor>();
builder.Services.AddTransient<Retriever>();
builder.Services.AddTransient<RagAnswerer>();

var app = builder.Build();

// Module 12's image build step: `dotnet run --project src/RagService -- build-index <file>` embeds the
// corpus with EMBED_BACKEND's model and writes the file VECTOR_STORE=baked loads. No server starts.
if (args is ["build-index", var output])
{
    var index = new InMemoryVectorIndex();
    var ingestor = ActivatorUtilities.CreateInstance<Ingestor>(app.Services, index);
    int count = await ingestor.IngestFolderAsync(rag.CorpusRoot);
    await BakedIndex.SaveAsync(output, index, rag.EmbedderId);
    Console.WriteLine($"baked {count} chunks into {output} ({rag.EmbedderId})");
    return;
}

app.MapGet("/health", () => new { Status = "ok" });

app.MapPost("/ingest", async (Ingestor ingestor, CancellationToken ct, string folder = ".") =>
    ingestor.TryResolve(folder, out string? dir)
        ? Results.Ok(new { ChunksIndexed = await ingestor.IngestFolderAsync(dir, ct) })
        // { "detail": ... }, the same body FastAPI's HTTPException returns.
        : Results.BadRequest(new { Detail = "folder must be an existing directory under the corpus root" }));

app.MapPost("/ask", async (AskRequest req, RagAnswerer answerer, CancellationToken ct) =>
    req.Errors() is { } errors
        ? Results.ValidationProblem(errors, statusCode: StatusCodes.Status422UnprocessableEntity)   // FastAPI's status
        : Results.Ok(await answerer.AnswerAsync(req.Question!, req.K, ct)));

app.Run();
```

The tests mirror Python's. The Titan fake overrides `InvokeModelAsync` and records the request body, which pins the one fact the cross-language index depends on: the C# adapter sends the same `{"inputText": ...}` body as `BedrockEmbedder`.

```csharp
// tests/RagService.Tests/BakedIndexTests.cs
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Amazon;
using Amazon.BedrockRuntime;
using Amazon.BedrockRuntime.Model;
using Amazon.Runtime;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace RagService.Tests;

/// <summary>The test_baked.py twin.</summary>
public class BakedIndexTests
{
    private string _file = null!;

    [SetUp]
    public async Task SetUp()
    {
        var index = new InMemoryVectorIndex();
        var ingestor = new Ingestor(new HashingEmbeddingGenerator(), index,
            new RagOptions { FixturesDir = TestPaths.Fixtures },
            Microsoft.Extensions.Logging.Abstractions.NullLogger<Ingestor>.Instance);
        await ingestor.IngestFolderAsync(Path.Combine(TestPaths.Fixtures, "corpus"));
        _file = Path.Combine(Path.GetTempPath(), $"rag-index-{Guid.NewGuid():N}.json");
        Assert.That(await BakedIndex.SaveAsync(_file, index, "hashing-256"), Is.EqualTo(3));
    }

    [TearDown]
    public void TearDown() => File.Delete(_file);

    [Test]
    public async Task A_loaded_index_retrieves_like_the_one_it_was_saved_from()
    {
        InMemoryVectorIndex loaded = await BakedIndex.LoadAsync(_file, "hashing-256");
        var hits = await new Retriever(new HashingEmbeddingGenerator(), loaded).RetrieveAsync("How do I roll back a deploy?", 3);
        Assert.That(hits.Select(h => h.Id), Is.EqualTo(new[] { "oncall.md#0", "oncall.md#1", "billing.md#0" }));
    }

    [Test]
    public void The_file_is_ordered_by_chunk_id_and_names_its_model()
    {
        using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(_file));
        JsonElement root = doc.RootElement;
        Assert.That(root.GetProperty("format").GetInt32(), Is.EqualTo(1));
        Assert.That(root.GetProperty("embedder").GetString(), Is.EqualTo("hashing-256"));
        Assert.That(root.GetProperty("dimensions").GetInt32(), Is.EqualTo(256));
        Assert.That(root.GetProperty("chunks").EnumerateArray().Select(c => c.GetProperty("id").GetString()),
            Is.EqualTo(new[] { "billing.md#0", "oncall.md#0", "oncall.md#1" }));
    }

    [Test]
    public void Load_refuses_an_index_from_a_different_model()
    {
        var ex = Assert.ThrowsAsync<InvalidOperationException>(() =>
            BakedIndex.LoadAsync(_file, "bedrock:amazon.titan-embed-text-v2:0"));
        Assert.That(ex!.Message, Does.Contain("embedded with 'hashing-256'"));
    }

    private WebApplicationFactory<Program> Baked(string? indexPath) =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(b => b
            .UseSetting("LLM_BACKEND", "stub")
            .UseSetting("EMBED_BACKEND", "hashing")
            .UseSetting("VECTOR_STORE", "baked")
            .UseSetting("INDEX_PATH", indexPath ?? "")
            .UseSetting("FIXTURES_DIR", TestPaths.Fixtures));

    [Test]
    public async Task Ask_answers_from_the_baked_index_without_ingest()
    {
        using WebApplicationFactory<Program> factory = Baked(_file);
        using HttpClient client = factory.CreateClient();
        using HttpResponseMessage ask = await client.PostAsJsonAsync("/ask", new { question = "How do I roll back a deploy?", k = 2 });
        using JsonDocument body = JsonDocument.Parse(await ask.Content.ReadAsStringAsync());
        Assert.That(body.RootElement.GetProperty("citations").GetRawText(), Is.EqualTo(
            """[{"tag":"S1","source":"oncall.md","chunk_id":"oncall.md#0"},{"tag":"S2","source":"oncall.md","chunk_id":"oncall.md#1"}]"""));
    }

    [Test]
    public void Baked_store_without_index_path_fails_at_startup()
    {
        using WebApplicationFactory<Program> factory = Baked(null);
        var ex = Assert.Throws<InvalidOperationException>(() => factory.CreateClient());
        Assert.That(ex!.Message, Does.Contain("INDEX_PATH"));
    }
}

/// <summary>A real AmazonBedrockRuntimeClient with InvokeModelAsync overridden: Titan without AWS.</summary>
public sealed class FakeTitanRuntime() : AmazonBedrockRuntimeClient(new AnonymousAWSCredentials(), RegionEndpoint.USEast1)
{
    public List<(string ModelId, string Body)> Requests { get; } = [];

    public override Task<InvokeModelResponse> InvokeModelAsync(InvokeModelRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add((request.ModelId, new StreamReader(request.Body).ReadToEnd()));
        byte[] reply = Encoding.UTF8.GetBytes("""{"embedding":[0.1,0.2],"inputTextTokenCount":1}""");
        return Task.FromResult(new InvokeModelResponse { Body = new MemoryStream(reply), ContentType = "application/json" });
    }
}

public class BedrockEmbeddingTests
{
    [Test]
    public async Task Bedrock_embedder_sends_one_titan_request_per_text()
    {
        var fake = new FakeTitanRuntime();
        using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(b => b
            .UseSetting("LLM_BACKEND", "stub")
            .UseSetting("EMBED_BACKEND", "bedrock")
            .UseSetting("VECTOR_STORE", "memory")
            .UseSetting("FIXTURES_DIR", TestPaths.Fixtures)
            .ConfigureTestServices(s =>
            {
                s.RemoveAll<IAmazonBedrockRuntime>();
                s.AddSingleton<IAmazonBedrockRuntime>(fake);
            }));
        using HttpClient client = factory.CreateClient();

        using HttpResponseMessage ask = await client.PostAsJsonAsync("/ask", new { question = "first" });

        Assert.That(ask.IsSuccessStatusCode, Is.True);
        Assert.That(fake.Requests.Single().ModelId, Is.EqualTo("amazon.titan-embed-text-v2:0"));
        // Compacted, because the SDK indents it: the same body BedrockEmbedder sends in Python.
        string body = JsonSerializer.Serialize(JsonDocument.Parse(fake.Requests.Single().Body).RootElement);
        Assert.That(body, Is.EqualTo("""{"inputText":"first"}"""));
    }
}
```

```powershell
dotnet test --filter "TestCategory!=Eval"    # 28 passed: module 07's 22 plus these 6
$env:EMBED_BACKEND = 'hashing'
dotnet run --project src/RagService -- build-index "$PWD/../../12-aws-deploy/index/rag-index-cs.json"
```

`dotnet run` starts a web project in its own folder, so pass `build-index` an absolute path (`$PWD` is `csharp/`). The two files differ in bytes (Python writes `1.0`, C# writes `1`) but not in content. Check:

```powershell
uv run --project ../python python -c "import json; f = lambda p: json.load(open(p)); print(f('../../12-aws-deploy/index/rag-index.json') == f('../../12-aws-deploy/index/rag-index-cs.json'))"
```

It prints `True`. Delete `rag-index-cs.json` afterwards; the images bake `rag-index.json`.

### Step 3: the deployable images

The images live in `projects/12-aws-deploy`, not in module 07, because they're module 07's service *plus* a baked index. The build context is `projects/`, so a `Dockerfile.dockerignore` sits next to each Dockerfile ([conventions](conventions.md#docker)). The same file works for both:

```text
**/.venv/
**/__pycache__/
**/.pytest_cache/
**/.ruff_cache/
**/.mypy_cache/
**/.vscode/
**/.vs/
**/bin/
**/obj/
**/outputs/
**/runs/
**/.terraform/
**/cdk.out/
```

The Python image skips the local-embedding stack. Nothing imports `sentence-transformers` when the index is baked and questions go to Titan, so `--no-install-package` leaves out PyTorch and its heaviest companions: about 700 MB the task would never touch.

```dockerfile
# projects/12-aws-deploy/python/Dockerfile — build context: projects/
# Module 07's service with the corpus embeddings baked in (VECTOR_STORE=baked).
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV PYTHONUNBUFFERED=1
WORKDIR /src
COPY 04-llm-client/python/ 04-llm-client/python/
COPY 07-rag-service/python/pyproject.toml 07-rag-service/python/uv.lock 07-rag-service/python/
WORKDIR /src/07-rag-service/python
# No dev tools, and none of the local-embedding stack: with the index baked and questions embedded
# by Bedrock, sentence-transformers is never imported. Skipping torch & co. cuts ~700 MB.
RUN uv sync --frozen --no-install-project --no-dev \
    --no-install-package torch --no-install-package sentence-transformers \
    --no-install-package transformers --no-install-package scipy --no-install-package scikit-learn
COPY 07-rag-service/python/ ./
COPY 07-rag-service/fixtures/ /src/07-rag-service/fixtures/
COPY 12-aws-deploy/index/rag-index.json /src/index/rag-index.json
ENV PATH="/src/07-rag-service/python/.venv/bin:$PATH" \
    FIXTURES_DIR=/src/07-rag-service/fixtures \
    VECTOR_STORE=baked \
    INDEX_PATH=/src/index/rag-index.json
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

The C# image sets `ASPNETCORE_HTTP_PORTS=8000`, so the task definition, target group and health check don't care which image runs. The SDK stage runs on the build machine's own platform (`$BUILDPLATFORM`), and its output is portable IL, so building for Graviton (`--platform linux/arm64`) only swaps the final base image; nothing runs emulated.

```dockerfile
# projects/12-aws-deploy/csharp/Dockerfile — build context: projects/
# Module 07's service with the corpus embeddings baked in (VECTOR_STORE=baked).
# The SDK stage runs on the build machine's platform; the output is portable IL, so only
# the final stage follows --platform (linux/arm64 for Graviton) and nothing runs emulated.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY 04-llm-client/csharp/Directory.Build.props 04-llm-client/csharp/
COPY 04-llm-client/csharp/src/LlmClient/LlmClient.csproj 04-llm-client/csharp/src/LlmClient/
COPY 07-rag-service/csharp/RagService.slnx 07-rag-service/csharp/Directory.Build.props 07-rag-service/csharp/
COPY 07-rag-service/csharp/src/RagService/RagService.csproj 07-rag-service/csharp/src/RagService/
COPY 07-rag-service/csharp/tests/RagService.Tests/RagService.Tests.csproj 07-rag-service/csharp/tests/RagService.Tests/
WORKDIR /src/07-rag-service/csharp
RUN dotnet restore
WORKDIR /src
COPY 04-llm-client/csharp/src/LlmClient/ 04-llm-client/csharp/src/LlmClient/
COPY 07-rag-service/csharp/ 07-rag-service/csharp/
WORKDIR /src/07-rag-service/csharp
RUN dotnet publish src/RagService -c Release -o /app --no-restore

FROM build AS test
COPY 07-rag-service/fixtures/ /src/07-rag-service/fixtures/
ENV FIXTURES_DIR=/src/07-rag-service/fixtures
ENTRYPOINT ["dotnet", "test", "--no-restore", "--filter", "TestCategory!=Eval"]

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
COPY 07-rag-service/fixtures/ ./fixtures/
COPY 12-aws-deploy/index/rag-index.json ./index/rag-index.json
# 8000, not the image's default 8080: one task definition, target group and health check for both images.
ENV ASPNETCORE_HTTP_PORTS=8000 \
    FIXTURES_DIR=/app/fixtures \
    VECTOR_STORE=baked \
    INDEX_PATH=/app/index/rag-index.json
EXPOSE 8000
USER $APP_UID
ENTRYPOINT ["dotnet", "RagService.dll"]
```

A compose file per language runs the same image locally. The image tag (`aws-deploy-py:local`, `aws-deploy-cs:local`) is the one `deploy.ps1` builds and pushes.

```yaml
# projects/12-aws-deploy/python/compose.yaml — the deployable image, run locally
name: aws-deploy-py
services:
  app:
    build: { context: ../.., dockerfile: 12-aws-deploy/python/Dockerfile }   # projects/: 04, 07 and the index
    image: aws-deploy-py:local   # the tag deploy.ps1 builds and pushes
    ports: ["8000:8000"]
    env_file:
      - path: .env   # optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      EMBED_BACKEND: ${EMBED_BACKEND:-hashing}   # must match the model that baked index/rag-index.json
    extra_hosts: ["host.docker.internal:host-gateway"]

  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

volumes:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

```yaml
# projects/12-aws-deploy/csharp/compose.yaml — the deployable image, run locally
name: aws-deploy-cs
services:
  app:
    build: { context: ../.., dockerfile: 12-aws-deploy/csharp/Dockerfile, target: final }   # projects/: 04, 07 and the index
    image: aws-deploy-cs:local   # the tag deploy.ps1 builds and pushes
    ports: ["8001:8000"]   # 8000 in the container (ASPNETCORE_HTTP_PORTS), 8001 on the host
    env_file:
      - path: .env   # optional
        required: false
    environment:
      LLM_BACKEND: ${LLM_BACKEND:-ollama}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}   # native Ollama, or --profile ollama
      OLLAMA_MODEL: ${OLLAMA_MODEL:-llama3.2}
      EMBED_BACKEND: ${EMBED_BACKEND:-hashing}   # must match the model that baked index/rag-index.json
    extra_hosts: ["host.docker.internal:host-gateway"]

  ollama:
    image: ollama/ollama:latest
    profiles: [ollama]   # opt in: skip it when Ollama runs natively (both want port 11434)
    ports: ["11434:11434"]
    volumes: ["ollama:/root/.ollama"]

volumes:
  ollama:
    name: ai-learn-ollama   # shared by every stack: each model downloads once
```

`.env.example`, shared by both stacks (copy it to `python/.env` and `csharp/.env`):

```bash
# projects/12-aws-deploy/python/.env.example
# Copy to .env (git-ignored). The deployed task sets its own values; these are for local runs.
# Chat: stub | ollama. Bedrock runs locally with `docker run` and your credentials (step 4).
LLM_BACKEND=stub
# Must match the model that baked ../index/rag-index.json: hashing for the offline index.
EMBED_BACKEND=hashing
# OLLAMA_BASE_URL=http://host.docker.internal:11434
# OLLAMA_MODEL=llama3.2
```

### Step 4: run the same image locally

**Offline first.** With the hashing index from step 2 and `LLM_BACKEND=stub` in `.env`, the container runs with no model and no AWS. From `projects/12-aws-deploy/python`:

```powershell
docker compose up -d --build
Invoke-RestMethod http://localhost:8000/health
Invoke-RestMethod -Method Post http://localhost:8000/ask -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?","k":2}' | ConvertTo-Json -Depth 5
docker compose down
```

The answer is the stub's echo of the prompt, and the citations are `oncall.md#0` and `oncall.md#1`, with no `/ingest`: the index came from the image. The C# stack is the same from `csharp/`, on port 8001.

**Then the same image against Bedrock.** `deploy.ps1 -BuildOnly` bakes a Titan index with your profile and builds the image, without Terraform and without pushing. Then run it with your `~/.aws` folder mounted read-only. The Python image runs as root, whose home is `/root`; the C# image runs as the non-root `app` user, whose home is `/home/app` ([environment settings](env-settings.md)). From `projects/12-aws-deploy`:

```powershell
pwsh ./deploy/deploy.ps1 -Lang python -BuildOnly
docker run --rm -p 8000:8000 `
    -v "${env:USERPROFILE}\.aws:/root/.aws:ro" `
    -e AWS_PROFILE=ai-learn -e AWS_REGION=us-east-1 `
    -e LLM_BACKEND=bedrock -e BEDROCK_MODEL_ID=us.amazon.nova-micro-v1:0 `
    -e EMBED_BACKEND=bedrock `
    -e Rates__InputPerMTok=0.035 -e Rates__OutputPerMTok=0.14 `
    aws-deploy-py:local
```

```powershell
pwsh ./deploy/deploy.ps1 -Lang csharp -BuildOnly
docker run --rm -p 8001:8000 `
    -v "${env:USERPROFILE}\.aws:/home/app/.aws:ro" `
    -e AWS_PROFILE=ai-learn -e AWS_REGION=us-east-1 `
    -e LLM_BACKEND=bedrock -e BEDROCK_MODEL_ID=us.amazon.nova-micro-v1:0 `
    -e EMBED_BACKEND=bedrock `
    -e Rates__InputPerMTok=0.035 -e Rates__OutputPerMTok=0.14 `
    aws-deploy-cs:local
```

Ask the same question, now at 8000 or 8001. An `AccessDeniedException` here is the cheapest place to discover a model or region problem. The rates are placeholders; take the real ones from the Bedrock pricing page. On WSL or Git Bash, mount `"$HOME/.aws"` instead, and in Git Bash prefix the command with `MSYS_NO_PATHCONV=1`.

### Step 5: the infrastructure (Terraform)

**The model ID goes into SSM first.** The task definition reads it at launch, and Terraform reads it at plan time to scope IAM to that model:

```powershell
aws ssm put-parameter --profile ai-learn --region us-east-1 `
    --name /ai-learn/aws-deploy/bedrock-model-id --type String --value us.amazon.nova-micro-v1:0 --overwrite
```

**Then find the regions its inference profile routes to:**

```powershell
aws bedrock get-inference-profile --profile ai-learn --region us-east-1 `
    --inference-profile-identifier us.amazon.nova-micro-v1:0 --query "models[].modelArn" --output text
```

Each ARN it prints is a foundation model in one region. Those regions go in `bedrock_routed_regions`. Miss one and requests fail intermittently with `AccessDeniedException`: only when the profile happens to route to the region you left out.

`main.tf` holds the registry, the roles and the service. Every name comes from `local.name`, which is `aws-deploy-` plus the workspace, so the same code makes an independent Python stack (`py`) and C# stack (`cs`).

```hcl
# infra/main.tf — one stack per Terraform workspace: py or cs
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { project = "ai-learn", stack = local.name }   # Cost Explorer can group spend by these
  }
}

locals {
  name = "aws-deploy-${terraform.workspace}"   # aws-deploy-py or aws-deploy-cs

  # BEDROCK_MODEL_ID lives in SSM (deploy step 1), so IAM is scoped to whatever model it names.
  chat_model_id = data.aws_ssm_parameter.chat_model_id.insecure_value
  # A cross-region inference profile ID is the foundation-model ID with a geography prefix:
  # us.amazon.nova-micro-v1:0 -> amazon.nova-micro-v1:0
  chat_foundation_model = replace(local.chat_model_id, "/^(us|eu|apac|global)\\./", "")
  chat_is_profile       = local.chat_model_id != local.chat_foundation_model
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "chat_model_id" {
  name = var.chat_model_param_name
}

# --- ECR: the private image registry ---
resource "aws_ecr_repository" "app" {
  name         = local.name
  force_delete = true   # otherwise `terraform destroy` fails while the repo still holds images
}

# --- IAM: who may assume the two roles below ---
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS uses to START the task (pull the image, write logs, resolve `secrets`).
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"   # ECR pull + logs
}

resource "aws_iam_role_policy" "execution_ssm" {
  name = "read-model-id"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # ECS resolves the task definition's `secrets` with THIS role, before your code runs.
      # A SecureString under a customer-managed KMS key would also need kms:Decrypt on that key.
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [data.aws_ssm_parameter.chat_model_id.arn]
    }]
  })
}

# Task role: what YOUR CODE runs as. Bedrock invoke on two models, nothing else.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "bedrock" {
  statement {
    sid = "Chat"
    # Converse is authorized by bedrock:InvokeModel; there's no bedrock:Converse action.
    # Add bedrock:InvokeModelWithResponseStream if you serve ConverseStream.
    actions = ["bedrock:InvokeModel"]
    resources = concat(
      # The inference profile itself, when BEDROCK_MODEL_ID is one...
      local.chat_is_profile ? [
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.chat_model_id}"
      ] : [],
      # ...and the foundation model in EVERY region the profile can route a request to.
      [for r in (local.chat_is_profile ? var.bedrock_routed_regions : [var.region]) :
      "arn:aws:bedrock:${r}::foundation-model/${local.chat_foundation_model}"],
    )
  }
  statement {
    sid       = "EmbedQuestions"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_embed_model_id}"]
  }
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.bedrock.json
}

# --- ECS Fargate: cluster, log group, task definition, service ---
resource "aws_ecs_cluster" "this" {
  name = local.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"   # the awslogs driver won't create it for you
  retention_in_days = 14                     # don't keep (possibly PII-bearing) logs forever (module 13)
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"    # CPU-light: latency is the Bedrock call, and the index is tiny
  memory                   = "1024"
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture   # ARM64 (Graviton) is cheaper; the image must match
  }

  container_definitions = jsonencode([{
    name         = local.name
    image        = "${aws_ecr_repository.app.repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]   # both images listen on 8000
    environment = [
      { name = "LLM_BACKEND", value = "bedrock" },
      { name = "AWS_REGION", value = var.region },
      { name = "EMBED_BACKEND", value = "bedrock" },   # must match the baked index; the app checks
      { name = "BEDROCK_EMBED_MODEL_ID", value = var.bedrock_embed_model_id },
      { name = "Rates__InputPerMTok", value = tostring(var.rates_input_per_mtok) },
      { name = "Rates__OutputPerMTok", value = tostring(var.rates_output_per_mtok) },
    ]
    # Resolved from SSM at launch by the execution role. Never baked into the image.
    secrets = [
      { name = "BEDROCK_MODEL_ID", valueFrom = data.aws_ssm_parameter.chat_model_id.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Failed ALB health checks during startup don't count for this long, so a slow start
  # (pulling the image, loading the index) isn't killed and replaced in a loop.
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true   # public subnets and no NAT gateway: the public IP is how it reaches ECR, SSM and Bedrock
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.name
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http]   # a target group must be behind a listener before a service can use it
}
```

For `us.amazon.nova-micro-v1:0` in `us-east-1`, the task role's chat statement comes out as below. A model ID without a geography prefix gets just its own foundation-model ARN.

```json
{
  "Sid": "Chat",
  "Effect": "Allow",
  "Action": "bedrock:InvokeModel",
  "Resource": [
    "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.amazon.nova-micro-v1:0",
    "arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-micro-v1:0",
    "arn:aws:bedrock:us-east-2::foundation-model/amazon.nova-micro-v1:0",
    "arn:aws:bedrock:us-west-2::foundation-model/amazon.nova-micro-v1:0"
  ]
}
```

`network.tf` uses the account's default VPC, whose subnets are public. That's what keeps the stack cheap: tasks get a public IP and reach ECR, SSM and Bedrock through the internet gateway, with no NAT gateway billing by the hour. The ALB admits your CIDR only, and the tasks admit the ALB only.

```hcl
# infra/network.tf — the default VPC, two security groups, and the ALB
# The default VPC's subnets are public (an internet gateway, no NAT gateway), which is what
# keeps this stack cheap. If your account has no default VPC: aws ec2 create-default-vpc.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]   # one per availability zone; an ALB needs at least two
  }
}

# --- The ALB accepts HTTP from your IP only. /ask spends money per call, so it is never open to the world. ---
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB: HTTP from allowed_cidr only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.allowed_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

# --- Tasks accept traffic from the ALB only, and call out to ECR, SSM, CloudWatch and Bedrock. ---
resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Fargate tasks: port 8000 from the ALB only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_out" {
  security_group_id = aws_security_group.task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_lb" "app" {
  name               = local.name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  idle_timeout       = 120   # seconds; a slow model call can outlast the 60 s default
}

resource "aws_lb_target_group" "app" {
  name                 = local.name
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"   # awsvpc tasks register by IP; the "instance" default fails for Fargate
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 30     # seconds to drain an old task on deploy (default 300)

  health_check {
    path                = "/health"   # liveness only: it must never call Bedrock
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

`alarms.tf` is the fast smoke detector from step 0:

```hcl
# infra/alarms.tf — a near-real-time spend signal. AWS Budgets updates a few times a day,
# so a runaway loop can burn hours of tokens before the budget email arrives. Bedrock's
# token metrics land in CloudWatch within minutes.
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email   # AWS emails a confirmation link; nothing arrives until you click it
}

resource "aws_cloudwatch_metric_alarm" "bedrock_output_tokens" {
  alarm_name        = "${local.name}-bedrock-output-tokens"
  alarm_description = "Bedrock output tokens in 5 minutes above the limit: a loop, a retry storm or abuse."
  namespace         = "AWS/Bedrock"
  metric_name       = "OutputTokenCount"   # output tokens are the expensive ones
  dimensions = {
    ModelId = local.chat_model_id
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.max_output_tokens_per_5_min
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"   # no calls means no data, which is fine
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

```hcl
# infra/variables.tf — values come from terraform.tfvars (git-ignored); see terraform.tfvars.example
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = "ai-learn"   # docs/env-settings.md
}

variable "allowed_cidr" {
  type        = string
  description = "Who may call the ALB: your public IP as a /32, e.g. 203.0.113.7/32"
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a CIDR such as 203.0.113.7/32, and not 0.0.0.0/0."
  }
}

variable "alert_email" {
  type        = string
  description = "Where the token alarm sends its email"
}

variable "chat_model_param_name" {
  type    = string
  default = "/ai-learn/aws-deploy/bedrock-model-id"
}

variable "bedrock_routed_regions" {
  type        = list(string)
  description = "Every region the chat inference profile routes to: aws bedrock get-inference-profile lists them"
  default     = ["us-east-1", "us-east-2", "us-west-2"]
}

variable "bedrock_embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"   # must be the model that baked the index
}

variable "rates_input_per_mtok" {
  type        = number
  description = "USD per million input tokens for the chat model: from the Bedrock pricing page"
}

variable "rates_output_per_mtok" {
  type        = number
  description = "USD per million output tokens for the chat model"
}

variable "max_output_tokens_per_5_min" {
  type    = number
  default = 50000
}

variable "cpu_architecture" {
  type    = string
  default = "X86_64"
  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}
```

```hcl
# infra/outputs.tf — what deploy.ps1 reads with `terraform output -raw <name>`
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "image_platform" {
  value = var.cpu_architecture == "ARM64" ? "linux/arm64" : "linux/amd64"
}

output "url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}
```

```hcl
# infra/terraform.tfvars.example — copy to terraform.tfvars (git-ignored) and fill in.
# Both workspaces (py, cs) read the same file; local.name keeps their resources apart.
region       = "us-east-1"
aws_profile  = "ai-learn"
allowed_cidr = "203.0.113.7/32"   # your public IP: curl.exe -s https://checkip.amazonaws.com
alert_email  = "you@example.com"

# The chat model ID itself lives in SSM (/ai-learn/aws-deploy/bedrock-model-id).
# These are the regions its inference profile routes to: aws bedrock get-inference-profile.
bedrock_routed_regions = ["us-east-1", "us-east-2", "us-west-2"]
bedrock_embed_model_id = "amazon.titan-embed-text-v2:0"

# The chat model's prices, from the Bedrock pricing page. These numbers are placeholders.
rates_input_per_mtok  = 0.035
rates_output_per_mtok = 0.14

max_output_tokens_per_5_min = 50000
cpu_architecture            = "X86_64"   # or ARM64: Graviton, cheaper; deploy.ps1 builds to match
```

For **Graviton**, set `cpu_architecture = "ARM64"`. The task definition's `runtime_platform` then asks Fargate for ARM, and `deploy.ps1` reads the `image_platform` output and builds `linux/arm64` to match. A mismatch shows up as `exec format error` in the task's log.

### Step 6: deploy

`deploy.ps1` is PowerShell 7, which also runs on Linux and macOS (and in CI). It bakes the index with your profile, builds the image for the stack's platform, pushes it tagged with the commit and `latest`, rolls the service, waits for it to be stable, and checks `/health`. It uses the AWS CLI's own `--query` instead of `jq`.

```powershell
# deploy/deploy.ps1 — bake the index, build the image, push it to ECR, roll the ECS service.
# Prereqs: the budget exists (deploy/budget.json), the SSM parameter exists, and
# `terraform apply` has run in this language's workspace (py or cs).
#   pwsh ./deploy/deploy.ps1 -Lang python              # deploy
#   pwsh ./deploy/deploy.ps1 -Lang python -BuildOnly   # bake + build locally; no Terraform, no push
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('python', 'csharp')][string] $Lang,
    [string] $AwsProfile = 'ai-learn',
    [string] $Region = 'us-east-1',
    [string] $Platform = 'linux/amd64',   # -BuildOnly only; a deploy builds for the stack's cpu_architecture
    [switch] $BuildOnly
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true   # a failing docker/aws/terraform call stops the script

$root = Split-Path $PSScriptRoot -Parent      # projects/12-aws-deploy
$projects = Split-Path $root -Parent          # projects/: the Docker build context (04, 07 and 12)
$infra = Join-Path $root 'infra'
$suffix = @{ python = 'py'; csharp = 'cs' }[$Lang]
$image = "aws-deploy-${suffix}:local"
$index = Join-Path $root 'index/rag-index.json'

if (-not $BuildOnly) {
    terraform -chdir="$infra" workspace select $suffix   # this language's stack
    $repo = terraform -chdir="$infra" output -raw ecr_repository_url
    $Platform = terraform -chdir="$infra" output -raw image_platform
}

# 1) Bake the index with the model the service will embed questions with: Titan, on your
#    profile's credentials. The env vars are restored afterwards, so your shell is unchanged.
$saved = @{}
foreach ($name in 'AWS_PROFILE', 'AWS_REGION', 'EMBED_BACKEND') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:AWS_PROFILE = $AwsProfile; $env:AWS_REGION = $Region; $env:EMBED_BACKEND = 'bedrock'
    if ($Lang -eq 'python') {
        Push-Location (Join-Path $projects '07-rag-service/python')
        try { uv run python -m app.build_index --out $index } finally { Pop-Location }
    }
    else {
        Push-Location (Join-Path $projects '07-rag-service/csharp')
        try { dotnet run --project src/RagService -- build-index $index } finally { Pop-Location }
    }
}
finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}

# 2) Build the image. The context is projects/, because the image needs 04, 07 and the index.
docker build --platform $Platform -f (Join-Path $root "$Lang/Dockerfile") -t $image $projects
if ($BuildOnly) {
    Write-Host "Built $image ($Platform). Run it against Bedrock locally before you deploy it."
    return
}

# 3) Push, tagged with the commit and as latest (the tag the task definition runs).
$sha = git rev-parse --short HEAD
aws ecr get-login-password --profile $AwsProfile --region $Region |
    docker login --username AWS --password-stdin $repo.Split('/')[0]
foreach ($tag in $sha, 'latest') {
    docker tag $image "${repo}:$tag"
    docker push "${repo}:$tag"
}

# 4) Roll the service onto the new image, wait until it's stable, then smoke-test it.
#    --query and --output text instead of jq: the AWS CLI filters JSON itself.
$cluster = terraform -chdir="$infra" output -raw cluster_name
$service = terraform -chdir="$infra" output -raw service_name
aws ecs update-service --profile $AwsProfile --region $Region --cluster $cluster --service $service `
    --force-new-deployment --query 'service.serviceName' --output text
aws ecs wait services-stable --profile $AwsProfile --region $Region --cluster $cluster --services $service
$url = terraform -chdir="$infra" output -raw url
Write-Host "Deployed $sha to $url"
curl.exe -s "$url/health"
```

From `projects/12-aws-deploy`, the first deploy of the Python stack:

```powershell
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars    # then set allowed_cidr, alert_email and the rates
terraform init
terraform workspace select -or-create py              # safe to rerun; `workspace new` fails the second time
terraform apply
cd ..
pwsh ./deploy/deploy.ps1 -Lang python
```

On the first `apply` the ECR repository is still empty, so the service's task fails to pull `:latest` and ECS keeps retrying. That's expected: `deploy.ps1` pushes the image and forces a new deployment. Confirm the SNS subscription email, or the token alarm has nowhere to go. Then:

```powershell
$url = terraform -chdir=infra output -raw url
Invoke-RestMethod "$url/health"
Invoke-RestMethod -Method Post "$url/ask" -ContentType 'application/json' `
    -Body '{"question":"How do I roll back a deploy?","k":2}' | ConvertTo-Json -Depth 5
```

Now try the URL from your phone on mobile data. It times out: that's the security group. Logs are in the `log_group` output's CloudWatch log group; `aws logs tail (terraform -chdir=infra output -raw log_group) --follow --profile ai-learn --region us-east-1` streams them.

The C# stack is the same with the other workspace:

```powershell
cd infra
terraform workspace select -or-create cs
terraform apply
cd ..
pwsh ./deploy/deploy.ps1 -Lang csharp
```

Record in `NOTES.md`: what bit you (IAM scope, routed regions and the SSM parameter are the usual three), the image sizes (`docker images aws-deploy-*`), startup time to healthy, and `/ask` latency from your machine. Bedrock's call dominates the latency, as predicted.

### Step 7: tear down

Destroy every stack you deployed, then the workspaces, then the SSM parameter. The parameter goes **last**: Terraform reads it on every plan, `destroy` included. Keep it if you're going straight on to module 13.

```powershell
cd projects/12-aws-deploy/infra
terraform workspace select cs; terraform destroy
terraform workspace select py; terraform destroy
terraform workspace select default
terraform workspace delete cs; terraform workspace delete py
aws ssm delete-parameter --profile ai-learn --region us-east-1 --name /ai-learn/aws-deploy/bedrock-model-id
```

`force_delete` on the ECR repository lets `destroy` delete it with images inside. Keep the budget; budgets themselves cost nothing or next to nothing (check the Budgets pricing page).

What a stack costs while it sits idle, roughly, in `us-east-1` (check the pricing pages; these move):

| Resource | Idle cost | Notes |
|---|---|---|
| Application Load Balancer | ~$0.55/day | billed per hour plus capacity units, traffic or not |
| Fargate task, 0.5 vCPU / 1 GB | ~$0.60/day x86, less on Graviton | per second while running |
| Public IPv4 addresses | ~$0.12/day each | the task's, plus one per ALB availability zone |
| CloudWatch Logs, alarm, SNS | cents a month | 14-day log retention |
| ECR storage | ~$0.10/GB-month | about 0.6 GB for both images |
| NAT gateway | **none** | the default-VPC design avoids ~$1/day per gateway |
| Bedrock | per token only | nothing while idle |

### Optional: the same stack in CDK (C#)

`cdk init app --language csharp` in `projects/12-aws-deploy/infra-cdk` gives a .NET project that references `Amazon.CDK.Lib`. Set its `TargetFramework` to `net10.0`, delete the template's stack class, and add the two files below. `ApplicationLoadBalancedFargateService` does in one construct what `main.tf` and `network.tf` do by hand, and its defaults are where the money hides: given no VPC, it creates one **with NAT gateways**, and it opens the listener to the internet. So the stack passes its own VPC with `NatGateways = 0` and public subnets, gives the task a public IP, and sets `OpenListener = false`.

```csharp
// src/InfraCdk/AwsDeployStack.cs — the infra/*.tf stack as one CDK construct tree
using System.Text.RegularExpressions;
using Amazon.CDK;
using Amazon.CDK.AWS.CloudWatch;
using Amazon.CDK.AWS.CloudWatch.Actions;
using Amazon.CDK.AWS.EC2;
using Amazon.CDK.AWS.Ecr.Assets;
using Amazon.CDK.AWS.ECS;
using Amazon.CDK.AWS.ECS.Patterns;
using Amazon.CDK.AWS.IAM;
using Amazon.CDK.AWS.SNS;
using Amazon.CDK.AWS.SNS.Subscriptions;
using Amazon.CDK.AWS.SSM;
using Constructs;
using EcsSecret = Amazon.CDK.AWS.ECS.Secret;                                 // not the Secrets Manager one
using ElbHealthCheck = Amazon.CDK.AWS.ElasticLoadBalancingV2.HealthCheck;   // ECS has a HealthCheck type too

namespace InfraCdk;

public sealed record AwsDeploySettings(
    string Lang,          // python | csharp: which Dockerfile to build
    string ProjectsDir,   // the Docker build context: projects/
    string AllowedCidr,   // your public IP as a /32
    string AlertEmail)
{
    public string ChatModelParamName { get; init; } = "/ai-learn/aws-deploy/bedrock-model-id";
    public string[] RoutedRegions { get; init; } = ["us-east-1", "us-east-2", "us-west-2"];
    public string EmbedModelId { get; init; } = "amazon.titan-embed-text-v2:0";
    public string InputPerMTok { get; init; } = "0.035";   // placeholders: take them from the Bedrock pricing page
    public string OutputPerMTok { get; init; } = "0.14";
    public double MaxOutputTokensPer5Min { get; init; } = 50_000;
}

public sealed class AwsDeployStack : Stack
{
    public AwsDeployStack(Construct scope, string id, AwsDeploySettings s, IStackProps props) : base(scope, id, props)
    {
        // Public subnets only and NO NAT gateway. Without a Vpc, the pattern creates one with
        // NAT gateways, which bill by the hour whether or not anything runs.
        var vpc = new Vpc(this, "Vpc", new VpcProps
        {
            MaxAzs = 2,   // an ALB needs two availability zones
            NatGateways = 0,
            SubnetConfiguration = [new SubnetConfiguration { Name = "public", SubnetType = SubnetType.PUBLIC }],
        });

        // Read at synth time (a context lookup, cached in cdk.context.json), so IAM can be scoped to it.
        string chatModelId = StringParameter.ValueFromLookup(this, s.ChatModelParamName);
        IStringParameter chatModelParam = StringParameter.FromStringParameterName(this, "ChatModelId", s.ChatModelParamName);

        var svc = new ApplicationLoadBalancedFargateService(this, "Svc", new ApplicationLoadBalancedFargateServiceProps
        {
            Vpc = vpc,
            TaskSubnets = new SubnetSelection { SubnetType = SubnetType.PUBLIC },
            AssignPublicIp = true,   // how the task reaches ECR, SSM and Bedrock without a NAT gateway
            OpenListener = false,    // the default opens port 80 to 0.0.0.0/0; one CIDR is allowed below
            Cpu = 512,
            MemoryLimitMiB = 1024,
            DesiredCount = 1,
            HealthCheckGracePeriod = Duration.Seconds(60),
            RuntimePlatform = new RuntimePlatform
            {
                OperatingSystemFamily = OperatingSystemFamily.LINUX,
                CpuArchitecture = CpuArchitecture.X86_64,   // ARM64 for Graviton, with Platform_.LINUX_ARM64 below
            },
            TaskImageOptions = new ApplicationLoadBalancedTaskImageOptions
            {
                // CDK builds the image and pushes it to its bootstrap ECR repo. The excludes keep
                // virtualenvs and build output out of the asset copy (and out of its hash).
                Image = ContainerImage.FromAsset(s.ProjectsDir, new AssetImageProps
                {
                    File = $"12-aws-deploy/{s.Lang}/Dockerfile",
                    Platform = Platform_.LINUX_AMD64,
                    Exclude = ["**/.venv", "**/bin", "**/obj", "**/cdk.out", "**/.terraform", "**/__pycache__"],
                }),
                ContainerPort = 8000,
                Environment = new Dictionary<string, string>
                {
                    ["LLM_BACKEND"] = "bedrock",
                    ["AWS_REGION"] = Region,
                    ["EMBED_BACKEND"] = "bedrock",
                    ["BEDROCK_EMBED_MODEL_ID"] = s.EmbedModelId,
                    ["Rates__InputPerMTok"] = s.InputPerMTok,
                    ["Rates__OutputPerMTok"] = s.OutputPerMTok,
                },
                // CDK grants the EXECUTION role read on this parameter, as infra/main.tf does by hand.
                Secrets = new Dictionary<string, EcsSecret> { ["BEDROCK_MODEL_ID"] = EcsSecret.FromSsmParameter(chatModelParam) },
            },
        });

        svc.LoadBalancer.Connections.AllowFrom(Peer.Ipv4(s.AllowedCidr), Port.Tcp(80), "HTTP from the allowed CIDR only");
        svc.LoadBalancer.SetAttribute("idle_timeout.timeout_seconds", "120");
        svc.TargetGroup.SetAttribute("deregistration_delay.timeout_seconds", "30");
        svc.TargetGroup.ConfigureHealthCheck(new ElbHealthCheck { Path = "/health", Interval = Duration.Seconds(15) });

        // Least privilege: the same Resource list as infra/main.tf.
        string foundationModel = Regex.Replace(chatModelId, @"^(us|eu|apac|global)\.", "");
        List<string> chatArns = foundationModel != chatModelId
            ? [$"arn:aws:bedrock:{Region}:{Account}:inference-profile/{chatModelId}",
               .. s.RoutedRegions.Select(r => $"arn:aws:bedrock:{r}::foundation-model/{foundationModel}")]
            : [$"arn:aws:bedrock:{Region}::foundation-model/{chatModelId}"];
        svc.TaskDefinition.TaskRole.AddToPrincipalPolicy(new PolicyStatement(new PolicyStatementProps
        {
            Actions = ["bedrock:InvokeModel"],
            Resources = [.. chatArns, $"arn:aws:bedrock:{Region}::foundation-model/{s.EmbedModelId}"],
        }));

        // The near-real-time spend signal (infra/alarms.tf).
        var alerts = new Topic(this, "Alerts");
        alerts.AddSubscription(new EmailSubscription(s.AlertEmail));
        var outputTokens = new Metric(new MetricProps
        {
            Namespace = "AWS/Bedrock",
            MetricName = "OutputTokenCount",
            DimensionsMap = new Dictionary<string, string> { ["ModelId"] = chatModelId },
            Statistic = "Sum",
            Period = Duration.Minutes(5),
        });
        outputTokens.CreateAlarm(this, "BedrockOutputTokens", new CreateAlarmOptions
        {
            Threshold = s.MaxOutputTokensPer5Min,
            EvaluationPeriods = 1,
            ComparisonOperator = ComparisonOperator.GREATER_THAN_THRESHOLD,
            TreatMissingData = TreatMissingData.NOT_BREACHING,
        }).AddAlarmAction(new SnsAction(alerts));
    }
}
```

```csharp
// src/InfraCdk/Program.cs — two stacks; deploy and destroy them one at a time
using Amazon.CDK;
using InfraCdk;

var app = new App();

// Personal values come from the command line (-c allowedCidr=... -c alertEmail=...), not from a committed file.
string Context(string key) => app.Node.TryGetContext(key) as string
    ?? throw new InvalidOperationException($"missing context value '{key}': pass -c {key}=...");

// The account and region your --profile resolves to; the SSM lookup in the stack needs both.
var env = new Amazon.CDK.Environment
{
    Account = System.Environment.GetEnvironmentVariable("CDK_DEFAULT_ACCOUNT"),
    Region = System.Environment.GetEnvironmentVariable("CDK_DEFAULT_REGION"),
};
string projects = Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), "..", ".."));   // infra-cdk -> projects/

foreach (var (id, lang) in new[] { ("AwsDeployPy", "python"), ("AwsDeployCs", "csharp") })
    new AwsDeployStack(app, id, new AwsDeploySettings(lang, projects, Context("allowedCidr"), Context("alertEmail")),
        new StackProps { Env = env });

app.Synth();
```

`ValueFromLookup` reads the SSM parameter at synth time (and caches it in `cdk.context.json`), so the IAM statement names the same ARNs as the Terraform version. `ContainerImage.FromAsset` builds the image from `projects/` and pushes it to the CDK bootstrap's ECR repository, so there's no `deploy.ps1` in this path, but bake the index first. From `projects/12-aws-deploy/infra-cdk`:

```powershell
cdk bootstrap --profile ai-learn                     # once per account and region
cdk deploy AwsDeployPy --profile ai-learn -c allowedCidr=203.0.113.7/32 -c alertEmail=you@example.com
cdk destroy AwsDeployPy --profile ai-learn -c allowedCidr=203.0.113.7/32 -c alertEmail=you@example.com
```

`cdk destroy` leaves the bootstrap stack (`CDKToolkit`: an S3 bucket and an ECR repository holding your built assets). Delete it in the CloudFormation console when you're done with CDK; empty its bucket first. The C# CDK app has nothing to do with the C# service: it deploys the Python image just as happily.

### Optional: the same API on Lambda

Fargate is the recommendation for an always-on chat API, but a low-traffic internal endpoint can cost almost nothing on Lambda. ASP.NET Core runs there with `Amazon.Lambda.AspNetCoreServer.Hosting` and one line, `builder.Services.AddAWSLambdaHosting(LambdaEventSource.HttpApi)`, which is a no-op outside Lambda. Before choosing it, check:

- **Runtime version.** AWS's managed .NET runtimes trail the SDK. If yours isn't offered, deploy a container-image Lambda, or a Native AOT binary on `provided.al2023`.
- **Cold starts.** JIT plus the AWS SDK plus the baked index plus a multi-second model call is a slow first request. Native AOT (`<PublishAot>true</PublishAot>`, `WebApplication.CreateSlimBuilder`) cuts startup sharply; the cost is trimming, so reflection-based JSON needs a `JsonSerializerContext`, and you check that the AWS SDK and MEAI packages you use are AOT-compatible.
- **Timeouts.** Lambda's maximum duration and API Gateway's integration timeout both cap a request; long generations hit them.

## Cross-check the two

**Exact, offline, every build.** Both test suites pin the same things: the Converse request built from the same messages, the same usage and cost numbers (12 in, 5 out, $1 and $4 per million), the stop-reason mapping, the Titan request body, the baked file's format, order and model name, and the retrieval ids from a baked index (`oncall.md#0`, `oncall.md#1`, `billing.md#0`).

**Exact, offline, across languages.** Bake a hashing index with each language (step 2) and compare: same content. Then run *both* services on the **same** file, which is the real claim, that either image can load either builder's index. From `projects/07-rag-service`, each in its own terminal:

```powershell
# Terminal 1
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'baked'
$env:INDEX_PATH = (Resolve-Path ../12-aws-deploy/index/rag-index.json).Path
cd python; uv run --no-sync uvicorn app.main:app --port 8000

# Terminal 2
$env:LLM_BACKEND = 'stub'; $env:EMBED_BACKEND = 'hashing'; $env:VECTOR_STORE = 'baked'
$env:INDEX_PATH = (Resolve-Path ../12-aws-deploy/index/rag-index.json).Path
cd csharp; dotnet run --project src/RagService -- --urls http://localhost:8001
```

Then, in a third:

```powershell
$body = '{"question":"Who has to approve a refund?","k":2}'
$ask = foreach ($port in 8000, 8001) {
    Invoke-RestMethod -Method Post "http://localhost:$port/ask" -ContentType 'application/json' -Body $body |
        ConvertTo-Json -Depth 5
}
$ask[0] -ceq $ask[1]    # True: same answer, same citations
```

**On AWS.** Deploy each language in turn (or both, briefly) and compare:

- **`GET /health`** must match exactly: same status, same `{"status":"ok"}`. The ALB doesn't know which language it's talking to.
- **`POST /ask`** must have the same shape and the same citations for the same question: both embed the question with Titan and search the same baked vectors, so retrieval is deterministic. The answer text matches only approximately: the same model, but generation isn't deterministic.
- **A malformed body** is a 422 from both for a missing or empty `question` (module 07's contract); the error bodies differ.
- **Startup time, image size and memory** differ; record them in `NOTES.md`. Latency per request should be close, because Bedrock dominates.

| Concern | Python | C# / .NET |
|---|---|---|
| Bedrock chat | `BedrockClient`: boto3 `converse`, on a worker thread | `AsIChatClient(modelId)` from `AWSSDK.Extensions.Bedrock.MEAI` |
| Bedrock embeddings | `BedrockEmbedder`: boto3 `invoke_model`, Titan body by hand | `AsIEmbeddingGenerator(modelId)` |
| Optional dependency | the `[bedrock]` extra; lazy import in the factory | package references in `LlmClient` |
| Retries | botocore's own retry mode | the AWS SDK's own retry mode; the HTTP resilience handler isn't on this path |
| Missing model ID | `KeyError` when the factory runs (startup, via 07's lifespan) | `InvalidOperationException` in `AddLlmClient` (startup) |
| Test fake | a real boto3 client with botocore's `Stubber` | a real `AmazonBedrockRuntimeClient` with `ConverseAsync` overridden |
| Baked index | `baked.py`, `python -m app.build_index --out` | `BakedIndex.cs`, `dotnet run -- build-index` |
| Credentials in Docker | `/root/.aws` (root user); SSO needs `botocore[crt]` | `/home/app/.aws` (non-root `app` user); SSO needs `AWSSDK.SSO` + `AWSSDK.SSOOIDC` |
| Port | uvicorn on 8000 | `ASPNETCORE_HTTP_PORTS=8000` |
| Final image | `python:3.12-slim`, ~350 MB without PyTorch | `aspnet:10.0`, ~260 MB |
| IaC (natural fit) | Terraform, or CDK in Python | Terraform, or CDK in C# |
| Lambda | an ASGI adapter or the Lambda Web Adapter | `Amazon.Lambda.AspNetCoreServer.Hosting`; Native AOT for cold starts |

## Moving to AWS

This module *is* the move. The point worth noticing: **you didn't rearchitect to deploy.** The backend seam from [04](04-calling-models-apis-sdks.md), the store and embedder seams from [07](07-retrieval-augmented-generation.md), and env-driven config meant "go to production" was *one new backend, one new store, a Dockerfile, IaC and a script*. The capstone ([17](17-capstone-and-portfolio.md)) replaces the baked index with a managed vector store when the corpus outgrows an image.

## How experts think / pitfalls

- **Budget before the first deploy, plus a fast alarm.** Budgets lag by hours; a CloudWatch alarm on Bedrock's token metric reacts in minutes. Per-token billing plus a loop bug is a silent, unbounded bill.
- **Never an open `/ask`.** A public endpoint that spends money per request gets found. Restrict ingress in the same change that creates it; add rate limits and WAF next ([13](13-cost-scaling-and-security.md)).
- **Don't provision GPUs to call Bedrock.** A Bedrock-backed service is CPU-light glue.
- **IAM is the auth, and inference profiles widen it.** Scope `bedrock:InvokeModel` to the profile ARN plus the foundation model in every routed region. `"Resource": "*"` works and is wrong.
- **Same embedding model for the index and the questions, enforced.** Write the model's name into the index and refuse to start on a mismatch. A mismatch doesn't error; it just returns wrong documents.
- **NAT gateways are the classic idle cost.** CDK's Fargate pattern creates them by default. Public subnets with public IPs, or VPC endpoints, avoid them for a learning stack.
- **Fail at startup, not on the first request.** A missing model ID, a missing index or an unknown backend should stop the task, so ECS shows an unhealthy deployment instead of users seeing 500s.
- **`target_type = "ip"` and port parity.** Fargate tasks register by IP. The .NET images default to 8080; forgetting `ASPNETCORE_HTTP_PORTS` is the classic "healthy locally, unhealthy behind the ALB" bug.
- **Run the exact image against Bedrock locally first.** IAM, region and model-access errors are cheaper on your laptop.
- **Tear down in the right order.** Stacks, then workspaces, then the parameter they read. A destroy that fails halfway leaves billing resources behind.
- **Gate deploys on evals, not just tests** ([09](09-evaluation-and-testing.md)). A green unit-test suite can ship a model regression.

## Review track sync

> Parallel track: [R — Reviewing AI-written code](R-reviewing-ai-written-code.md). Keep it in step with this module.

- **Move to the cloud:** run your personal benchmark in CodeBuild against Bedrock-hosted models, archiving outputs to S3 (see the track's *Moving to AWS*).
- **Watch for:** in agent-written IaC, over-broad IAM (`"Action": "*"`, `"Resource": "*"`), `0.0.0.0/0` ingress on anything that spends money, NAT gateways nobody asked for, missing `force_delete` or retention settings, and unrequested resources (`scope-creep`). Review the IaC diff with more care than application code: cost and blast radius are bigger here.
- **C#-specific watch:** the AWS SDK for .NET and its MEAI bridge move fast. Agents mix up `AsIChatClient` with the older `AsChatClient`, invent `AddBedrock...()` DI helpers that don't exist, and reach for pre-GA MEAI names (`CompleteAsync`, `ChatCompletion`). In CDK C#, watch for TypeScript-style property names and object literals that won't compile, the ambiguous `HealthCheck` and `Secret` types (ECS vs ELB, ECS vs Secrets Manager), and `Resources = ["*"]`. In Dockerfiles, watch for a missing `ASPNETCORE_HTTP_PORTS`, a `runtime` (not `aspnet`) base image for a web app, and SSO profiles that fail inside the container because `AWSSDK.SSO`/`AWSSDK.SSOOIDC` aren't referenced.

## Checkpoint

You're ready for [13](13-cost-scaling-and-security.md) if you can:

- [ ] Choose Lambda, Fargate, EKS or EC2-GPU for a described AI workload and justify it, including why a Bedrock-backed app needs no GPU.
- [ ] Show module 04's `bedrock` backend passing its offline tests in both languages (`uv run pytest`, `dotnet test`), and explain why it has no retry wrapper of its own.
- [ ] Explain the baked index: why it replaces Chroma here, why Titan embeds both the corpus and the questions, and what happens if they don't match. Show the cross-language check returning `True`.
- [ ] Run the deployable image locally offline (stub and hashing), then against Bedrock with your credentials mounted, in both languages.
- [ ] Write the IAM `Resource` list for a cross-region inference profile and say where each ARN comes from.
- [ ] Deploy with `terraform apply` and `deploy.ps1`, get a cited answer from the ALB URL, and show that a request from another IP times out.
- [ ] Explain why the budget alone isn't enough, and point at the alarm that fills the gap.
- [ ] Tear everything down in order and list what would have kept billing if you hadn't.
- [ ] Say when .NET on Lambda is worth it, and what Native AOT buys and costs.

## Going deeper

- **Amazon Bedrock** docs: the `Converse` API, inference profiles and their IAM requirements, model availability by region, and Titan Text Embeddings V2.
- **Amazon ECS on Fargate** and **Application Load Balancer** docs: task definitions, `awsvpc` networking, target groups, health-check grace periods.
- **Terraform AWS provider** docs for `aws_ecs_service`, `aws_lb_target_group` and the `aws_vpc_security_group_*_rule` resources; or **AWS CDK** `ApplicationLoadBalancedFargateService`.
- **SSM Parameter Store** and **Secrets Manager**: the two stores and how ECS injects them.
- **AWS Budgets**, **Cost Anomaly Detection**, and the **Bedrock CloudWatch metrics** (`InputTokenCount`, `OutputTokenCount`, `Invocations`).
- AWS's **GitHub Actions OIDC** guidance: keyless CI auth.
- "AWSSDK.Extensions.Bedrock.MEAI" and "Microsoft.Extensions.AI IChatClient / IEmbeddingGenerator": the Bedrock bridge and the abstractions it plugs into.
- "Amazon.Lambda.AspNetCoreServer.Hosting", "ASP.NET Core Native AOT" and "System.Text.Json source generation": the API on Lambda with acceptable cold starts.

*Last verified: 2026-10-05. Built, in a throwaway build of modules 04 and 07 plus this project: module 04 with `bedrock` (pytest 23 passed with botocore `Stubber`, pyright clean; dotnet test 21 passed with a fake runtime); module 07 with `baked` (pytest 29 passed, pyright clean; dotnet test 28 passed); both `build-index` steps on hashing (identical content) and both services on one baked file (byte-identical `/ask`); the Python image's dependency set without PyTorch serving `/ask`; `deploy.ps1` parsed and dry-run with stubbed commands; the budget and SSM inputs validated against botocore's service models; the CDK C# app built and synthesized offline (no NAT gateway, CIDR-only ingress, the IAM ARNs above). Read-only: Terraform (HCL parsed, but `terraform fmt -check` and `terraform validate` not run: Terraform wasn't installed), Docker images (compose files validated with `docker compose config`), and everything against AWS: no deploy, no Bedrock call.*

**Verify on first build:**

- `terraform fmt -check` and `terraform validate` on `infra/`, with the AWS provider `~> 6.0`: `insecure_value` on the `aws_ssm_parameter` data source and the `aws_vpc_security_group_*_rule` resources are the newest pieces.
- That the `AWS/Bedrock` `OutputTokenCount` metric for a call through an inference profile carries `ModelId` = the profile ID. If the alarm's graph stays empty while you send requests, look at the metric's actual dimensions in the CloudWatch console and change `dimensions` to match.
- That Nova Micro and Titan Text Embeddings V2 are callable in your account and region with no access request, and that `get-inference-profile` lists the three US regions in `bedrock_routed_regions`.
- The image sizes (~350 MB Python, ~260 MB C#), memory under load, and time to healthy on 512 CPU / 1024 MB; and that the `--no-install-package` list still covers PyTorch's companions in your lock file.
- SSO or `aws login` credentials inside each container: `botocore[crt]` for Python; `AWSSDK.SSO` and `AWSSDK.SSOOIDC` for C# (the newer `aws login` provider may need another SDK package).
- A Graviton deploy: the C# build stage on `$BUILDPLATFORM` and the Python image under emulation, both producing an image that starts on `ARM64`.

Next: [13 — Cost, scaling & security](13-cost-scaling-and-security.md).
