#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "env-to-ssm.sh failed at line ${LINENO}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/aws-guard.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/state.sh"

ENVIRONMENT="${1:?Usage: $0 <environment>}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

SECRETS_FILE="${INFRA_ROOT}/config/${ENVIRONMENT}.secrets.env"
[[ -f "$SECRETS_FILE" ]] || die "Missing ${SECRETS_FILE}. Copy config/${ENVIRONMENT}.secrets.env.example to that path and fill in real values first (it's gitignored — never commit it)."

# --- Why Parameter Store, and why every value as SecureString ---------
# These become the backend's environment variables in production
# (order-pools-backend/.env.example is exactly what this file mirrors).
# Pushing them as SecureString means they're encrypted at rest with the
# AWS-managed `alias/aws/ssm` key, and readable only by a caller with
# ssm:GetParameter — which, on the EC2 side, is exactly and only the
# scoped policy iam/01-ec2-instance-role.sh attached to this instance's
# role. Nothing is ever written into a bash script, a systemd unit file
# committed to git, or a Docker image layer.
log_info "Pushing ${SECRETS_FILE} into SSM Parameter Store under /${PROJECT}/${ENVIRONMENT}/backend/..."

PUSHED_COUNT=0
while IFS='=' read -r key value; do
  # Skip blank lines and comments; skip keys left blank in the template
  # (e.g. optional SMTP_* vars) rather than pushing an empty secret.
  [[ -z "$key" || "$key" == \#* ]] && continue
  [[ -z "$value" ]] && { log_warn "Skipping ${key} — no value set in ${SECRETS_FILE}."; continue; }

  aws ssm put-parameter \
    --name "/${PROJECT}/${ENVIRONMENT}/backend/${key}" \
    --type SecureString \
    --value "$value" \
    --overwrite \
    --output json >/dev/null
  PUSHED_COUNT=$((PUSHED_COUNT + 1))
done < "$SECRETS_FILE"

log_info "Pushed ${PUSHED_COUNT} parameters."
log_info "Verify manually (names only, never prints values):"
log_info "  aws ssm get-parameters-by-path --path /${PROJECT}/${ENVIRONMENT}/backend/ --query 'Parameters[].Name'"
log_info "Next: backend/deploy-backend.sh reads these back (WithDecryption) on every deploy."
