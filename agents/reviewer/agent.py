"""Reviewer agent — Bedrock AgentCore entrypoint.

Critiques a Writer draft against its brief and returns a structured
approve/reject decision with actionable feedback, so the Orchestrator can
drive a Writer<->Reviewer loop programmatically without parsing free text.
"""

import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from botocore.config import Config as BotocoreConfig
from pydantic import BaseModel, Field
from strands import Agent
from strands.models import BedrockModel

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# See matching comment in agents/writer/agent.py — this agent crashed with an
# uncaught ModelThrottledException in practice (500 back to the Orchestrator)
# after botocore's default 4 retries were exhausted under concurrent load.
_BEDROCK_RETRY_CONFIG = BotocoreConfig(retries={"max_attempts": 8, "mode": "adaptive"})

SYSTEM_PROMPT = """You are the Reviewer agent in a content production pipeline.

Given a brief and a Writer agent's draft, critique the draft against the \
brief: accuracy, tone, structure, and completeness. Decide whether it's \
ready to ship as-is. Be specific and actionable in your feedback so the \
Writer can revise effectively — vague notes like "make it better" are not \
useful. If the draft is genuinely good, approve it rather than inventing \
nitpicks."""


class ReviewDecision(BaseModel):
    approved: bool = Field(description="True if the draft is ready to ship as-is.")
    feedback: str = Field(
        description="Specific, actionable feedback for the Writer to address. "
        "Empty string if approved with nothing further to add."
    )


app = BedrockAgentCoreApp()

# Model config is stateless and safe to share; a fresh Agent is built per
# invocation below since Agent instances accumulate conversation history and
# this process serves many independent requests over its lifetime.
model = BedrockModel(region_name=AWS_REGION, model_id=MODEL_ID, boto_client_config=_BEDROCK_RETRY_CONFIG)


@app.entrypoint
def invoke(payload: dict) -> dict:
    """Main entrypoint. Expected payload shape: {"brief": "...", "draft": "..."}"""
    brief = payload.get("brief", "")
    draft = payload.get("draft", "")
    if not draft:
        return {"error": "Missing 'draft' in request payload."}

    agent = Agent(model=model, system_prompt=SYSTEM_PROMPT)
    prompt = f"Brief:\n{brief}\n\nDraft to review:\n{draft}"
    decision = agent.structured_output(ReviewDecision, prompt)
    return {"approved": decision.approved, "feedback": decision.feedback}


if __name__ == "__main__":
    app.run()
