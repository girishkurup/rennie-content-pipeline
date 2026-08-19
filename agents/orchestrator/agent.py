"""Orchestrator agent — Bedrock AgentCore entrypoint.

Coordinates the Writer and Reviewer agents to turn a content brief into a
draft ready for human review: draft -> review -> (revise -> review)* up to
MAX_AI_REVIEW_ITERATIONS rounds, then hands off regardless of approval status
so a stuck AI loop can't block the pipeline forever (see max_human_review_iterations
in terraform/envs/dev/variables.tf for what happens after handoff).

Talks to the Writer/Reviewer AgentCore Runtimes directly via boto3's
bedrock-agentcore InvokeAgentRuntime, rather than calling their models
in-process — this agent's own model is only used to decide *when* to loop vs.
stop and to summarize the outcome; Writer/Reviewer own their own model calls.

Can also fetch a reference source URL (see fetch_url) and pass the extracted
page text to the Writer as grounding context. No server-side allowlist is
enforced here yet — the frontend's source list (NHS, WHO, Cochrane, etc.) is
a UI convenience, not a security boundary, so this agent can technically
fetch any URL a caller puts in the brief.
"""

import json
import os
import re
import time
import urllib.error
import urllib.request

import boto3
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from botocore.config import Config as BotocoreConfig
from strands import Agent, tool
from strands.models import BedrockModel

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
WRITER_RUNTIME_ARN = os.environ["WRITER_RUNTIME_ARN"]
REVIEWER_RUNTIME_ARN = os.environ["REVIEWER_RUNTIME_ARN"]
MAX_AI_REVIEW_ITERATIONS = int(os.environ.get("MAX_AI_REVIEW_ITERATIONS", "3"))
# Optional: without it, progress updates are skipped (e.g. local/dev runs
# outside the full pipeline) rather than erroring the whole invocation.
CONTENT_JOBS_TABLE = os.environ.get("CONTENT_JOBS_TABLE", "")

app = BedrockAgentCoreApp()

# See matching comment in agents/writer/agent.py — under concurrent load the
# Writer/Reviewer runtimes this agent calls have been seen to crash outright
# (500) on Bedrock throttling. This covers this agent's *own* model calls;
# _invoke_runtime below adds a matching retry for the Writer/Reviewer calls,
# since a 500 from a crashed downstream invocation isn't something the
# downstream agent's own botocore retry config can help with.
_BEDROCK_RETRY_CONFIG = BotocoreConfig(retries={"max_attempts": 8, "mode": "adaptive"})

model = BedrockModel(region_name=AWS_REGION, model_id=MODEL_ID, boto_client_config=_BEDROCK_RETRY_CONFIG)
# boto3 clients are safe to share across requests/threads for making calls.
#
# read_timeout matters here for the same reason as pipeline_task_writer's own
# client (see its matching comment): invoke_agent_runtime is a blocking,
# non-streaming call, and botocore's 60s default read_timeout is comfortably
# shorter than a Writer/Reviewer call can legitimately take once their own
# throttling backoff (see their agent.py) kicks in.
_agentcore = boto3.client(
    "bedrock-agentcore",
    region_name=AWS_REGION,
    config=_BEDROCK_RETRY_CONFIG.merge(BotocoreConfig(read_timeout=280, connect_timeout=10)),
)
_jobs_table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(CONTENT_JOBS_TABLE) if CONTENT_JOBS_TABLE else None

_INVOKE_RUNTIME_RETRIES = 2
_INVOKE_RUNTIME_BACKOFF_SECONDS = 5


def _update_progress(job_id: str, step: str) -> None:
    """Best-effort "which agent is working right now" status, polled by the
    frontend so a user watching a job isn't staring at an unchanging
    "queued" for the ~150-300s the AI draft/review loop actually takes.

    Deliberately swallows failures — a DynamoDB hiccup here must never fail
    the actual pipeline run over a cosmetic progress update.
    """
    if not job_id or _jobs_table is None:
        return
    try:
        _jobs_table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET current_step = :step",
            ExpressionAttributeValues={":step": step},
        )
    except Exception as exc:  # noqa: BLE001 - best-effort, see docstring
        print(f"_update_progress failed for job {job_id}: {type(exc).__name__}: {exc}", flush=True)


