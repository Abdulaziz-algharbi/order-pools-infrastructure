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
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/ssm.sh"

ENVIRONMENT="${1:?Usage: $0 <environment> [image-tag]}"
# Optional: a specific image tag (a commit SHA in ECR) to go back to.
# Without it, the instance picks: the last image that was healthy there
# if the latest deploy failed, otherwise the one deployed before the
# current one (see deploy-remote.sh.tmpl).
TARGET_TAG="${2:-previous}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
REPOSITORY_URI="$(get_output "$ENVIRONMENT" backend/ecr-repository-uri)"
LOG_GROUP_NAME="$(get_output "$ENVIRONMENT" backend/log-group-name)"
for v in INSTANCE_ID REPOSITORY_URI LOG_GROUP_NAME; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing for '${ENVIRONMENT}'."
done

# A rollback is a deploy of an earlier image: the same remote script,
# with "previous" (or the tag given) instead of a new commit. It also
# re-reads the settings from SSM Parameter Store, so the image goes back
# but the configuration stays current.
confirm "This will replace the running backend container on ${INSTANCE_ID} with image '${TARGET_TAG}'."

log_info "Rendering the remote deployment script for image '${TARGET_TAG}'..."
REMOTE_SCRIPT_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_SCRIPT_FILE"' EXIT
sed \
  -e "s|__PROJECT__|${PROJECT}|g" \
  -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
  -e "s|__BACKEND_PORT__|${BACKEND_PORT}|g" \
  -e "s|__AWS_REGION__|${AWS_REGION}|g" \
  -e "s|__IMAGE_REPOSITORY__|${REPOSITORY_URI}|g" \
  -e "s|__IMAGE_TAG__|${TARGET_TAG}|g" \
  -e "s|__LOG_GROUP__|${LOG_GROUP_NAME}|g" \
  "${SCRIPT_DIR}/deploy-remote.sh.tmpl" > "$REMOTE_SCRIPT_FILE"

ssm_run_script "$INSTANCE_ID" "order-pool ${ENVIRONMENT} backend rollback (${TARGET_TAG:0:12})" "$REMOTE_SCRIPT_FILE" \
  || die "Rollback did not complete cleanly — the instance needs manual investigation (aws ssm start-session --target ${INSTANCE_ID}; then: cat /opt/${PROJECT}-backend/deployed-tags, docker compose -f /opt/${PROJECT}-backend/compose.yml ps -a)."

log_info "Rollback succeeded on the instance. Checking target group health..."
if [[ -n "${TG_ARN:-}" && "$TG_ARN" != "None" ]]; then
  wait_target_healthy "$TG_ARN" "$INSTANCE_ID" || log_warn "Target group not yet healthy — check manually."
fi

log_info "Rollback complete."
