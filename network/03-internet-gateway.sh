#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "03-internet-gateway.sh failed at line ${LINENO}"' ERR

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
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "No VPC found for '${ENVIRONMENT}' — run 01-vpc.sh first."

# An Internet Gateway (IGW) is the VPC's one and only door to the public
# internet — a horizontally-scaled, AWS-managed resource (no sizing, no
# hourly charge), but it does nothing until (a) attached to a VPC and
# (b) referenced as the target of a 0.0.0.0/0 route (that's
# 04-route-tables.sh — this script only creates and attaches it).
log_info "Checking for an existing Internet Gateway attached to ${VPC_ID}..."
EXISTING_IGW_ID="$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)"

if [[ -n "$EXISTING_IGW_ID" && "$EXISTING_IGW_ID" != "None" ]]; then
  log_info "Found existing Internet Gateway: ${EXISTING_IGW_ID} — reusing it."
  IGW_ID="$EXISTING_IGW_ID"
else
  log_info "Creating a new Internet Gateway..."
  IGW_ID="$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-${ENVIRONMENT}-igw")" \
    --query 'InternetGateway.InternetGatewayId' --output text)"

  log_info "Attaching ${IGW_ID} to ${VPC_ID}..."
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi

put_output "$ENVIRONMENT" "network/igw-id" "$IGW_ID"
log_info "Internet Gateway ready: ${IGW_ID}"
log_info "Verify manually:  aws ec2 describe-internet-gateways --internet-gateway-ids ${IGW_ID}"
log_info "Next: 04-route-tables.sh points a 0.0.0.0/0 route at this IGW."
