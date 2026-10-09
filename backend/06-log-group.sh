#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "06-log-group.sh failed at line ${LINENO}"' ERR

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

# Same name iam/01-ec2-instance-role.sh scopes the instance's
# logs:PutLogEvents permission to.
LOG_GROUP_NAME="/${PROJECT}/${ENVIRONMENT}/backend"
RETENTION_DAYS="${LOG_RETENTION_DAYS:?Set LOG_RETENTION_DAYS in config/${ENVIRONMENT}.env}"

# --- What this log group is for ----------------------------------------
# In a container the backend logs only to stdout (order-pools-backend's
# Dockerfile sets LOG_TO_FILES=false). Docker's `awslogs` logging driver
# sends that stdout straight to this CloudWatch Logs group, one log
# stream per container. So logs survive a redeploy (a replaced container
# loses its local log), survive the instance itself being replaced, and
# can be read without opening a session on the instance:
#   aws logs tail /order-pool/<env>/backend --follow
#
# The group is created here rather than by the driver
# (awslogs-create-group=true) so it gets a retention period: a group the
# driver creates keeps logs forever, and CloudWatch bills storage
# (~$0.03/GB-month) on top of ingestion (~$0.50/GB). How long is
# LOG_RETENTION_DAYS (config/<env>.env): dev keeps a week. Re-running
# this script applies a changed value to the existing group.

log_info "Checking for an existing log group ${LOG_GROUP_NAME}..."
EXISTING="$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" \
  --query "length(logGroups[?logGroupName=='${LOG_GROUP_NAME}'])" --output text)"
if [[ "$EXISTING" != "0" ]]; then
  log_info "Log group ${LOG_GROUP_NAME} already exists — reusing it."
else
  log_info "Creating log group ${LOG_GROUP_NAME}..."
  aws logs create-log-group \
    --log-group-name "$LOG_GROUP_NAME" \
    --tags "Project=${PROJECT},Environment=${ENVIRONMENT},ManagedBy=${TAG_MANAGED_BY}"
fi

log_info "Setting retention to ${RETENTION_DAYS} days..."
aws logs put-retention-policy --log-group-name "$LOG_GROUP_NAME" --retention-in-days "$RETENTION_DAYS"

put_output "$ENVIRONMENT" "backend/log-group-name" "$LOG_GROUP_NAME"

log_info "Log group ready: ${LOG_GROUP_NAME} (retention ${RETENTION_DAYS} days)"
log_info "Verify manually:  aws logs describe-log-groups --log-group-name-prefix ${LOG_GROUP_NAME}"
log_info "Next: dns-tls/01-acm-backend.sh"
