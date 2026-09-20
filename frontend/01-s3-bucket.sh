#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-s3-bucket.sh failed at line ${LINENO}"' ERR

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

BUCKET_NAME="${PROJECT}-${ENVIRONMENT}-frontend"

# --- Why this bucket is fully private -----------------------------
# Unlike the classic "S3 static website hosting" feature (which requires
# the bucket to be public), this bucket stays private end to end.
# CloudFront reads from it using Origin Access Control (OAC) —
# frontend/02-cloudfront.sh creates that, frontend/03-bucket-policy.sh
# grants read access to ONLY that specific distribution's service
# principal. Nobody, including you, can browse this bucket's contents
# directly over the internet; every request goes through CloudFront.
log_info "Checking whether bucket ${BUCKET_NAME} already exists (and is ours)..."
HEAD_ERR_FILE="$(mktemp)"
trap 'rm -f "$HEAD_ERR_FILE"' EXIT
HEAD_EXIT=0
aws s3api head-bucket --bucket "$BUCKET_NAME" 2>"$HEAD_ERR_FILE" || HEAD_EXIT=$?

if [[ "$HEAD_EXIT" -eq 0 ]]; then
  log_info "Bucket ${BUCKET_NAME} already exists and is accessible — reusing it."
elif grep -q "404" "$HEAD_ERR_FILE" 2>/dev/null; then
  log_info "Creating bucket ${BUCKET_NAME} in ${AWS_REGION}..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging \
    "TagSet=[{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}},{Key=ManagedBy,Value=${TAG_MANAGED_BY}}]"
else
  die "Bucket name '${BUCKET_NAME}' exists but isn't accessible with this AWS account — S3 names are global, so it's likely taken by a different account. Adjust the naming convention in this script and retry."
fi

log_info "Blocking all public access (CloudFront reads this bucket via OAC, not a public bucket policy)..."
aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log_info "Enabling default (SSE-S3) encryption..."
aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

put_output "$ENVIRONMENT" "frontend/bucket-name" "$BUCKET_NAME"
log_info "Frontend bucket ready: ${BUCKET_NAME}"
log_info "Verify manually:  aws s3api get-public-access-block --bucket ${BUCKET_NAME}"
log_info "Next: dns-tls/03-acm-frontend.sh"
