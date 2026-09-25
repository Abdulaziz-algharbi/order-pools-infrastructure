#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "deploy-backend.sh failed at line ${LINENO}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/aws-guard.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/state.sh"

ENVIRONMENT="${1:?Usage: $0 <environment> [path-to-order-pools-backend]}"
# Defaults to the sibling checkout — matches the orderPool/{infrastructure,
# order-pools-app,order-pools-backend} layout already assumed by this
# project (and by order-pools-backend's own docker-compose.yml, which
# builds the nginx image from ../order-pools-app the same way).
BACKEND_REPO_PATH="${2:-${INFRA_ROOT}/../order-pools-backend}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

BACKEND_REPO_PATH="$(cd "$BACKEND_REPO_PATH" && pwd)"
[[ -f "${BACKEND_REPO_PATH}/package.json" ]] || die "No package.json at ${BACKEND_REPO_PATH} — pass the correct order-pools-backend path as the 2nd argument."

INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
BUCKET_NAME="$(get_output "$ENVIRONMENT" backend/artifact-bucket-name)"
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
for v in INSTANCE_ID BUCKET_NAME TG_ARN; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run backend/01-ec2-instance.sh, 02-artifact-bucket.sh and 03-target-group.sh first."
done

PARAM_COUNT="$(aws ssm get-parameters-by-path --path "/${PROJECT}/${ENVIRONMENT}/backend/" --query 'length(Parameters)' --output text)"
[[ "$PARAM_COUNT" != "0" ]] || die "No parameters found under /${PROJECT}/${ENVIRONMENT}/backend/ — run backend/env-to-ssm.sh first."

log_info "Building backend from ${BACKEND_REPO_PATH}..."
( cd "$BACKEND_REPO_PATH" && npm ci && npm run build )
[[ -f "${BACKEND_REPO_PATH}/dist/src/server.js" ]] || die "Build did not produce dist/src/server.js — check the build output above."

RELEASE_ID="$(date -u +%Y%m%d%H%M%S)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

log_info "Packaging release artifact (package.json + package-lock.json + dist/ — no node_modules)..."
# node_modules is deliberately NOT in this tarball: bcrypt is a native
# addon, and `npm ci` runs again on the target instance (see
# deploy-remote.sh.tmpl) so the binary that ends up on disk is compiled
# for Ubuntu/the instance's actual architecture, not whatever machine
# built this artifact.
cp "${BACKEND_REPO_PATH}/package.json" "${BACKEND_REPO_PATH}/package-lock.json" "$BUILD_DIR/"
cp -R "${BACKEND_REPO_PATH}/dist" "${BUILD_DIR}/dist"
TARBALL="${BUILD_DIR}/release.tar.gz"
# COPYFILE_DISABLE + --no-xattrs: macOS's bsdtar otherwise embeds
# extended attributes (e.g. com.apple.provenance) as LIBARCHIVE.xattr.*
# headers, which GNU tar on the instance doesn't know and warns about on
# every deploy. Nothing in the release needs extended attributes.
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARBALL" -C "$BUILD_DIR" package.json package-lock.json dist

OBJECT_KEY="releases/${RELEASE_ID}.tar.gz"
log_info "Uploading to s3://${BUCKET_NAME}/${OBJECT_KEY}..."
aws s3 cp "$TARBALL" "s3://${BUCKET_NAME}/${OBJECT_KEY}" >/dev/null

log_info "Rendering the remote deployment script..."
REMOTE_SCRIPT_FILE="$(mktemp)"
sed \
  -e "s|__PROJECT__|${PROJECT}|g" \
  -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
  -e "s|__BACKEND_PORT__|${BACKEND_PORT}|g" \
  -e "s|__ARTIFACT_BUCKET__|${BUCKET_NAME}|g" \
  -e "s|__ARTIFACT_KEY__|${OBJECT_KEY}|g" \
  -e "s|__AWS_REGION__|${AWS_REGION}|g" \
  "${SCRIPT_DIR}/deploy-remote.sh.tmpl" > "$REMOTE_SCRIPT_FILE"

log_info "Sending the deployment command to ${INSTANCE_ID} via SSM (no SSH, no open port involved)..."
COMMANDS_JSON="$(jq -n --arg script "$(cat "$REMOTE_SCRIPT_FILE")" '{commands: [$script]}')"
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "order-pool ${ENVIRONMENT} backend deploy ${RELEASE_ID}" \
  --parameters "$COMMANDS_JSON" \
  --query 'Command.CommandId' --output text)"

log_info "Waiting for the remote script to finish (download, npm ci, restart, local health check)..."
# `command-executed` polls until the command leaves an in-progress
# state; it can itself return non-zero if the command's final status is
# a failure, which is exactly the case this script inspects next rather
# than trusting the waiter's own exit code.
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true

STATUS="$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text)"
if [[ "$STATUS" != "Success" ]]; then
  log_error "Remote deployment script finished with status: ${STATUS}"
  log_error "--- stdout ---"
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text
  log_error "--- stderr ---"
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text
  die "Deployment failed. If the previous release was already running and only the restart/health-check step failed, it may now be down — run backend/rollback-backend.sh ${ENVIRONMENT} to re-point 'current' at the last known-good release."
fi

log_info "Instance-side deployment succeeded. Waiting for the ALB target group to report healthy..."
for i in $(seq 1 20); do
  HEALTH="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --targets "Id=${INSTANCE_ID}" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
  [[ "$HEALTH" == "healthy" ]] && break
  if [[ "$i" -eq 20 ]]; then
    die "Target group never reported healthy (last state: ${HEALTH}) within 100s. The instance's own health check passed, so this may just need a little longer — check: aws elbv2 describe-target-health --target-group-arn ${TG_ARN}"
  fi
  sleep 5
done

put_output "$ENVIRONMENT" "backend/last-release-id" "$RELEASE_ID"
log_info "Deployment complete — release ${RELEASE_ID} is live and healthy behind the ALB."
log_info "Verify:  curl -sf https://${BACKEND_DOMAIN}/ping"
