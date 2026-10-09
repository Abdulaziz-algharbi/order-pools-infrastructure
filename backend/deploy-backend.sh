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
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/ssm.sh"

ENVIRONMENT="${1:?Usage: $0 <environment> [path-to-order-pools-backend]}"
# Defaults to the sibling checkout — matches the orderPool/{infrastructure,
# order-pools-app,order-pools-backend} layout already assumed by this
# project.
BACKEND_REPO_PATH="${2:-${INFRA_ROOT}/../order-pools-backend}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"
require_cmd docker git jq

# --- What this does ------------------------------------------------------
# The same deploy GitHub Actions runs on every push to main
# (order-pools-backend/.github/workflows/deploy.yml + this repo's
# .github/workflows/deploy-backend.yml), from a laptop:
#   1. build the backend's Docker image from your checkout,
#   2. push it to ECR, tagged with the commit,
#   3. tell the instance (SSM) to pull and run it (deploy-remote.sh.tmpl),
#   4. wait for the ALB to see it healthy.
# Unlike CI it doesn't run the tests first — run them yourself, e.g.
# `node scripts/run-api-tests.js --api-image=<tag>` in order-pools-backend.

BACKEND_REPO_PATH="$(cd "$BACKEND_REPO_PATH" && pwd)"
[[ -f "${BACKEND_REPO_PATH}/Dockerfile" ]] || die "No Dockerfile at ${BACKEND_REPO_PATH} — pass the correct order-pools-backend path as the 2nd argument."

INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
REPOSITORY_NAME="$(get_output "$ENVIRONMENT" backend/ecr-repository-name)"
REPOSITORY_URI="$(get_output "$ENVIRONMENT" backend/ecr-repository-uri)"
LOG_GROUP_NAME="$(get_output "$ENVIRONMENT" backend/log-group-name)"
for v in INSTANCE_ID TG_ARN REPOSITORY_NAME REPOSITORY_URI LOG_GROUP_NAME; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run backend/01-ec2-instance.sh, 03-target-group.sh, 05-ecr-repository.sh and 06-log-group.sh first."
done

PARAM_COUNT="$(aws ssm get-parameters-by-path --path "/${PROJECT}/${ENVIRONMENT}/backend/" --query 'length(Parameters)' --output text)"
[[ "$PARAM_COUNT" != "0" ]] || die "No parameters found under /${PROJECT}/${ENVIRONMENT}/backend/ — run backend/env-to-ssm.sh first."

# The tag says exactly which code is in the image. A checkout with
# uncommitted changes isn't any commit, so it gets its own tag (with a
# timestamp — the repository's tags are immutable, so every such build
# needs a new one) rather than passing itself off as HEAD.
COMMIT="$(git -C "$BACKEND_REPO_PATH" rev-parse HEAD)"
if [[ -n "$(git -C "$BACKEND_REPO_PATH" status --porcelain)" ]]; then
  IMAGE_TAG="${COMMIT}-dirty-$(date -u +%Y%m%d%H%M%S)"
  log_warn "order-pools-backend has uncommitted changes — tagging this build ${IMAGE_TAG}."
else
  IMAGE_TAG="$COMMIT"
fi
IMAGE="${REPOSITORY_URI}:${IMAGE_TAG}"

if aws ecr describe-images --repository-name "$REPOSITORY_NAME" --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
  log_info "${IMAGE_TAG} is already in ECR (built by CI or an earlier run) — deploying that image as is."
else
  # --platform: the image must match the INSTANCE's CPU, not this
  # machine's. On an Apple Silicon Mac a plain build is arm64, which an
  # x86_64 t3 instance can't run; Docker emulates the other architecture
  # for the build (slower — a few minutes — but the result is native for
  # the instance).
  log_info "Building ${IMAGE} for ${IMAGE_PLATFORM}..."
  docker build --platform "$IMAGE_PLATFORM" -t "$IMAGE" "$BACKEND_REPO_PATH"

  log_info "Pushing to ECR..."
  # Your own AWS credentials, traded for a 12-hour registry token.
  aws ecr get-login-password | docker login --username AWS --password-stdin "${REPOSITORY_URI%%/*}"
  docker push "$IMAGE"
fi

log_info "Rendering the remote deployment script..."
REMOTE_SCRIPT_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_SCRIPT_FILE"' EXIT
sed \
  -e "s|__PROJECT__|${PROJECT}|g" \
  -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
  -e "s|__BACKEND_PORT__|${BACKEND_PORT}|g" \
  -e "s|__AWS_REGION__|${AWS_REGION}|g" \
  -e "s|__IMAGE_REPOSITORY__|${REPOSITORY_URI}|g" \
  -e "s|__IMAGE_TAG__|${IMAGE_TAG}|g" \
  -e "s|__LOG_GROUP__|${LOG_GROUP_NAME}|g" \
  "${SCRIPT_DIR}/deploy-remote.sh.tmpl" > "$REMOTE_SCRIPT_FILE"

log_info "Deploying ${IMAGE_TAG} on ${INSTANCE_ID} via SSM (no SSH, no open port involved)..."
ssm_run_script "$INSTANCE_ID" "order-pool ${ENVIRONMENT} backend deploy ${IMAGE_TAG:0:12}" "$REMOTE_SCRIPT_FILE" \
  || die "Deployment failed — see the remote output above. If the new container started but never got healthy, the backend is down: run backend/rollback-backend.sh ${ENVIRONMENT} to go back to the last image that was healthy here."

log_info "Instance-side deployment succeeded. Waiting for the ALB target group to report healthy..."
wait_target_healthy "$TG_ARN" "$INSTANCE_ID" \
  || die "The instance's own health check passed, so this may just need a little longer — check: aws elbv2 describe-target-health --target-group-arn ${TG_ARN}"

put_output "$ENVIRONMENT" "backend/last-release-id" "$IMAGE_TAG"
log_info "Deployment complete — ${IMAGE_TAG} is live and healthy behind the ALB."
log_info "Verify:  curl -sf https://${BACKEND_DOMAIN}/ping"
log_info "Logs:    aws logs tail ${LOG_GROUP_NAME} --follow"
