"""Smoke test: prove our credentials can reach a hosted model.

Real model-calling patterns (streaming, retries, cost accounting) are module 04.
This just confirms the pipe is connected.
"""

from __future__ import annotations

import os
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

def main() -> int:
    # Model IDs change; check the current Bedrock model catalog.

    model_id = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-micro-v1:0")
    region = os.environ.get("AWS_REGION","us-east-1")
    client = boto3.client(
        "bedrock-runtime", 
        region_name=region,
        config=Config(
            retries={"max_attempts":8, "mode": "adaptive"}, # tell boto3 to retry automatically with adaptive backoff
            read_timeout=20,
            connect_timeout=5
        ))

    try:
        # Bedrock's "Converse" API gives one consistent shape across model families.
        response = client.converse(
            modelId=model_id,
            messages=[
                {
                    "role": "user", "content":
                    [{"text": "Say hello in one short sentence"}]
                }
            ],
            inferenceConfig={"maxTokens": 64, "temperature": 0.0}
        )
    except ClientError as err:
        code = err.response.get("Error", {}).get("Code", "Unknown")
        message = err.response.get("Error", {}).get("Message", str(err))

        if code == "ThrottlingException":
            # Rate limiting, not a spend/access problem. You exceeded this
            # account's per-minute requests (RPM) or tokens (TPM) quota for
            # this model in this region. The adaptive retries above already
            # back off and retry; still seeing this means the quota is too low.
            print("Bedrock throttled this call (per-minute RPM/TPM quota exceeded).",
            file=sys.stderr)
            print(f"Model: {model_id}", file=sys.stderr)
            print(f"Region: {region}", file=sys.stderr)
            print(
                "Fixes: prefer us-east-1 (highest default limits), or request a "
                "quota increase in the Service Quotas console -> Amazon Bedrock -> "
                "'On-demand model inference requests per minute for <model>'.",
                file=sys.stderr,
            )
            return 2

        print(f"Bedrock call failed: {code} - {message}", file=sys.stderr)
        return 1

    text = response["output"]["message"]["content"][0]["text"]
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())