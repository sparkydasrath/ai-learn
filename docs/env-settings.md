# Environment settings

Per-machine setup that isn't part of any one project. Commands are PowerShell 7 ([shell conventions](conventions.md#shell-commands)).

## The active project

Both bootstrap scripts set `AI_LEARN_PROJECT` (for the current process and, persistently, for your Windows user) to the project they just created. Nothing in the repo reads it. It's a marker for your own prompt, shell aliases or tasks, if you want "the project I'm on" available everywhere. To switch it by hand:

```powershell
$env:AI_LEARN_PROJECT = "03-token-lab"
code .
```

## AWS credentials for Docker (from module 12)

Use an AWS CLI profile and mount your local `.aws` folder into the container, read-only. Don't bake credentials into the image. These docs use one profile name throughout, `ai-learn`.

### 1) Configure the profile on the host

With access keys:

```powershell
aws configure --profile ai-learn
```

Or, if your org uses IAM Identity Center (SSO):

```powershell
aws configure sso --profile ai-learn
aws sso login --profile ai-learn
```

Check it works:

```powershell
aws sts get-caller-identity --profile ai-learn
```

### 2) Run a container with the mounted config

```powershell
docker run --rm `
  -v "${env:USERPROFILE}\.aws:/root/.aws:ro" `
  -e AWS_PROFILE=ai-learn `
  -e AWS_REGION=us-east-1 `
  -e LLM_BACKEND=bedrock `
  -e BEDROCK_MODEL_ID="amazon.nova-micro-v1:0" `
  <image>
```

`/root/.aws` is right for images that run as root (the Python images). The C# images run as the non-root `app` user (`USER $APP_UID`), whose home is `/home/app`, so mount at `/home/app/.aws` instead:

```powershell
docker run --rm `
  -v "${env:USERPROFILE}\.aws:/home/app/.aws:ro" `
  -e AWS_PROFILE=ai-learn -e AWS_REGION=us-east-1 `
  -e LLM_BACKEND=bedrock -e BEDROCK_MODEL_ID="amazon.nova-micro-v1:0" `
  <image>
```

Why this is the default:

- It reuses your normal AWS CLI profile workflow.
- It works with short-lived credentials and SSO refresh.
- It keeps secrets out of the image and the repo.

### 2a) If Bedrock asks for an inference profile

Many newer models can't be invoked on demand by their base model ID. If you get a `ValidationException` that mentions an inference profile, use a **system-defined cross-region inference profile**: its ID is the model ID with a geography prefix, such as `us.`. Find one that includes your model:

```powershell
aws bedrock list-inference-profiles `
  --type-equals SYSTEM_DEFINED `
  --region us-east-1 `
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic.claude')].[inferenceProfileId,inferenceProfileArn]" `
  --output table
```

Pass the `inferenceProfileId` as `BEDROCK_MODEL_ID`. IAM permissions for an inference profile need both the profile's ARN and the foundation-model ARNs in every region it routes to; module 12 shows the policy.

Optionally, create an **application inference profile** from that system profile, to tag and track your own usage separately:

```powershell
aws bedrock create-inference-profile `
  --region us-east-1 `
  --inference-profile-name ai-learn-claude `
  --model-source copyFrom="<SYSTEM_DEFINED_PROFILE_ARN>"
```

Quick check from the host before involving Docker:

```powershell
aws bedrock-runtime converse `
  --profile ai-learn --region us-east-1 `
  --model-id "<MODEL_OR_INFERENCE_PROFILE_ID>" `
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]'
```

## Alternative: pass credentials as env vars

Use this only when you need to, such as in CI or for a quick test. The values come from your current shell:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN `
  -e AWS_REGION -e LLM_BACKEND=bedrock -e BEDROCK_MODEL_ID `
  <image>
```

## Common errors and fixes

- `ProfileNotFound`: the name in `AWS_PROFILE` isn't in `%USERPROFILE%\.aws\config`, or the mount path doesn't match the container user's home (see above).
- `ExpiredToken` or other auth failures: run `aws sso login --profile ai-learn` again.
- `MissingDependencyException ... botocore[crt]`: SSO credentials need `botocore[crt]`. Add it with `uv add "botocore[crt]"`.
- Bedrock `AccessDeniedException`: check the IAM policy covers the model (or inference-profile) ARN, and that model access is enabled for your account in the Bedrock console.