def _invoke_runtime(runtime_arn: str, payload: dict) -> dict:
    # Catch rather than let propagate: an unhandled exception here would
    # crash the whole agent turn, whereas returning an error string lets the
    # model react sensibly (e.g. surface it and stop, rather than the
    # invocation failing opaquely).
    #
    # A handful of retries with backoff is worth it specifically because the
    # observed failure mode is the *downstream* agent crashing on transient
    # Bedrock throttling (ModelThrottledException -> uncaught -> 500), not a
    # real, persistent problem with the request itself.
    last_error = None
    for attempt in range(1 + _INVOKE_RUNTIME_RETRIES):
        if attempt > 0:
            time.sleep(_INVOKE_RUNTIME_BACKOFF_SECONDS * attempt)
        try:
            response = _agentcore.invoke_agent_runtime(
                agentRuntimeArn=runtime_arn,
                contentType="application/json",
                payload=json.dumps(payload).encode("utf-8"),
            )
            body = response["response"].read()
            return json.loads(body)
        except Exception as exc:  # noqa: BLE001 - intentional catch-all, see comment above
            last_error = exc
            # Logged (not just returned) so it's visible in CloudWatch even
            # if the model paraphrases/drops it in its own final response.
            print(
                f"invoke_agent_runtime failed for {runtime_arn} (attempt {attempt + 1}): "
                f"{type(exc).__name__}: {exc}",
                flush=True,
            )
    return {"_error": f"{type(last_error).__name__}: {last_error}"}


FETCH_MAX_CHARS = 8000


def _extract_text(html: str) -> str:
    """Crude but dependency-free HTML-to-text: drop script/style blocks and
    tags, collapse whitespace. Good enough for the clean, semantic markup
    typical of the reference sites this is aimed at (NHS, WHO, etc.);
    swap for a real parser (e.g. BeautifulSoup) if messier sites show up."""
    html = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", html)
    return re.sub(r"\s+", " ", text).strip()


SYSTEM_PROMPT = f"""You are the Orchestrator agent for a content production pipeline.

Given a content brief, coordinate the Writer and Reviewer agents to produce a
draft ready for human review:
0. If the brief names a reference source URL, call fetch_url on it FIRST.
   Pass whatever it returns as source_context on your first draft_content
   call, so the Writer grounds the draft in that material. If fetch_url
   fails, proceed without it rather than blocking the whole job on one
   unreachable page.
1. Call draft_content to get a first draft.
2. Call review_content to get feedback on it.
3. If not approved, call draft_content again with the previous draft and the
   feedback so the Writer can revise, then call review_content again.
4. Stop as soon as review_content reports approved=true, or once you've used
   up your review rounds (review_content will tell you when you have) —
   whichever comes first. At most {MAX_AI_REVIEW_ITERATIONS} review rounds.

When you stop, respond with the final draft in full, plus one sentence on
whether it was approved or is being handed to human review after exhausting
AI review rounds."""


