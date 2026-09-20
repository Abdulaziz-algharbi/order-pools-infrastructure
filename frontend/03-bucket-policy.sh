#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "03-bucket-policy.sh failed at line ${LINENO}"' ERR

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

BUCKET_NAME="$(get_output "$ENVIRONMENT" frontend/bucket-name)"
DIST_ID="$(get_output "$ENVIRONMENT" frontend/distribution-id)"
for v in BUCKET_NAME DIST_ID; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run frontend/01-s3-bucket.sh and frontend/02-cloudfront.sh first."
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DISTRIBUTION_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

# --- Why this specific condition matters -------------------------
# The Principal here is the CloudFront service itself
# (cloudfront.amazonaws.com), not "the internet" — the bucket already
# blocks all public access (frontend/01-s3-bucket.sh), so this is the
# ONLY door into it. The `AWS:SourceArn` condition further restricts
# that door to THIS SPECIFIC distribution — without it, ANY CloudFront
# distribution in ANY AWS account could read this bucket, which would
# defeat the point of using OAC over a plain public bucket in the first
# place.
log_info "Applying bucket policy: read-only, scoped to distribution ${DIST_ID}..."
POLICY_DOCUMENT=$(jq -n \
  --arg bucketArn "arn:aws:s3:::${BUCKET_NAME}" \
  --arg distArn "$DISTRIBUTION_ARN" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "AllowCloudFrontServicePrincipalReadOnly",
      Effect: "Allow",
      Principal: { Service: "cloudfront.amazonaws.com" },
      Action: "s3:GetObject",
      Resource: "\($bucketArn)/*",
      Condition: { StringEquals: { "AWS:SourceArn": $distArn } }
    }]
  }')

aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$POLICY_DOCUMENT"

log_info "Bucket policy applied."
log_info "Verify manually:  aws s3api get-bucket-policy --bucket ${BUCKET_NAME} --query Policy --output text | jq ."
log_info "Next: dns-tls/04-route53-frontend-record.sh"
