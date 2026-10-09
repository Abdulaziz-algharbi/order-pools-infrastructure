#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "05-ecr-repository.sh failed at line ${LINENO}"' ERR

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

# Same name iam/01-ec2-instance-role.sh and iam/02-github-oidc-roles.sh
# scope their ECR permissions to.
REPOSITORY_NAME="${PROJECT}-${ENVIRONMENT}-backend"
KEEP_IMAGES="${ECR_KEEP_IMAGES:?Set ECR_KEEP_IMAGES in config/${ENVIRONMENT}.env}"

# --- What this repository is for ---------------------------------------
# The backend ships as a Docker image (order-pools-backend/Dockerfile),
# not a tarball. GitHub Actions builds it once, runs the tests against
# that exact image, and pushes it here tagged with the git commit SHA.
# The EC2 instance then pulls it over its own IAM role — the same
# pull-based model as the S3 artifact bucket: nothing is pushed to the
# instance, and the registry is private (no public pull, ever).
#
# ECR (Elastic Container Registry) is AWS's private Docker registry.
# Unlike Docker Hub it authenticates with IAM, so neither CI (OIDC role)
# nor the instance (instance profile) needs a stored registry password:
# `aws ecr get-login-password` exchanges the caller's IAM credentials for
# a 12-hour registry token.

log_info "Checking for an existing ECR repository ${REPOSITORY_NAME}..."
if aws ecr describe-repositories --repository-names "$REPOSITORY_NAME" >/dev/null 2>&1; then
  log_info "Repository ${REPOSITORY_NAME} already exists — reusing it."
else
  log_info "Creating ECR repository ${REPOSITORY_NAME}..."
  # --image-tag-mutability IMMUTABLE: once `:<git-sha>` is pushed, no
  #   later push can silently replace what that tag points at. A tag then
  #   always means one exact build, which is what makes "roll back to the
  #   previous tag" trustworthy. (CI skips the push when the tag already
  #   exists — a re-run of the same commit redeploys the same image.)
  # scanOnPush=true: ECR's basic vulnerability scan (free) runs on every
  #   push; results show under the image in the console or via
  #   `aws ecr describe-image-scan-findings`. Informational only — it
  #   never blocks a deploy.
  # AES256: images are encrypted at rest with an S3-managed key — ECR's
  #   default, stated explicitly. KMS would add a key to manage for no
  #   gain at this stage.
  aws ecr create-repository \
    --repository-name "$REPOSITORY_NAME" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    >/dev/null
fi

# Cost/hygiene, same idea as the artifact bucket's 30-day rule: ECR
# charges for storage (~$0.10/GB-month), and every push adds an image.
# Rule 1 removes untagged images (layers left behind when a build fails
# mid-push) after a day; rule 2 keeps the ECR_KEEP_IMAGES most recent
# images (config/<env>.env) and expires older ones. Images share their
# base layers, so a few of them are a few hundred MB in total.
# Rules are evaluated in rulePriority order, lowest first.
log_info "Applying lifecycle policy (untagged: 1 day; keep the ${KEEP_IMAGES} newest images)..."
LIFECYCLE_POLICY=$(jq -n --argjson keep "$KEEP_IMAGES" '{
  rules: [
    {
      rulePriority: 1,
      description: "Expire untagged images after 1 day",
      selection: { tagStatus: "untagged", countType: "sinceImagePushed", countUnit: "days", countNumber: 1 },
      action: { type: "expire" }
    },
    {
      rulePriority: 2,
      description: "Keep only the \($keep) most recent images",
      selection: { tagStatus: "any", countType: "imageCountMoreThan", countNumber: $keep },
      action: { type: "expire" }
    }
  ]
}')
aws ecr put-lifecycle-policy \
  --repository-name "$REPOSITORY_NAME" \
  --lifecycle-policy-text "$LIFECYCLE_POLICY" >/dev/null

REPOSITORY_URI="$(aws ecr describe-repositories --repository-names "$REPOSITORY_NAME" \
  --query 'repositories[0].repositoryUri' --output text)"

put_output "$ENVIRONMENT" "backend/ecr-repository-name" "$REPOSITORY_NAME"
put_output "$ENVIRONMENT" "backend/ecr-repository-uri" "$REPOSITORY_URI"

log_info "ECR repository ready: ${REPOSITORY_URI}"
log_info "Verify manually:  aws ecr describe-repositories --repository-names ${REPOSITORY_NAME}"
log_info "                  aws ecr get-lifecycle-policy --repository-name ${REPOSITORY_NAME}"
log_info "Next: backend/06-log-group.sh"
