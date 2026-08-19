# Engineering guide

Day-to-day workflow for working on this codebase — local dev, how to
redeploy after each kind of change, and the debugging playbook this
project's own real production bugs were actually root-caused with. For
deploying to a new AWS account, see [`deployment.md`](deployment.md)
instead.

## Local development

**Agents** (`agents/*/agent.py`) run standalone for quick iteration, outside
a container:

```bash
python -m venv .venv && source .venv/Scripts/activate   # Windows Git Bash
pip install -r agents/writer/requirements.txt            # per agent
cd agents/writer && python agent.py                      # starts a local dev server
```

The Orchestrator needs `WRITER_RUNTIME_ARN` / `REVIEWER_RUNTIME_ARN` env
vars set to real deployed runtimes to actually coordinate anything locally —
there's no local stand-in for Writer/Reviewer, so Orchestrator-only local
runs are mostly useful for checking it starts cleanly, not full loops.

**Frontend** (`frontend/`):

```bash
cd frontend && npm install && npm run dev
```

`frontend/.env.development` points at the **live deployed backend**, not a
local one — there's no local API/Lambda emulation in this repo. Frontend
local dev means a local UI talking to real deployed AWS infra.

**Lambdas** (`lambdas/*/handler.py`) have no local emulator set up either
(no SAM local, no LocalStack). The fastest real feedback loop is: edit ->
`terraform apply` (redeploys in seconds, Terraform hashes the zip and only
touches what changed) -> exercise it via `curl` or the frontend -> check
CloudWatch logs. See the debugging playbook below.

## Making a change

| You changed... | Redeploy with |
|---|---|
| `agents/*/agent.py`, `Dockerfile`, `requirements.txt` | `./scripts/deploy_agents.sh` (bumps `agent_image_tag` for you), then `terraform apply -var-file=dev.tfvars` in `terraform/envs/dev` |
| `lambdas/*/handler.py` | `terraform apply -var-file=dev.tfvars` — no build step, `data.archive_file` zips and hashes it automatically |
| Any `.tf` file | `terraform apply -var-file=dev.tfvars` |
| `frontend/src/**` | `npm run build` in `frontend/`, then `terraform apply` (uploads `frontend/dist` via `fileset()`), then invalidate CloudFront (see below) |

```bash
aws cloudfront create-invalidation \
  --distribution-id "$(cd terraform/envs/dev && terraform output -raw cloudfront_distribution_id)" \
  --paths "/*"
```

**One thing to know:** `agent_image_tag` in `dev.tfvars` applies to *all
three* agents at once (one shared Terraform variable). If you only changed
the Orchestrator, `deploy_agents.sh` still rebuilds and re-pushes Writer and
Reviewer under the new tag too (fast — Docker layer caching means an
unchanged agent's build is just a cache hit and a manifest push, a few
seconds).

## Debugging playbook

This is the actual sequence that root-caused every real production bug this
project has hit — verify against live AWS state, don't guess from symptoms.

**1. Check the job's own record first.**

```bash
aws dynamodb get-item --table-name <project>-<env>-content-jobs \
  --key '{"job_id":{"S":"<job_id>"}}'
```

`status` and `current_step` tell you where it is. If `status: failed`, the
`final_draft` field usually names which Lambda to check next.

**2. Check the Step Functions execution — this is usually where the real
error lives.**

```bash
aws stepfunctions describe-execution --execution-arn <execution_arn>
aws stepfunctions get-execution-history --execution-arn <execution_arn> --max-results 100 \
  | grep -B2 -A20 -i "fail\|timeout\|error"
```

