#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-route53-backend-record.sh failed at line ${LINENO}"' ERR

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
ALB_DNS_NAME="$(get_output "$ENVIRONMENT" backend/alb-dns-name)"
ALB_HOSTED_ZONE_ID="$(get_output "$ENVIRONMENT" backend/alb-hosted-zone-id)"
for v in HOSTED_ZONE_ID ALB_DNS_NAME ALB_HOSTED_ZONE_ID; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run dns-tls/01-acm-backend.sh and backend/04-alb.sh first."
done

# --- Alias vs. CNAME ---------------------------------------------------
# This uses an ALIAS record, not a CNAME. A CNAME can't coexist with
# other records at the same name and can't be used at a zone apex; an
# ALIAS is a Route-53-specific extension that resolves like an A record
# from the client's point of view (so it works everywhere a CNAME
# can't) while still pointing at the ALB's ever-changing underlying IPs
# via its stable DNS name. `EvaluateTargetHealth=true` means Route 53
# will stop resolving to this ALB if the ALB reports itself unhealthy —
# meaningful once there's more than one ALB/target behind it, harmless
# here with just one.
log_info "Upserting ALIAS record ${BACKEND_DOMAIN} -> ${ALB_DNS_NAME}..."
CHANGE_BATCH=$(jq -n \
  --arg name "$BACKEND_DOMAIN" \
  --arg albDns "$ALB_DNS_NAME" \
  --arg albZone "$ALB_HOSTED_ZONE_ID" \
  '{Changes:[{Action:"UPSERT",ResourceRecordSet:{
      Name:$name, Type:"A",
      AliasTarget:{HostedZoneId:$albZone, DNSName:$albDns, EvaluateTargetHealth:true}
  }}]}')

CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" --query 'ChangeInfo.Id' --output text)"

log_info "Waiting for the change to propagate to all Route 53 name servers (INSYNC)..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

log_info "DNS ready: https://${BACKEND_DOMAIN} now resolves to the ALB."
log_info "Verify manually:  dig +short ${BACKEND_DOMAIN}"
log_info "Backend networking/DNS/TLS is now fully wired. Next: backend/env-to-ssm.sh, then backend/deploy-backend.sh."
