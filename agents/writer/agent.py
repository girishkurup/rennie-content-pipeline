"""Writer agent — Bedrock AgentCore entrypoint.

Drafts content from a brief. Wrapped in BedrockAgentCoreApp so the same code
runs both as a local dev server (`agentcore dev` / `python agent.py`) and as
the container deployed to Bedrock AgentCore Runtime by
terraform/modules/agentcore_runtime.

Model id and region come from environment variables so the same image can be
reused across environments (dev/staging/prod) purely via Terraform-set env
vars, without rebuilding.
"""

import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from botocore.config import Config as BotocoreConfig
from strands import Agent
from strands.models import BedrockModel

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Under concurrent load across the three agents, on-demand Bedrock throttling
# is routine, not exceptional (seen in practice: ConverseStream throttled
# after exhausting botocore's default 4 retries, crashing the whole
# invocation with an uncaught ModelThrottledException). "adaptive" mode backs
# off based on observed throttling rather than a fixed schedule, and more
# attempts gives it room to actually wait it out instead of giving up.
_BEDROCK_RETRY_CONFIG = BotocoreConfig(retries={"max_attempts": 8, "mode": "adaptive"})

SYSTEM_PROMPT = """You are the Writer agent in a content production pipeline.

Given a brief, draft clear, well-structured content that matches the brief's \
intent, tone, and length. You do not review, approve, or critique your own \
work — a separate Reviewer agent handles that. If a previous draft and \
reviewer feedback are included in the request, revise the draft to address \
that feedback rather than starting over from scratch."""

app = BedrockAgentCoreApp()

# Model config is stateless and safe to share across requests. The Agent
# itself is NOT — it accumulates conversation history — so a fresh one is
# built per invocation below rather than reused as a module-level global.
# Otherwise one caller's history would leak into the next caller's context on
# this long-running server.
model = BedrockModel(region_name=AWS_REGION, model_id=MODEL_ID, boto_client_config=_BEDROCK_RETRY_CONFIG)


@app.entrypoint
def invoke(payload: dict) -> dict:
    """Main entrypoint. `payload` is the JSON body sent to the runtime.

    Expected shape: {"prompt": "<brief, optionally with prior draft + feedback>"}
    """
    prompt = payload.get("prompt", "")
    if not prompt:
        return {"error": "Missing 'prompt' in request payload."}

    agent = Agent(model=model, system_prompt=SYSTEM_PROMPT)
    result = agent(prompt)
    return {"result": str(result)}


if __name__ == "__main__":
    app.run()