@app.entrypoint
def invoke(payload: dict) -> dict:
    """Main entrypoint. Expected payload shape: {"brief": "..."}

    Returns structured fields rather than relying on the model's own final
    text response as the source of truth for the draft content — the model's
    reply mixes narration ("Perfect! The draft has been approved...") in with
    the actual article text, which is fine for a human chat transcript but
    not for a UI that needs to show "the initial draft" as a clean document.
    Instead, the draft text is captured directly from the tool calls as they
    happen:
      - initial_draft: the Writer's very first pass, before any review
      - ai_reviewed_draft: the draft as it stood after the AI review loop
        ended (approved, or rounds exhausted) — what's handed to the human
      - approved: whether the Reviewer actually approved it (vs. rounds
        exhausted without approval)
      - summary: the model's own narration, kept only as a human-readable
        log line, not as something downstream code parses
    """
    brief = payload.get("brief", "")
    if not brief:
        return {"error": "Missing 'brief' in request payload."}
    # Optional — pipeline_task_writer passes this so progress updates land on
    # the right job; absent, _update_progress just no-ops (see its docstring).
    job_id = payload.get("job_id", "")

    # All per-invocation state lives in closures, not module globals — avoids
    # cross-request races when this process serves multiple invocations.
    review_rounds = {"count": 0}
    drafts = {"initial": None, "latest": None}
    review_state = {"approved": False}

    @tool
    def fetch_url(url: str) -> str:
        """Fetch a web page's readable text content to use as reference material
        for the Writer agent. Only call this for a URL explicitly given in the
        brief as a reference source — not for URLs you infer or guess at.

        Args:
            url: The URL to fetch.
        """
        _update_progress(job_id, f"Fetching reference source ({url})…")
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0 (compatible; ContentPipelineBot/1.0)"}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310 - user-provided reference URL, by design
                content_type = resp.headers.get("Content-Type", "")
                raw = resp.read()
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            return f"ERROR fetching {url}: {type(exc).__name__}: {exc}"

        if "html" not in content_type and "text" not in content_type:
            return f"ERROR: unsupported content type '{content_type}' for {url}"

        text = _extract_text(raw.decode("utf-8", errors="replace"))
        return text[:FETCH_MAX_CHARS]

    @tool
    def draft_content(previous_draft: str = "", feedback: str = "", source_context: str = "") -> str:
        """Ask the Writer agent to draft, or revise, content for this brief.

        Args:
            previous_draft: The prior draft to revise. Leave empty for a first draft.
            feedback: Reviewer feedback to address. Leave empty for a first draft.
            source_context: Reference material from fetch_url, to ground the
                draft in. Leave empty if no source URL was fetched.
        """
        round_num = review_rounds["count"] + 1
        step = (
            f"Writer agent is drafting (round {round_num} of {MAX_AI_REVIEW_ITERATIONS})…"
            if previous_draft
            else "Writer agent is drafting the first version…"
        )
        _update_progress(job_id, step)

        prompt = brief
        if source_context:
            prompt = f"{prompt}\n\nReference material fetched from the source URL:\n{source_context}"
        if previous_draft:
            prompt = (
                f"{prompt}\n\nPrevious draft:\n{previous_draft}\n\n"
                f"Reviewer feedback to address:\n{feedback}"
            )
        result = _invoke_runtime(WRITER_RUNTIME_ARN, {"prompt": prompt})
        if "_error" in result:
            return f"ERROR calling Writer agent: {result['_error']}"
        draft_text = result.get("result", "")
        if drafts["initial"] is None:
            drafts["initial"] = draft_text
        drafts["latest"] = draft_text
        return draft_text

    @tool
    def review_content(draft: str) -> str:
        """Ask the Reviewer agent to critique a draft against the brief.

        Once the AI review round limit is reached, this stops calling the
        Reviewer and instead reports that the draft should go to human
        review as-is, so the loop terminates.

        Args:
            draft: The draft to review.
        """
        if review_rounds["count"] >= MAX_AI_REVIEW_ITERATIONS:
            return json.dumps(
                {
                    "approved": False,
                    "feedback": (
                        f"Max AI review rounds ({MAX_AI_REVIEW_ITERATIONS}) reached; "
                        "stop looping and hand this draft to human review as-is."
                    ),
                }
            )
        _update_progress(
            job_id, f"Reviewer agent is checking brand/compliance (round {review_rounds['count'] + 1} of {MAX_AI_REVIEW_ITERATIONS})…"
        )
        result = _invoke_runtime(REVIEWER_RUNTIME_ARN, {"brief": brief, "draft": draft})
        if "_error" in result:
            # An infra failure (e.g. Bedrock throttling that outlasted
            # _invoke_runtime's own retries) isn't a real review round — don't
            # burn one of the 3 allowed rounds on it, or a couple of bad-luck
            # throttles alone can exhaust the budget before any real review
            # happens.
            return json.dumps(result)
        review_rounds["count"] += 1
        review_state["approved"] = bool(result.get("approved"))
        return json.dumps(result)

    agent = Agent(model=model, system_prompt=SYSTEM_PROMPT, tools=[fetch_url, draft_content, review_content])
    result = agent(f"Content brief:\n{brief}")
    _update_progress(job_id, "Handing off to human review…")
    return {
        "initial_draft": drafts["initial"],
        "ai_reviewed_draft": drafts["latest"],
        "approved": review_state["approved"],
        "ai_review_rounds": review_rounds["count"],
        "summary": str(result),
    }


if __name__ == "__main__":
    app.run()
