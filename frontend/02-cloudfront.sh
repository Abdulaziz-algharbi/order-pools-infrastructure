#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-cloudfront.sh failed at line ${LINENO}"' ERR

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
CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/frontend-cert-arn)"
for v in BUCKET_NAME CERT_ARN; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run frontend/01-s3-bucket.sh and dns-tls/03-acm-frontend.sh first."
done

# CloudFront itself is a global service (no --region needed for the CLI
# calls below), but the S3 origin must be addressed by its REGIONAL
# domain name, not the legacy global s3.amazonaws.com one — the global
# endpoint issues a redirect for buckets outside us-east-1 that
# CloudFront's origin fetcher doesn't follow.
BUCKET_REGIONAL_DOMAIN="${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
OAC_NAME="${PROJECT}-${ENVIRONMENT}-frontend-oac"
ORIGIN_ID="${PROJECT}-${ENVIRONMENT}-s3-origin"

# =====================================================================
# Origin Access Control (OAC) — the modern replacement for the older
# "Origin Access Identity". It lets CloudFront sign its requests to S3
# with SigV4 so the bucket can trust "this request really came from my
# CloudFront distribution" and grant it read access via a bucket policy
# (frontend/03-bucket-policy.sh) — without the bucket ever being public.
# =====================================================================
log_info "Checking for an existing Origin Access Control ${OAC_NAME}..."
OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" --output text 2>/dev/null || true)"

if [[ -n "$OAC_ID" && "$OAC_ID" != "None" ]]; then
  log_info "Found existing OAC: ${OAC_ID} — reusing it."
else
  log_info "Creating Origin Access Control ${OAC_NAME}..."
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "Name=${OAC_NAME},Description=OrderPool ${ENVIRONMENT} frontend,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)"
fi
put_output "$ENVIRONMENT" "frontend/oac-id" "$OAC_ID"

# =====================================================================
# The distribution itself
# =====================================================================
log_info "Checking for an existing distribution serving ${FRONTEND_DOMAIN}..."
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${FRONTEND_DOMAIN}')].Id | [0]" \
  --output text 2>/dev/null || true)"

if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
  log_info "Found existing distribution: ${DIST_ID} — reusing it."
  log_info "(This script does not update an existing distribution's config — edit and re-run manually via 'aws cloudfront update-distribution' if settings below ever need to change.)"
else
  log_info "Creating CloudFront distribution for ${FRONTEND_DOMAIN}..."

  # CachingOptimized (Id 658327ea-f89d-4fab-a63d-7e88639e58f6) is one of
  # AWS's own predefined, account-independent managed cache policies —
  # the same ID on every AWS account on earth, not a resource this
  # project created. It's the standard choice for a static SPA: caches
  # based on the URL only (no cookies/headers/query strings affect the
  # cache key), long TTLs by default, gzip/brotli compression.
  readonly CACHING_OPTIMIZED_POLICY_ID="658327ea-f89d-4fab-a63d-7e88639e58f6"

  DIST_CONFIG_FILE="$(mktemp)"
  trap 'rm -f "$DIST_CONFIG_FILE"' EXIT
  jq -n \
    --arg callerRef "${PROJECT}-${ENVIRONMENT}-$(date -u +%s)" \
    --arg comment "OrderPool ${ENVIRONMENT} frontend" \
    --arg originId "$ORIGIN_ID" \
    --arg originDomain "$BUCKET_REGIONAL_DOMAIN" \
    --arg oacId "$OAC_ID" \
    --arg alias "$FRONTEND_DOMAIN" \
    --arg certArn "$CERT_ARN" \
    --arg cachePolicyId "$CACHING_OPTIMIZED_POLICY_ID" \
    '{
      CallerReference: $callerRef,
      Comment: $comment,
      Enabled: true,
      DefaultRootObject: "index.html",
      Origins: {
        Quantity: 1,
        Items: [{
          Id: $originId,
          DomainName: $originDomain,
          OriginAccessControlId: $oacId,
          S3OriginConfig: { OriginAccessIdentity: "" }
        }]
      },
      DefaultCacheBehavior: {
        TargetOriginId: $originId,
        ViewerProtocolPolicy: "redirect-to-https",
        AllowedMethods: { Quantity: 2, Items: ["GET","HEAD"], CachedMethods: { Quantity: 2, Items: ["GET","HEAD"] } },
        Compress: true,
        CachePolicyId: $cachePolicyId
      },
      # SPA client-side routing: React Router paths like /retailer/pools
      # are not real S3 keys, so S3 (via CloudFront) returns a 403 (the
      # object literally does not exist, and this bucket denies listing)
      # for them. Rewriting both 403 and 404 to /index.html with a 200
      # is what lets the client-side router take over instead of the
      # visitor seeing a raw error page on refresh/deep link.
      CustomErrorResponses: {
        Quantity: 2,
        Items: [
          { ErrorCode: 403, ResponseCode: "200", ResponsePagePath: "/index.html", ErrorCachingMinTTL: 10 },
          { ErrorCode: 404, ResponseCode: "200", ResponsePagePath: "/index.html", ErrorCachingMinTTL: 10 }
        ]
      },
      Aliases: { Quantity: 1, Items: [$alias] },
      ViewerCertificate: {
        ACMCertificateArn: $certArn,
        SSLSupportMethod: "sni-only",
        MinimumProtocolVersion: "TLSv1.2_2021"
      },
      # PriceClass_100 = US/Canada/Europe edge locations only — the
      # cheapest tier. Fine for a dev/demo audience; widen to
      # PriceClass_All (all edge locations worldwide, higher cost) later
      # if/when there is a genuinely global audience to serve.
      PriceClass: "PriceClass_100"
    }' > "$DIST_CONFIG_FILE"

  DIST_ID="$(aws cloudfront create-distribution --distribution-config "file://${DIST_CONFIG_FILE}" \
    --query 'Distribution.Id' --output text)"

  # A first distribution deploy propagates to every edge location
  # worldwide — this routinely takes 5-15+ minutes. There is no faster
  # path; this is CloudFront's own deployment process, not something
  # this script controls.
  log_info "Waiting for the distribution to finish deploying globally (this is genuinely slow — often 5-15+ minutes)..."
  aws cloudfront wait distribution-deployed --id "$DIST_ID"
fi

DIST_DOMAIN_NAME="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"
put_output "$ENVIRONMENT" "frontend/distribution-id" "$DIST_ID"
put_output "$ENVIRONMENT" "frontend/distribution-domain-name" "$DIST_DOMAIN_NAME"

log_info "Distribution ready: ${DIST_DOMAIN_NAME} (id: ${DIST_ID})"
log_info "Verify manually:  aws cloudfront get-distribution --id ${DIST_ID} --query 'Distribution.Status'"
log_info "Next: frontend/03-bucket-policy.sh (grants THIS distribution read access to the bucket)."
