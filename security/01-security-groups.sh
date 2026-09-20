#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-security-groups.sh failed at line ${LINENO}"' ERR

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

VPC_ID="$(get_output "$ENVIRONMENT" network/vpc-id)"
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "No VPC found for '${ENVIRONMENT}' — run the network/ scripts first."

find_or_create_sg() {
  local name="$1" description="$2"
  local existing
  # shellcheck disable=SC2046
  existing="$(aws ec2 describe-security-groups \
    --filters $(tag_filters) "Name=tag:Name,Values=${name}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    log_info "Security group '${name}' already exists: ${existing} — reusing." >&2
    echo "$existing"
    return
  fi
  log_info "Creating security group '${name}'..." >&2
  aws ec2 create-security-group \
    --group-name "$name" \
    --description "$description" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec security-group "$name")" \
    --query 'GroupId' --output text
}

# =====================================================================
# ALB security group — the ONE thing in this whole stack meant to accept
# traffic from arbitrary internet clients. Only 80 (redirected to 443 by
# the listener itself — backend/03-alb.sh, Phase 3) and 443 are open.
# =====================================================================
ALB_SG_ID="$(find_or_create_sg "${PROJECT}-${ENVIRONMENT}-alb-sg" "ALB - public HTTPS/HTTP")"

for port in 80 443; do
  ALREADY_OPEN="$(aws ec2 describe-security-groups --group-ids "$ALB_SG_ID" \
    --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`${port}\`])" --output text)"
  if [[ "$ALREADY_OPEN" == "0" ]]; then
    log_info "Opening ${port}/tcp on the ALB security group to 0.0.0.0/0..."
    aws ec2 authorize-security-group-ingress \
      --group-id "$ALB_SG_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null
  else
    log_info "${port}/tcp already open on ALB security group — skipping."
  fi
done
# ALB egress is left at its AWS default (all traffic allowed outbound).
# Deliberate, not an oversight: the ALB is a fully-managed AWS service,
# not code this project wrote, and it needs to reach target instances by
# private IP inside the VPC. Restricting a managed load balancer's
# egress buys no real security margin and isn't a standard pattern —
# unlike the EC2 security group below, which runs code this project is
# actually responsible for securing.

# =====================================================================
# Backend EC2 security group — implements exactly the model from the
# architecture decision:
#   Inbound:  ONLY the ALB security group, on the backend's port. No
#             CIDR-based rule exists at all — nothing on the open
#             internet can reach port 8000 directly, only traffic that
#             has already passed through the ALB.
#   Outbound: ONLY 443/tcp to the internet (MongoDB Atlas, SSM control
#             plane, apt/npm registries) plus DNS (UDP+TCP 53) scoped to
#             the VPC CIDR — not the whole internet.
#
#   Why DNS egress is required for a "443-only" instance: a
#   `mongodb+srv://` URI is resolved via a DNS SRV + TXT lookup, and
#   every HTTPS connection needs a successful DNS lookup BEFORE the TLS
#   handshake can even start. Without this rule, "outbound 443 only"
#   would silently break everything, Atlas included, because nothing
#   could resolve a hostname to connect to in the first place. Scoping
#   it to VPC_CIDR (not 0.0.0.0/0) means it can only reach the VPC's own
#   Route 53 Resolver, never an arbitrary DNS server on the internet.
# =====================================================================
EC2_SG_ID="$(find_or_create_sg "${PROJECT}-${ENVIRONMENT}-backend-sg" "Backend EC2 - ALB-only inbound, 443-only outbound")"

ALREADY_ALLOWED="$(aws ec2 describe-security-groups --group-ids "$EC2_SG_ID" \
  --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`${BACKEND_PORT}\`])" --output text)"
if [[ "$ALREADY_ALLOWED" == "0" ]]; then
  log_info "Allowing ${BACKEND_PORT}/tcp inbound on the backend security group, from the ALB security group only..."
  aws ec2 authorize-security-group-ingress \
    --group-id "$EC2_SG_ID" \
    --protocol tcp --port "$BACKEND_PORT" \
    --source-group "$ALB_SG_ID" >/dev/null
else
  log_info "${BACKEND_PORT}/tcp already allowed from the ALB security group — skipping."
fi

# `create-security-group` always creates a default "allow all outbound"
# egress rule. That default is exactly what this project's decision
# says NOT to have, so it's explicitly revoked, then replaced with only
# what's needed.
DEFAULT_EGRESS_PRESENT="$(aws ec2 describe-security-groups --group-ids "$EC2_SG_ID" \
  --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'])" --output text)"
if [[ "$DEFAULT_EGRESS_PRESENT" != "0" ]]; then
  log_info "Revoking the default allow-all egress rule on ${EC2_SG_ID}..."
  aws ec2 revoke-security-group-egress \
    --group-id "$EC2_SG_ID" \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
else
  log_info "Default allow-all egress rule already absent — skipping revoke."
fi

HTTPS_EGRESS_PRESENT="$(aws ec2 describe-security-groups --group-ids "$EC2_SG_ID" \
  --query "length(SecurityGroups[0].IpPermissionsEgress[?ToPort==\`443\` && IpProtocol=='tcp'])" --output text)"
if [[ "$HTTPS_EGRESS_PRESENT" == "0" ]]; then
  log_info "Allowing 443/tcp outbound to 0.0.0.0/0 (Atlas, SSM, apt, npm)..."
  aws ec2 authorize-security-group-egress \
    --group-id "$EC2_SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
else
  log_info "443/tcp egress already present — skipping."
fi

for proto in tcp udp; do
  DNS_EGRESS_PRESENT="$(aws ec2 describe-security-groups --group-ids "$EC2_SG_ID" \
    --query "length(SecurityGroups[0].IpPermissionsEgress[?ToPort==\`53\` && IpProtocol=='${proto}'])" --output text)"
  if [[ "$DNS_EGRESS_PRESENT" == "0" ]]; then
    log_info "Allowing DNS (${proto}/53) outbound, scoped to the VPC CIDR (${VPC_CIDR}) only..."
    aws ec2 authorize-security-group-egress \
      --group-id "$EC2_SG_ID" --protocol "$proto" --port 53 --cidr "$VPC_CIDR" >/dev/null
  else
    log_info "DNS (${proto}/53) egress already present — skipping."
  fi
done

put_output "$ENVIRONMENT" "security/alb-sg-id" "$ALB_SG_ID"
put_output "$ENVIRONMENT" "security/backend-sg-id" "$EC2_SG_ID"

log_info "ALB security group:     ${ALB_SG_ID}"
log_info "Backend security group: ${EC2_SG_ID}"
log_info "Verify manually:  aws ec2 describe-security-groups --group-ids ${ALB_SG_ID} ${EC2_SG_ID}"
log_info "Next: iam/01-ec2-instance-role.sh"
