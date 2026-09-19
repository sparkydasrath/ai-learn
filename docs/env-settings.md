# Environment Settings

## Workspace project switch

```powershell
# For project 02
$env:AI_LEARN_PROJECT = "02-landscape-map"
code .

# For project 03
$env:AI_LEARN_PROJECT = "03-llm-fundamentals"
code .
```

## Standard AWS credentials pattern for Docker (recommended)

Use AWS profiles + mount your local `.aws` folder into the container.
Do not bake credentials into the image.

### 1) Configure credentials on host

One-time setup (access keys):

```powershell
aws configure --profile my-profile
```

Or if your org uses SSO:

```powershell
aws configure sso --profile my-profile
aws sso login --profile my-profile
```

### 2) Run Docker with mounted AWS config

```powershell
docker run --rm `
  -v $env:USERPROFILE\.aws:/root/.aws:ro `
  -e AWS_PROFILE=learn-profile `
  -e AWS_REGION=us-east-1 `
  -e BEDROCK_MODEL_ID="amazon.nova-micro-v1:0" `
  hello-model
```

### 2a) If Bedrock requires an inference profile

Some models cannot be invoked with on-demand throughput using the base model ID.
If you see a ValidationException that asks for an inference profile, create an
application inference profile and use its ID or ARN as `BEDROCK_MODEL_ID`.

1. List system-defined inference profiles and find one that includes your model:

```powershell
aws bedrock list-inference-profiles `
  --type-equals SYSTEM_DEFINED `
  --region us-east-1 `
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic.claude-sonnet-4-5')].[inferenceProfileId,inferenceProfileArn]" `
  --output table
```

2. Create your application inference profile from that source profile ARN:

```powershell
aws bedrock create-inference-profile `
  --region us-east-1 `
  --inference-profile-name claude-sonnet-45-app `
  --description "App profile for Claude Sonnet 4.5" `
  --model-source copyFrom="<SYSTEM_DEFINED_PROFILE_ARN>"
```

3. Save the returned `inferenceProfileArn` (or `inferenceProfileId`).

4. Run Docker again, but pass the inference profile instead of the base model ID:

```powershell
docker run --rm `
  -v $env:USERPROFILE\.aws:/root/.aws:ro `
  -e AWS_PROFILE=learn-profile `
  -e AWS_REGION=us-east-1 `
  -e BEDROCK_MODEL_ID="<YOUR_INFERENCE_PROFILE_ID_OR_ARN>" `
  hello-model
```

5. Optional quick verification from host (before Docker):

```powershell
aws bedrock-runtime converse `
  --region us-east-1 `
  --model-id "<YOUR_INFERENCE_PROFILE_ID_OR_ARN>" `
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]'
```

Why this is the default:

- Reuses your normal AWS CLI profile workflow
- Works with short-lived credentials and SSO refresh
- Keeps secrets out of the image and repo

## Alternative: pass env vars directly

Use this only when needed (for CI or short tests):

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY `
  -e AWS_SESSION_TOKEN `
  -e AWS_REGION `
  -e BEDROCK_MODEL_ID `
  hello-model
```

## Quick checks before running

```powershell
# Verify active identity on host
aws sts get-caller-identity --profile my-profile

# If using SSO, refresh when expired
aws sso login --profile my-profile
```

## Common errors and fixes

- `ProfileNotFound`: profile name in `AWS_PROFILE` does not exist in `%USERPROFILE%\.aws\config`
- `ExpiredToken` or auth failures: run `aws sso login --profile my-profile` again
- `MissingDependencyException ... botocore[crt]`: ensure dependency includes `botocore[crt]`
- Bedrock access denied: request model access in AWS console and confirm IAM permissions for Bedrock invoke
