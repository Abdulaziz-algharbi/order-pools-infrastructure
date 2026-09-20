#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-artifact-bucket.sh failed at line ${LINENO}"' ERR

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

BUCKET_NAME="$(get_output "$ENVIRONMENT" iam/artifact-bucket-name)"
[[ -n "$BUCKET_NAME" && "$BUCKET_NAME" != "None" ]] || BUCKET_NAME="${PROJECT}-${ENVIRONMENT}-backend-artifacts"

# --- What this bucket is for ------------------------------------------
# deploy-backend.sh (below) builds the backend, tars it up, and uploads
# it here under releases/<timestamp>.tar.gz. The EC2 instance then pulls
# that object down over its IAM role (iam/01-ec2-instance-role.sh
# already scoped s3:GetObject to exactly this bucket) via an SSM
# command — never over a public URL, never over SSH/SCP.
#
# S3 bucket names are GLOBALLY unique across every AWS account on
# earth, not just this one — if this name happens to be taken by a
# different account, `create-bucket` fails with BucketAlreadyExists and
# this script will say so explicitly rather than silently reusing
# someone else's bucket.

log_info "Checking whether bucket ${BUCKET_NAME} already exists (and is ours)..."
# `head-bucket` returns 200 (exit 0) if the bucket exists AND this
# credential can access it, a 404 if it doesn't exist at all, and a 403
# if it exists but belongs to someone else. We only treat 404 as "go
# ahead and create it".
HEAD_ERR_FILE="$(mktemp)"
trap 'rm -f "$HEAD_ERR_FILE"' EXIT
HEAD_EXIT=0
aws s3api head-bucket --bucket "$BUCKET_NAME" 2>"$HEAD_ERR_FILE" || HEAD_EXIT=$?

if [[ "$HEAD_EXIT" -eq 0 ]]; then
  log_info "Bucket ${BUCKET_NAME} already exists and is accessible — reusing it."
elif grep -q "404" "$HEAD_ERR_FILE" 2>/dev/null; then
  log_info "Creating bucket ${BUCKET_NAME} in ${AWS_REGION}..."
  # us-east-1 is the one region where `create-bucket` must NOT be given
  # a LocationConstraint (a long-standing S3 API quirk) — every other
  # region, including eu-north-1, requires it explicitly.
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging \
    "TagSet=[{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}},{Key=ManagedBy,Value=${TAG_MANAGED_BY}}]"
else
  die "Bucket name '${BUCKET_NAME}' exists but isn't accessible with this AWS account — S3 names are global, so this name is likely taken by a different AWS account. Change PROJECT or the bucket-naming convention in config/${ENVIRONMENT}.env and retry."
fi

log_info "Blocking all public access..."
aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log_info "Enabling default (SSE-S3) encryption..."
aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Cost/hygiene: without this, every deploy leaves its tarball in the
# bucket forever. 30 days is generous for "roll back to a build from
# last month" while keeping storage cost negligible either way (these
# are small tarballs) — mostly here to demonstrate the habit of not
# accumulating unbounded artifacts.
log_info "Applying a 30-day expiration lifecycle rule to releases/*..."
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" --lifecycle-configuration '{
  "Rules": [{
    "ID": "expire-old-releases",
    "Filter": {"Prefix": "releases/"},
    "Status": "Enabled",
    "Expiration": {"Days": 30}
  }]
}'

put_output "$ENVIRONMENT" "backend/artifact-bucket-name" "$BUCKET_NAME"
log_info "Artifact bucket ready: ${BUCKET_NAME}"
log_info "Verify manually:  aws s3api get-bucket-policy-status --bucket ${BUCKET_NAME}  # should show BlockPublicAccess=true"
log_info "Next: dns-tls/01-acm-backend.sh"
