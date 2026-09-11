# 12 — Deploying to AWS

> **Background.** You're a senior/staff-level .NET engineer becoming an AI engineer. These docs assume you're excellent at software engineering — architecture, testing, CI/CD, containers, IaC, cloud — and won't re-teach that. They teach the AI-specific layer on top, using analogies to what you already know. Math stays light and just-in-time. The method is **learn by building**: real, checked-in projects, developed **locally in Docker** and then moved to **AWS as pretend production**. Python is the default language; Python-isms are flagged.

## Where this fits

You have a working, observable, guarded AI system: RAG ([07](07-retrieval-augmented-generation.md)) or an agent ([08](08-agents-and-orchestration.md)), measured by evals ([09](09-evaluation-and-testing.md)), servable locally ([10](10-serving-and-inference-local.md)), instrumented and guardrailed ([11](11-observability-and-guardrails.md)). Now you ship it to AWS as **pretend production**.

You already know CI/CD, containers, and IaC conceptually — this module won't teach Docker or Terraform basics. It teaches the **AI-specific deployment decisions**: which compute target fits an LLM workload, how to use **Bedrock** as a managed model backend, and how the pieces (ECR, ECS Fargate, ALB, secrets, IaC, a pipeline) fit for a service whose "business logic" is model calls.

Unlike earlier modules, **this doc's build project *is* the AWS move.** You deploy a real service. The single most important instruction: **set a budget alarm *before* you deploy anything.**

After this module you'll be able to:

- Pick a deployment target (Lambda / ECS Fargate / EKS / EC2-GPU) for a given AI workload and defend it.
- Use Bedrock as your model backend, authenticated via IAM, with the generic invoke/converse pattern.
- Containerize the FastAPI service, push to ECR, run it on ECS Fargate behind an ALB.
- Keep secrets out of the image (SSM Parameter Store / Secrets Manager).
- Express the infrastructure as code (CDK or Terraform) and deploy it from a pipeline.
- Keep local Docker and cloud in parity.

## Deployment target choices for AI apps

Most AI apps are just **web services that call a model** — so the usual compute-target reasoning applies, with one twist: **latency is dominated by the model call (often seconds), not your code.** That reshapes the trade-offs.

- **AWS Lambda** — spiky, light, event-driven work. Great for async jobs, webhooks, batch scoring, low-traffic endpoints. Watch two things for LLMs: the **request/timeout ceiling** (long streaming generations can bump it — API Gateway and Lambda both cap duration) and **cold starts** (a cold container plus a multi-second model call makes a slow first request). Scales to zero — cheapest when idle.
- **ECS Fargate** — always-on, containerized HTTP services. **The default for a chat/RAG API.** Serverless containers (no EC2 to manage), autoscaling, plays nicely with an ALB and streaming. This is where our build project lands.
- **EKS** — Fargate's power without the ceiling, for teams already on Kubernetes or needing fine-grained scheduling (including GPUs). More ops; choose it when you already run k8s.
- **EC2 GPU** (`g`/`p` families) — only when you're **self-hosting the model** ([10](10-serving-and-inference-local.md)). If your model lives in Bedrock or a hosted API, you do **not** need a GPU — your service is CPU-bound glue. Don't provision GPUs to run an app that just calls Bedrock; it's the most common (and expensive) misconfiguration.

The rule of thumb: **always-on API → Fargate; spiky/async → Lambda; self-hosting the model → EC2-GPU/EKS.** For this module we use Fargate with Bedrock as the backend, so there's no GPU in sight.

## Bedrock as the model backend

Amazon **Bedrock** is AWS's managed, per-token model service (introduced in [10](10-serving-and-inference-local.md)). It's the natural cloud backend because it removes the two hardest parts of self-hosting — GPUs and scaling — and authenticates the way the rest of your AWS stack already does.