`execution_arn` is on the job's DynamoDB record. This has caught both real
bugs this project hit: a `Sandbox.Timedout` (Lambda's own timeout) and a
`ReadTimeoutError` (botocore's client-side timeout, a different failure
mode with a very similar symptom — don't assume they're the same bug just
because the job also ended up `failed`).

**3. Check the Lambda's own CloudWatch logs.**

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/<function-name>" \
  --start-time <epoch_ms> --end-time <epoch_ms>
```

On Windows Git Bash, prefix with `MSYS_NO_PATHCONV=1` — Git Bash silently
mangles the leading `/` in log group names otherwise and you'll get a
confusing `InvalidParameterException`.

**4. Check the AgentCore Runtime's own logs** — separate log group per
agent, *not* the Lambda that called it:

```bash
aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock-agentcore"
aws logs filter-log-events --log-group-name "/aws/bedrock-agentcore/runtimes/<agent>-<id>-DEFAULT" \
  --start-time <epoch_ms> --end-time <epoch_ms>
```

Heads up: this log group is shared across *all* invocations of that agent —
if there's concurrent traffic, you'll see interleaved logs from unrelated
jobs in the same stream. Match on the timestamps/session IDs your job's
execution history gave you in step 2, don't assume every line in the window
belongs to the job you're debugging.

**5. Get a test JWT to hit the API directly**, bypassing the browser:

```bash
aws cognito-idp admin-initiate-auth \
  --user-pool-id <pool_id> --client-id <client_id> \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=<user>,PASSWORD='<password>' \
  --query "AuthenticationResult.IdToken" --output text
```

Requires `ALLOW_ADMIN_USER_PASSWORD_AUTH` on the app client (already set,
`terraform/modules/auth/main.tf`) — the SPA itself only uses SRP, this is
additive for exactly this kind of CLI testing. Then:

```bash
curl -s -X POST "$API_ENDPOINT/chat" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"message": "<brief>"}'

curl -s "$API_ENDPOINT/jobs/<job_id>" -H "Authorization: Bearer $TOKEN"

curl -s -X POST "$API_ENDPOINT/jobs/<job_id>/review" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"approved": true, "feedback": ""}'
```

This is the fastest way to verify a fix actually reaches `pending_human_review`
and completes, without needing to click through the UI.

## Known gotchas (things that have actually cost real debugging time)

- **AgentCore `InvokeAgentRuntime` needs two policies, not one.** An
  identity-based policy on the *caller's* role (targeting both the bare
  runtime ARN and its `/runtime-endpoint/*` sub-resource) **and** a
  resource-based policy on the *target* runtime naming the caller's role as
  an allowed principal. Missing either one gives an opaque
  `AccessDeniedException`. See `terraform/modules/agentcore_runtime/iam.tf`
  and `resource_policy.tf`.
- **Resource policy statements take exactly one principal and one resource
  each.** Unlike normal IAM policies, `aws_bedrockagentcore_resource_policy`
  rejects a statement with a list of principals (`ValidationException:
  Invalid principal in policy`) or a resource list including the
  `/runtime-endpoint/*` variant (`must contain exactly one resource ARN`).
  One `dynamic "statement"` block per caller role, bare runtime ARN only —
  see the comments in `resource_policy.tf`.
- **`boto3`'s default `read_timeout` (60s) is too short for
  `invoke_agent_runtime`.** It's a synchronous, non-streaming call — zero
  bytes back until the entire agent turn finishes, which routinely takes
  150-300s+ for the Orchestrator's full draft/review loop. Every caller of
  this API needs an explicit `Config(read_timeout=...)` well above that, or
  every real call fails client-side long before the agent (or the Lambda's
  own timeout) ever gets a chance. This was a real, silent, 100%-failure-rate
  production bug — see the comments in `lambdas/pipeline_task_writer/
  handler.py` and `agents/orchestrator/agent.py`.
- **Bedrock throttling under concurrent load is routine, not exceptional.**
  Multiple jobs running at once will hit `ModelThrottledException`, and an
  uncaught one crashes the whole Runtime invocation (500 back to the
  caller). Every `BedrockModel` and `bedrock-agentcore` client in this repo
  uses `Config(retries={"max_attempts": 8, "mode": "adaptive"})` for this
  reason — don't strip it out for a "simpler" client construction.
- **AgentCore Runtime requires `linux/arm64` images.** `docker build`
  without `--platform linux/arm64 buildx` on an x86 machine produces an
  image the Runtime will reject. Always `docker buildx build --platform
  linux/arm64 ... --push`.
- **Windows + Git Bash + AWS CLI path handling.** Any AWS CLI argument
  starting with `/` (log group names, S3 keys passed directly rather than
  via `--payload fileb://`) gets silently mangled by Git Bash's POSIX-path
  auto-conversion. Prefix with `MSYS_NO_PATHCONV=1`, or convert with
  `cygpath -w` first for file paths passed to `fileb://`.
- **First deploy to a fresh account is a two-step `apply`.** The
  `aws_bedrockagentcore_agent_runtime` resource validates that its image
  tag already exists in ECR *at apply time* — the ECR repos have to exist
  (and have an image pushed) before the runtime resources can be created.
  See `docs/deployment.md` and the comment at the top of
  `terraform/modules/agentcore_runtime/runtime.tf`.
