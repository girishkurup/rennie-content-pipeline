#!/usr/bin/env bash
# Writes frontend/.env.production and frontend/.env.development from the
# current Terraform outputs — run this after `terraform apply` in a new
# account/environment, before `npm run build`.
#
# Usage:
#   ./scripts/generate_frontend_env.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/envs/dev"
TFVARS_FILE="$ENV_DIR/dev.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "ERROR: $TFVARS_FILE not found. Point ENV_DIR/TFVARS_FILE at your env if you've renamed it." >&2
  exit 1
fi

AWS_REGION="$(grep -E "^\s*aws_region\s*=" "$TFVARS_FILE" | head -1 | sed -E 's/^[^=]*=\s*"?([^"]*)"?\s*$/\1/')"

echo "--- Reading terraform outputs from $ENV_DIR ---"
pushd "$ENV_DIR" >/dev/null

API_ENDPOINT="$(terraform output -raw api_endpoint)"
USER_POOL_ID="$(terraform output -raw cognito_user_pool_id)"
CLIENT_ID="$(terraform output -raw cognito_app_client_id)"
HOSTED_UI_DOMAIN="$(terraform output -raw cognito_hosted_ui_domain)"

popd >/dev/null

if [[ -z "$API_ENDPOINT" || -z "$USER_POOL_ID" ]]; then
  echo "ERROR: got empty outputs — has 'terraform apply' finished successfully in $ENV_DIR?" >&2
  exit 1
fi

ENV_CONTENT="VITE_API_ENDPOINT=${API_ENDPOINT}
VITE_AWS_REGION=${AWS_REGION}
VITE_COGNITO_USER_POOL_ID=${USER_POOL_ID}
VITE_COGNITO_CLIENT_ID=${CLIENT_ID}
VITE_COGNITO_HOSTED_UI_DOMAIN=${HOSTED_UI_DOMAIN}
"

# Both files carry the same deployed-API values today (local dev talks to
# the real deployed backend, not a local emulator) — see frontend/README
# notes if that ever changes and .env.development needs to diverge.
printf '%s' "$ENV_CONTENT" > "$REPO_ROOT/frontend/.env.production"
printf '%s' "$ENV_CONTENT" > "$REPO_ROOT/frontend/.env.development"

echo "--- Wrote frontend/.env.production and frontend/.env.development ---"
cat "$REPO_ROOT/frontend/.env.production"

echo
echo "Now run:"
echo "  cd frontend && npm run build"
echo "  cd terraform/envs/dev && terraform apply -var-file=dev.tfvars   # uploads frontend/dist"