- **Auth via IAM, not API keys.** This is the mental shift from the hosted APIs in [04](04-calling-models-apis-sdks.md). Your Fargate **task role** gets an IAM policy granting `bedrock:InvokeModel` (least privilege — module [13](13-cost-scaling-and-security.md)), and the AWS SDK signs requests automatically. No API key to store or rotate. This is a genuine operational win.
- **The invoke/converse pattern.** Bedrock exposes model calls through the `bedrock-runtime` client. The **`Converse`** API is the newer, model-agnostic one: a uniform request/response shape (messages, roles, inference config) across model families, so your code doesn't hardcode a provider's JSON dialect — the same "program against the interface" instinct as the OpenAI-compatible gateway in [10](10-serving-and-inference-local.md). (There's also a lower-level `InvokeModel` where you build the model-specific body yourself. Prefer `Converse` for portability.)
- **Region and model availability vary and change.** Which models exist, and in which regions, shifts constantly, and many require a one-time **model access request** in the console. **Check the current Bedrock docs** for available model IDs and regions — don't hardcode assumptions or trust a model ID from a blog post. Don't paste specific ARNs from memory either; look them up.

Illustrative `Converse` call (shape is directional — verify parameter names against the current SDK docs):

```python
"""Illustrative Bedrock Converse call. Verify model IDs, region, and param
names against CURRENT AWS docs — these change. IAM (task role) supplies auth."""
import boto3

# region and model id are illustrative — check current Bedrock availability
client = boto3.client("bedrock-runtime", region_name="us-east-1")

resp = client.converse(
    modelId="<check-current-bedrock-model-id>",
    messages=[{"role": "user", "content": [{"text": "Explain a b-tree in one sentence."}]}],
    inferenceConfig={"maxTokens": 256, "temperature": 0.2},
)
text = resp["output"]["message"]["content"][0]["text"]
```

Because you kept the app behind a clean client interface ([04](04-calling-models-apis-sdks.md), [10](10-serving-and-inference-local.md)), swapping your local Ollama/OpenAI client for a Bedrock-backed one is a **single adapter class**, not an app rewrite.

## Containerizing → ECR → ECS Fargate behind an ALB

The shape you already know from any containerized service; here's the AI-flavored walkthrough.

1. **Reuse the Dockerfile** from the earlier module (10/11). Same image, now built for `linux/amd64` (or `arm64` for Fargate Graviton — cheaper). Keep it slim; the model doesn't live in the image (it's Bedrock).
2. **Push to ECR** (Elastic Container Registry) — AWS's private Docker registry. `docker build` → `docker tag` → `aws ecr get-login-password | docker login` → `docker push`.
3. **ECS Fargate service** runs N tasks from that image. The **task definition** declares CPU/memory, the image, env vars, the **task role** (with the Bedrock policy), and log config (→ CloudWatch, module [11](11-observability-and-guardrails.md)).
4. **ALB** (Application Load Balancer) in front, health-checking `/health`, routing to tasks. Fargate service autoscaling adds/removes tasks on CPU or request-count targets.

Since your service is CPU-light and latency is dominated by the Bedrock call, autoscale on **request count / concurrency**, not just CPU — a task waiting on a model response barely moves the CPU needle ([13](13-cost-scaling-and-security.md) goes deeper on scaling and backpressure).

## Secrets — never in the image

Same rule as always, stated because people still bake keys into images: **no secrets in the Dockerfile, image layers, or committed env files.**

- **SSM Parameter Store** — cheap/free for config and secrets (`SecureString`). Good default for most values.
- **Secrets Manager** — richer (rotation, cross-account); use it for things that must rotate (DB creds, third-party API keys if any).
- ECS injects these into the task as environment variables via the task definition's `secrets` block, resolved at launch from the parameter's ARN. The **task role** needs read permission on exactly those parameters (least privilege).

With Bedrock you often have **no model API key at all** — IAM *is* the auth — which is one fewer secret to leak. Any remaining secrets (a vector DB URL, a third-party key) go in Parameter Store.

## Infrastructure as code — pick one

Define everything above as code so it's reviewable, repeatable, and destroyable. Two reasonable choices:

- **AWS CDK** — infrastructure in a real programming language (TypeScript/Python/**C#**). For a .NET engineer this is the comfortable path: you can author CDK in **C#**, get types and IntelliSense, and treat infra like the application code you already write. Higher-level "constructs" collapse a Fargate-behind-ALB stack into a few lines. Downside: AWS-only, and it compiles down to CloudFormation (occasionally leaky).
- **Terraform** — declarative HCL, cloud-agnostic, enormous ecosystem, the industry portability standard. Downside: another language (HCL), and state management to run.

**Recommendation:** if you want minimal friction and comfort, use **CDK in C#** — it leans on skills you already have and keeps infra close to app code. If you value portability or your org already standardizes on it, use **Terraform**. The build project shows a Terraform skeleton (portable and self-contained to read), and notes the CDK equivalent. Either is fine; the point is *infra as reviewed, versioned code*.

## CI/CD to deploy

GitHub Actions → ECR → ECS is the standard path and mirrors any container pipeline you've built:

1. On push to `main`: run tests **and your [09](09-evaluation-and-testing.md) evals** (quality is a gate, not an afterthought).
2. Build the image, tag with the git SHA, push to ECR.
3. Update the ECS service to the new task definition (rolling deploy; ALB drains old tasks).
4. Auth from Actions to AWS via **OIDC** (a federated role), *not* long-lived access keys in secrets — the modern, keyless CI pattern.

## Env parity between local Docker and cloud

The failure mode is "works in my container, breaks on Fargate." Keep parity by:

- **Same image** locally and in ECR — build once, run everywhere.
- **Config via environment**, injected identically (local `.env` / compose; cloud SSM). The *code* reads the same env var names.
- **The backend adapter is the only real difference.** Locally you might point at Ollama ([10](10-serving-and-inference-local.md)) or OpenAI; in cloud, Bedrock. Select it by env var so the running image is identical. **Run the exact image locally against Bedrock first** (with AWS creds mounted) to catch IAM/permission issues before you deploy.

## The build project

**`projects/12-aws-deploy/`** — Take the [07](07-retrieval-augmented-generation.md) RAG service (or the [08](08-agents-and-orchestration.md) agent), containerize it, and deploy to **ECS Fargate with Bedrock as the model backend**, defined in IaC, with a deploy script. Run the same image locally first. **Set a budget alarm before deploying.**

### Layout

```
projects/12-aws-deploy/
  pyproject.toml
  Dockerfile              # reused from module 10/11
  docker-compose.yml      # run the SAME image locally
  app/
    __init__.py
    main.py               # FastAPI (RAG/agent from 07/08)
    backends/
      bedrock.py          # Bedrock adapter (Converse)
      local.py            # Ollama/OpenAI adapter (module 10)
  infra/                  # Terraform skeleton (illustrative)
    main.tf
    variables.tf
  deploy/
    deploy.sh             # build -> ECR -> ECS
    budget_alarm.md       # DO THIS FIRST
  NOTES.md
```

### `app/backends/bedrock.py` — the adapter

```python
"""Bedrock backend adapter. Same interface as the local backend (module 10),
so the app selects a backend by env var and the image is identical everywhere.
Model IDs / region / params are ILLUSTRATIVE — verify against current AWS docs."""
from __future__ import annotations

import os

import boto3


class BedrockBackend:
    def __init__(self) -> None:
        self._model_id = os.environ["BEDROCK_MODEL_ID"]  # from SSM; check availability
        self._client = boto3.client(
            "bedrock-runtime",
            region_name=os.environ.get("AWS_REGION", "us-east-1"),
        )  # IAM task role supplies credentials — no API key

    def chat(self, prompt: str, max_tokens: int = 512) -> str:
        resp = self._client.converse(
            modelId=self._model_id,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": max_tokens, "temperature": 0.2},
        )
        return resp["output"]["message"]["content"][0]["text"]
```

```python
# app/main.py — backend selected by env var (parity: same image local & cloud)
import os

from fastapi import FastAPI
from pydantic import BaseModel

if os.environ.get("LLM_BACKEND", "local") == "bedrock":
    from .backends.bedrock import BedrockBackend as Backend
else:
    from .backends.local import LocalBackend as Backend

app = FastAPI(title="aws-deploy-rag")
backend = Backend()


class AskRequest(BaseModel):
    question: str


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ask")
def ask(req: AskRequest) -> dict[str, str]:
    # ... your module-07 retrieval builds the grounded prompt ...
    answer = backend.chat(req.question)
    return {"answer": answer}
```

### `infra/main.tf` — Terraform skeleton (illustrative)

```hcl
# ILLUSTRATIVE Terraform skeleton — trimmed for readability. A real stack needs
# a VPC, subnets, security groups, and full ALB listener/target-group wiring.
# Verify resource arguments against the current AWS provider docs.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
provider "aws" {
  region = var.region
}

# --- ECR: the private image registry ---
resource "aws_ecr_repository" "app" {
  name = "${var.name}-repo"
}

# --- IAM task role: LEAST PRIVILEGE — only Bedrock invoke (module 13) ---
resource "aws_iam_role" "task" {
  name               = "${var.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy" "bedrock" {
  role   = aws_iam_role.task.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["bedrock:InvokeModel", "bedrock:Converse"],
      Resource = "*" # scope to specific model ARNs in real use — look them up, don't guess
    }]
  })
}

# --- ECS Fargate service behind an ALB (details elided) ---
resource "aws_ecs_cluster" "this" { name = "${var.name}-cluster" }

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"   # CPU-light: latency is the Bedrock call, not us
  memory                   = "1024"
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions = jsonencode([{
    name  = var.name
    image = "${aws_ecr_repository.app.repository_url}:latest"
    portMappings = [{ containerPort = 8000 }]
    environment = [
      { name = "LLM_BACKEND", value = "bedrock" }
    ]
    # secrets pulled from SSM at launch — never baked into the image:
    secrets = [
      { name = "BEDROCK_MODEL_ID", valueFrom = var.bedrock_model_id_param_arn }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.name}"   # -> CloudWatch (module 11)
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

# aws_ecs_service, aws_lb, aws_lb_target_group, aws_lb_listener, autoscaling: elided.
```

> **CDK equivalent (for the .NET dev):** the same stack in C# CDK uses higher-level constructs — roughly `new ApplicationLoadBalancedFargateService(this, "Svc", ...)` collapses the ALB + service + task-def wiring into one construct, and you add the Bedrock policy to `taskRole` with typed `PolicyStatement`s. If you're more comfortable in C# than HCL, author it there.

### `deploy/deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
# --- Prereq: you ran deploy/budget_alarm.md FIRST. ---
: "${AWS_REGION:?set AWS_REGION}"; : "${ECR_REPO:?set ECR_REPO}"
SHA=$(git rev-parse --short HEAD)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ECR_REPO%/*}"

docker build -t "$ECR_REPO:$SHA" -t "$ECR_REPO:latest" .
docker push "$ECR_REPO:$SHA"
docker push "$ECR_REPO:latest"

# roll the ECS service to the new image (rolling deploy; ALB drains old tasks)
aws ecs update-service --cluster "${NAME}-cluster" --service "${NAME}-svc" \
  --force-new-deployment --region "$AWS_REGION"
```

### `deploy/budget_alarm.md` — DO THIS FIRST

> **Before you deploy anything**, create an **AWS Budget** with an alarm (e.g. an email/SNS notification at 50%/80%/100% of a small monthly cap like $20). Bedrock is per-token so a bug that loops an agent, or a leaked endpoint, runs up a bill silently — there's no crash to stop it. The budget alarm is your smoke detector. Module [13](13-cost-scaling-and-security.md) covers cost control in depth; the alarm is the non-negotiable first step. Set it in the Billing console or as an `aws_budgets_budget` Terraform resource.

### Run the same image locally first

```bash
cd projects/12-aws-deploy
# 1) local backend (no AWS): identical image, LLM_BACKEND=local
docker compose up --build
curl -s localhost:8000/ask -d '{"question":"summarize the onboarding doc"}' \
  -H 'content-type: application/json' | jq

# 2) SAME image against Bedrock, locally — catches IAM issues before deploy
docker run --rm -p 8000:8000 \
  -e LLM_BACKEND=bedrock -e AWS_REGION -e BEDROCK_MODEL_ID \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  <your-image>
```

### Deploy to AWS

```bash
# after budget_alarm.md:
cd infra && terraform init && terraform apply    # creates ECR, roles, cluster, ALB...
cd .. && AWS_REGION=... ECR_REPO=... NAME=... ./deploy/deploy.sh
# hit the ALB DNS name /health, then /ask
```

Record in `NOTES.md`: the deploy steps that bit you (IAM policy scope, model access request, region availability are the usual three), and the round-trip latency vs local — Bedrock's model call dominates, exactly as predicted.

### Moving to AWS

This *is* the AWS module — the section above is the move. The higher-order point: **you didn't rearchitect to deploy.** The gateway/adapter seam ([04](04-calling-models-apis-sdks.md), [10](10-serving-and-inference-local.md)), the guardrails and structured logging ([11](11-observability-and-guardrails.md)), and env-driven config meant "go to prod" was *containerize + IaC + swap the backend adapter + wire logs to CloudWatch*. That's the payoff of the discipline from the earlier modules.

## How experts think / pitfalls

- **Don't provision GPUs to call Bedrock.** If the model is managed (Bedrock/hosted API), your service is CPU-light glue → Fargate/Lambda. GPUs are only for self-hosting the model ([10](10-serving-and-inference-local.md)). This is the most expensive rookie mistake.
- **IAM is the auth, not an API key.** Embrace it — a task role with `bedrock:InvokeModel` means one fewer secret to store and rotate. Scope the policy to specific model ARNs, not `*`, in real use ([13](13-cost-scaling-and-security.md)).
- **Budget alarm before the first deploy. Always.** Per-token billing plus a loop bug equals a silent, unbounded bill. The alarm is the first resource you create.
- **Autoscale on concurrency, not just CPU.** A task blocked on a multi-second Bedrock call barely touches CPU; request-count/concurrency targets reflect real load.
- **Run the exact image against Bedrock locally before deploying.** Catches IAM scoping, model-access-request, and region-availability errors on your laptop instead of in a failed Fargate task.
- **Model IDs and regions drift — look them up.** Never hardcode a model ID or ARN from memory or a blog. Check current Bedrock availability and request model access.
- **Pitfall: secrets in the image.** They persist in layers and ECR forever. Use SSM/Secrets Manager and inject at launch.
- **Pitfall: gating deploys on tests but not evals.** Quality is a release gate ([09](09-evaluation-and-testing.md)); a green unit-test suite can ship a model regression. Run evals in CI.
- **Pitfall: Lambda for long streaming generations.** Duration/timeout ceilings and cold starts bite; use Fargate for always-on streaming APIs.

## Checkpoint

You're ready for [13](13-cost-scaling-and-security.md) if you can:

- Choose Lambda vs Fargate vs EKS vs EC2-GPU for a described AI workload and justify it, including why a Bedrock-backed app needs no GPU.
- Explain Bedrock auth via IAM task roles and the model-agnostic `Converse` pattern, and why you shouldn't hardcode model IDs/regions.
- Walk the containerize → ECR → Fargate-behind-ALB path, and say where secrets live and why never in the image.
- State a reason to pick CDK-in-C# vs Terraform for your situation.
- Describe a GitHub Actions → ECR → ECS pipeline that gates on evals and authenticates via OIDC.
- Explain how you keep local Docker and cloud in parity, and **why the budget alarm comes first.**

## Going deeper

- **Amazon Bedrock** docs — the `Converse`/`InvokeModel` APIs, current model IDs, regions, and how to request model access.
- **Amazon ECS / Fargate** and **Application Load Balancer** docs — task definitions, service autoscaling, health checks.
- **AWS CDK** (Python or C#) and **Terraform AWS provider** docs — pick your IaC and read its Fargate/ALB constructs.
- **SSM Parameter Store** and **Secrets Manager** docs — the two secret stores and when to use each.
- AWS's **GitHub Actions OIDC** guidance — keyless CI auth to AWS.
- **AWS Budgets** — set the alarm (revisited in [13](13-cost-scaling-and-security.md)).

Next: [13 — Cost, scaling & security](13-cost-scaling-and-security.md).
