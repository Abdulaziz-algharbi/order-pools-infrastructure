#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-acm-backend.sh failed at line ${LINENO}"' ERR

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

# --- Region note -------------------------------------------------------
# Unlike a CloudFront certificate (which MUST live in us-east-1 no
# matter what region everything else is in), an ALB's certificate must
# be in the SAME region as the ALB itself — eu-north-1 here. This script
# deliberately does NOT override AWS_DEFAULT_REGION away from
# config/dev.env's value, whereas the frontend's ACM script (Phase 4)
# will have to.

log_info "Looking up the Route 53 hosted zone for ${DOMAIN_ROOT}..."
# A hosted zone can have a trailing dot in its Id (e.g. /hostedzone/ZABC)
# — `--output text` on `.Id` returns that whole path, so it's stripped
# down to just the zone ID with `sed` before use elsewhere.
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN_ROOT}." \
  --query "HostedZones[?Name=='${DOMAIN_ROOT}.'].Id | [0]" --output text | sed 's#/hostedzone/##')"
[[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] || die "No Route 53 hosted zone found for ${DOMAIN_ROOT}. You said its NS/SOA records are already set — confirm the zone exists: aws route53 list-hosted-zones-by-name"
put_output "$ENVIRONMENT" "dns-tls/hosted-zone-id" "$HOSTED_ZONE_ID"
log_info "Hosted zone: ${HOSTED_ZONE_ID}"

log_info "Checking for an existing, usable ACM certificate for ${BACKEND_DOMAIN}..."
CERT_ARN="$(aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
  --query "CertificateSummaryList[?DomainName=='${BACKEND_DOMAIN}'] | [0].CertificateArn" --output text 2>/dev/null || true)"

if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
  log_info "Found existing certificate: ${CERT_ARN} — reusing it."
else
  log_info "Requesting a new DNS-validated certificate for ${BACKEND_DOMAIN}..."
  # DNS validation (vs. email validation) is what lets this be fully
  # scripted: ACM hands back a CNAME record to publish, and once
  # Route 53 is serving it, ACM polls for it itself — no human ever has
  # to click a validation email link.
  CERT_ARN="$(aws acm request-certificate \
    --domain-name "$BACKEND_DOMAIN" \
    --validation-method DNS \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    --query 'CertificateArn' --output text)"
fi
put_output "$ENVIRONMENT" "dns-tls/backend-cert-arn" "$CERT_ARN"

# --- Eventual consistency: the validation CNAME isn't available the
# instant request-certificate returns — ACM needs a few seconds to
# generate it. Poll describe-certificate until it shows up rather than
# assuming it's there on the first call.
log_info "Waiting for ACM to generate the DNS validation record..."
VALIDATION_NAME=""
for _ in $(seq 1 20); do
  VALIDATION_NAME="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null || true)"
  [[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] && break
  sleep 5
done
[[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] || die "ACM never produced a validation record after 100s — re-run this script, or check 'aws acm describe-certificate --certificate-arn ${CERT_ARN}'."

VALIDATION_TYPE="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Type' --output text)"
VALIDATION_VALUE="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)"

log_info "Publishing the validation record (${VALIDATION_TYPE} ${VALIDATION_NAME}) to Route 53..."
CHANGE_BATCH=$(jq -n \
  --arg name "$VALIDATION_NAME" --arg type "$VALIDATION_TYPE" --arg value "$VALIDATION_VALUE" \
  '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:$type,TTL:300,ResourceRecords:[{Value:$value}]}}]}')
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" --query 'ChangeInfo.Id' --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
log_info "Validation record is live in Route 53."

# `certificate-validated` is a real ACM waiter — it polls
# describe-certificate until Status is ISSUED. This can take anywhere
# from under a minute to ~20+ minutes depending on how fast ACM's own
# validation check runs; if this step times out, the certificate and
# its validation record both already exist, so simply re-running this
# script picks up exactly where it left off (both idempotency checks
# above will find them and skip straight to this wait).
log_info "Waiting for ACM to validate and issue the certificate — this can take a few minutes..."
aws acm wait certificate-validated --certificate-arn "$CERT_ARN"

log_info "Certificate ISSUED: ${CERT_ARN}"
log_info "Verify manually:  aws acm describe-certificate --certificate-arn ${CERT_ARN} --query 'Certificate.Status'"
log_info "Next: backend/03-target-group.sh, then backend/04-alb.sh (uses this certificate ARN)."
