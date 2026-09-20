#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "03-target-group.sh failed at line ${LINENO}"' ERR

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

VPC_ID="$(get_output "$ENVIRONMENT" network/vpc-id)"
INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
for v in VPC_ID INSTANCE_ID; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run the network/ and backend/01-ec2-instance.sh scripts first."
done

TG_NAME="${PROJECT}-${ENVIRONMENT}-backend-tg"

# --- What a target group is, and why the health check matters --------
# A target group is the ALB's list of "where do I actually send traffic"
# plus the rule for deciding whether each target is currently healthy
# enough to receive it. `/ping` (mounted directly on the Express app,
# not under /api — see order-pools-backend/src/app.ts) is used here
# rather than a path under /api/v1, matching how the old nginx setup
# already relied on that same endpoint for its own Docker HEALTHCHECK.
log_info "Checking for an existing target group ${TG_NAME}..."
TG_ARN="$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"

if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  log_info "Found existing target group: ${TG_ARN} — reusing it."
else
  log_info "Creating target group ${TG_NAME} (HTTP:${BACKEND_PORT}, health check /ping)..."
  TG_ARN="$(aws elbv2 create-target-group \
    --name "$TG_NAME" \
    --protocol HTTP \
    --port "$BACKEND_PORT" \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path /ping \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
fi

log_info "Registering instance ${INSTANCE_ID} with the target group..."
# Re-registering an already-registered target is harmless — AWS just
# leaves it as-is, so this is safe to run on every re-run of this
# script without an extra existence check.
aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=${INSTANCE_ID}"

put_output "$ENVIRONMENT" "backend/target-group-arn" "$TG_ARN"
log_info "Target group ready: ${TG_ARN}"
log_info "Verify manually:  aws elbv2 describe-target-health --target-group-arn ${TG_ARN}"
log_info "(It will show 'unhealthy' or 'initial' until deploy-backend.sh actually starts the app — that's expected right now.)"
log_info "Next: backend/04-alb.sh"
