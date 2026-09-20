#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "rollback-backend.sh failed at line ${LINENO}"' ERR

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

INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || die "No instance-id found for '${ENVIRONMENT}'."

confirm "This will re-point the running backend at the previous release and restart it on ${INSTANCE_ID}."

log_info "Rendering the remote rollback script..."
REMOTE_SCRIPT_FILE="$(mktemp)"
sed \
  -e "s|__PROJECT__|${PROJECT}|g" \
  -e "s|__BACKEND_PORT__|${BACKEND_PORT}|g" \
  "${SCRIPT_DIR}/rollback-remote.sh.tmpl" > "$REMOTE_SCRIPT_FILE"

log_info "Sending the rollback command to ${INSTANCE_ID} via SSM..."
COMMANDS_JSON="$(jq -n --arg script "$(cat "$REMOTE_SCRIPT_FILE")" '{commands: [$script]}')"
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "order-pool ${ENVIRONMENT} backend rollback" \
  --parameters "$COMMANDS_JSON" \
  --query 'Command.CommandId' --output text)"

aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true
STATUS="$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text)"

if [[ "$STATUS" != "Success" ]]; then
  log_error "Rollback failed (status: ${STATUS}). Output:"
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text
  die "Rollback did not complete cleanly — the instance needs manual investigation (aws ssm start-session --target ${INSTANCE_ID})."
fi

log_info "Rollback succeeded on the instance. Checking target group health..."
if [[ -n "${TG_ARN:-}" && "$TG_ARN" != "None" ]]; then
  for i in $(seq 1 20); do
    HEALTH="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --targets "Id=${INSTANCE_ID}" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
    [[ "$HEALTH" == "healthy" ]] && break
    [[ "$i" -eq 20 ]] && log_warn "Target group not yet healthy (last state: ${HEALTH}) — check manually."
    sleep 5
  done
fi

log_info "Rollback complete."
