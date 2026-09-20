#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "03-acm-frontend.sh failed at line ${LINENO}"' ERR

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

# --- The one hard-coded region in this entire project, and why -------
# `check_account_region` sets AWS_DEFAULT_REGION to config/<env>.env's
# AWS_REGION (eu-north-1) — correct for every other script, because the
# ALB and everything behind it genuinely lives there. CloudFront is
# different: it's a global service, but the CERTIFICATE it uses must be
# requested in the specific region us-east-1, no matter which region
# your stack otherwise runs in. Get this wrong (i.e. omit --region here)
# and `request-certificate` silently succeeds in eu-north-1, the
# certificate is real and valid, and frontend/02-cloudfront.sh will
# simply be unable to find or use it — a classic, easy-to-miss mistake.
# Every `aws acm` call below passes --region us-east-1 explicitly rather
# than relying on any ambient default.
ACM_REGION="us-east-1"

log_info "Looking up the Route 53 hosted zone for ${DOMAIN_ROOT}..."
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN_ROOT}." \
  --query "HostedZones[?Name=='${DOMAIN_ROOT}.'].Id | [0]" --output text | sed 's#/hostedzone/##')"
[[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] || die "No Route 53 hosted zone found for ${DOMAIN_ROOT}."
put_output "$ENVIRONMENT" "dns-tls/hosted-zone-id" "$HOSTED_ZONE_ID"

log_info "Checking for an existing, usable ACM certificate for ${FRONTEND_DOMAIN} in ${ACM_REGION}..."
CERT_ARN="$(aws acm list-certificates --region "$ACM_REGION" --certificate-statuses ISSUED PENDING_VALIDATION \
  --query "CertificateSummaryList[?DomainName=='${FRONTEND_DOMAIN}'] | [0].CertificateArn" --output text 2>/dev/null || true)"

if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
  log_info "Found existing certificate: ${CERT_ARN} — reusing it."
else
  log_info "Requesting a new DNS-validated certificate for ${FRONTEND_DOMAIN} in ${ACM_REGION}..."
  CERT_ARN="$(aws acm request-certificate --region "$ACM_REGION" \
    --domain-name "$FRONTEND_DOMAIN" \
    --validation-method DNS \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    --query 'CertificateArn' --output text)"
fi
put_output "$ENVIRONMENT" "dns-tls/frontend-cert-arn" "$CERT_ARN"

log_info "Waiting for ACM to generate the DNS validation record..."
VALIDATION_NAME=""
for _ in $(seq 1 20); do
  VALIDATION_NAME="$(aws acm describe-certificate --region "$ACM_REGION" --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null || true)"
  [[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] && break
  sleep 5
done
[[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] || die "ACM never produced a validation record after 100s — re-run this script."

VALIDATION_TYPE="$(aws acm describe-certificate --region "$ACM_REGION" --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Type' --output text)"
VALIDATION_VALUE="$(aws acm describe-certificate --region "$ACM_REGION" --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)"

log_info "Publishing the validation record (${VALIDATION_TYPE} ${VALIDATION_NAME}) to Route 53..."
CHANGE_BATCH=$(jq -n \
  --arg name "$VALIDATION_NAME" --arg type "$VALIDATION_TYPE" --arg value "$VALIDATION_VALUE" \
  '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:$type,TTL:300,ResourceRecords:[{Value:$value}]}}]}')
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" --query 'ChangeInfo.Id' --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
log_info "Validation record is live in Route 53."

log_info "Waiting for ACM to validate and issue the certificate — this can take a few minutes..."
aws acm wait certificate-validated --region "$ACM_REGION" --certificate-arn "$CERT_ARN"

log_info "Certificate ISSUED: ${CERT_ARN}"
log_info "Verify manually:  aws acm describe-certificate --region ${ACM_REGION} --certificate-arn ${CERT_ARN} --query 'Certificate.Status'"
log_info "Next: frontend/02-cloudfront.sh (uses this certificate ARN)."
