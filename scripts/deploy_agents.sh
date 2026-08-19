#!/usr/bin/env bash
# Builds and pushes all three agent images (writer, reviewer, orchestrator)
# to whatever AWS account/region your active credentials point at, then
# bumps agent_image_tag in dev.tfvars so the next `terraform apply` picks
# them up.
#
# Usage:
#   ./scripts/deploy_agents.sh
#
# Prerequisites:
#   - AWS credentials active for the TARGET account (aws sts get-caller-identity
#     to confirm before running this — it builds/pushes wherever your
#     credentials point, there is no separate account/profile flag).
#   - Docker Desktop running, with buildx (ships with it by default).
#   - The three ECR repos must already exist. First deploy to a fresh
#     account is a two-step apply for exactly this reason — see
#     docs/deployment.md:
#       terraform apply -target=module.writer_agent.aws_ecr_repository.this \
#                        -target=module.reviewer_agent.aws_ecr_repository.this \
#                        -target=module.orchestrator_agent.aws_ecr_repository.this
#     before running this script for the very first time in a new account.
#
# What it does NOT do: run `terraform apply`. Run that yourself afterwards
# so you can review the plan (a new image_tag touches all three
# aws_bedrockagentcore_agent_runtime resources).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/envs/dev"
TFVARS_FILE="$ENV_DIR/dev.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "ERROR: $TFVARS_FILE not found. Point ENV_DIR/TFVARS_FILE at your env if you've renamed it." >&2
  exit 1
fi

get_tfvar() {
  grep -E "^\s*$1\s*=" "$TFVARS_FILE" | head -1 | sed -E 's/^[^=]*=\s*"?([^"]*)"?\s*$/\1/'
}

AWS_REGION="$(get_tfvar aws_region)"
PROJECT_NAME="$(get_tfvar project_name)"
ENVIRONMENT="$(get_tfvar environment)"
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

if [[ -z "$AWS_REGION" || -z "$NAME_PREFIX" ]]; then
  echo "ERROR: could not parse aws_region/project_name/environment out of $TFVARS_FILE" >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="deploy-$(date +%Y%m%d%H%M%S)"

echo "Account:      $ACCOUNT_ID"
echo "Region:       $AWS_REGION"
echo "Name prefix:  $NAME_PREFIX"
echo "Image tag:    $TAG"
echo
read -r -p "Build and push all three agent images to the above account? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

echo "--- ECR login ---"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for AGENT in writer reviewer orchestrator; do
  REPO="${NAME_PREFIX}-${AGENT}"
  IMAGE="${ECR_REGISTRY}/${REPO}:${TAG}"

  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REPO" >/dev/null 2>&1; then
    echo
    echo "ERROR: ECR repo '$REPO' doesn't exist yet." >&2
    echo "Run the targeted apply in the script header comment first, then re-run this script." >&2
    exit 1
  fi

  echo
  echo "--- Building & pushing $AGENT -> $IMAGE ---"
  docker buildx build --platform linux/arm64 -t "$IMAGE" --push "$REPO_ROOT/agents/$AGENT"
done

echo
echo "--- Updating agent_image_tag in $TFVARS_FILE ---"
sed -i -E "s/^(agent_image_tag\s*=\s*)\"[^\"]*\"/\1\"${TAG}\"/" "$TFVARS_FILE"
grep -n "agent_image_tag" "$TFVARS_FILE"

echo
echo "All three images pushed as tag '$TAG'. Now run:"
echo "  cd terraform/envs/dev && terraform apply -var-file=dev.tfvars"
