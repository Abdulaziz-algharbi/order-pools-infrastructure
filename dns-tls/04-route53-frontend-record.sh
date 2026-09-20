#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "04-route53-frontend-record.sh failed at line ${LINENO}"' ERR

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

HOSTED_ZONE_ID="$(get_output "$ENVIRONMENT" dns-tls/hosted-zone-id)"
DIST_DOMAIN_NAME="$(get_output "$ENVIRONMENT" frontend/distribution-domain-name)"
for v in HOSTED_ZONE_ID DIST_DOMAIN_NAME; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run dns-tls/03-acm-frontend.sh and frontend/02-cloudfront.sh first."
done

# Every CloudFront distribution on every AWS account shares this exact
# same hosted zone ID — it identifies "this alias target is a CloudFront
# distribution" to Route 53, the same way each ALB region has its own
# fixed CanonicalHostedZoneId (used in dns-tls/02-route53-backend-record.sh).
# This is a documented AWS platform constant, not a per-resource ID this
# project owns or needs to look up.
readonly CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"

log_info "Upserting ALIAS record ${FRONTEND_DOMAIN} -> ${DIST_DOMAIN_NAME}..."
CHANGE_BATCH=$(jq -n \
  --arg name "$FRONTEND_DOMAIN" \
  --arg cfDomain "$DIST_DOMAIN_NAME" \
  --arg cfZone "$CLOUDFRONT_HOSTED_ZONE_ID" \
  '{Changes:[{Action:"UPSERT",ResourceRecordSet:{
      Name:$name, Type:"A",
      AliasTarget:{HostedZoneId:$cfZone, DNSName:$cfDomain, EvaluateTargetHealth:false}
  }}]}')
# EvaluateTargetHealth is false here (unlike the ALB record) because
# CloudFront distributions don't expose a health-check-able target the
# way an ALB's targets do — there's nothing meaningful for Route 53 to
# evaluate.

CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" --query 'ChangeInfo.Id' --output text)"

log_info "Waiting for the change to propagate to all Route 53 name servers (INSYNC)..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

log_info "DNS ready: https://${FRONTEND_DOMAIN} now resolves to CloudFront."
log_info "Verify manually:  dig +short ${FRONTEND_DOMAIN}"
log_info "Frontend networking/DNS/TLS is now fully wired. Next: frontend/deploy-frontend.sh"
