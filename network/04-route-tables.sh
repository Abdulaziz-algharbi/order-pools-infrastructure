#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "04-route-tables.sh failed at line ${LINENO}"' ERR

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
IGW_ID="$(get_output "$ENVIRONMENT" network/igw-id)"
SUBNET_1_ID="$(get_output "$ENVIRONMENT" network/public-subnet-1-id)"
SUBNET_2_ID="$(get_output "$ENVIRONMENT" network/public-subnet-2-id)"
for v in VPC_ID IGW_ID SUBNET_1_ID SUBNET_2_ID; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run 01-vpc.sh, 02-subnets.sh and 03-internet-gateway.sh first."
done

# A route table is the actual "public vs. private" switch for a subnet.
# Because this project skips a NAT Gateway entirely (the backend EC2
# instance gets a direct route out, locked down by security group
# instead — see security/01-security-groups.sh for the compensating
# controls), there is only ONE route table here, shared by both public
# subnets, carrying a single 0.0.0.0/0 -> Internet Gateway route.
log_info "Checking for an existing public route table..."
EXISTING_RT_ID="$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-public-rt" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"

if [[ -n "$EXISTING_RT_ID" && "$EXISTING_RT_ID" != "None" ]]; then
  log_info "Found existing route table: ${EXISTING_RT_ID} — reusing it."
  ROUTE_TABLE_ID="$EXISTING_RT_ID"
else
  log_info "Creating public route table..."
  ROUTE_TABLE_ID="$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table "${PROJECT}-${ENVIRONMENT}-public-rt")" \
    --query 'RouteTable.RouteTableId' --output text)"
fi

# `create-route` errors with RouteAlreadyExists if this exact route is
# already present — expected on a re-run — so check first instead of
# letting `set -e` kill the script the second time it's executed.
ROUTE_EXISTS="$(aws ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" \
  --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)"

if [[ "$ROUTE_EXISTS" == "0" ]]; then
  log_info "Adding 0.0.0.0/0 -> ${IGW_ID} route..."
  aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
else
  log_info "Default route already present — skipping."
fi

# Associating BOTH subnets with the same route table is what makes both
# of them public: every instance/ALB node launched into either one now
# has a path to the Internet Gateway.
for subnet_id in "$SUBNET_1_ID" "$SUBNET_2_ID"; do
  ALREADY_ASSOCIATED="$(aws ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" \
    --query "length(RouteTables[0].Associations[?SubnetId=='${subnet_id}'])" --output text)"
  if [[ "$ALREADY_ASSOCIATED" == "0" ]]; then
    log_info "Associating subnet ${subnet_id} with ${ROUTE_TABLE_ID}..."
    aws ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$subnet_id" >/dev/null
  else
    log_info "Subnet ${subnet_id} already associated — skipping."
  fi
done

put_output "$ENVIRONMENT" "network/public-route-table-id" "$ROUTE_TABLE_ID"
log_info "Public route table ready: ${ROUTE_TABLE_ID}"
log_info "Verify manually:  aws ec2 describe-route-tables --route-table-ids ${ROUTE_TABLE_ID}"
log_info "Networking layer complete. Next: security/01-security-groups.sh"
