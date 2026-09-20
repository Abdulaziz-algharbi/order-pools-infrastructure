#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-subnets.sh failed at line ${LINENO}"' ERR

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

# --- Why 2 subnets, in 2 different AZs, both PUBLIC -----------------
# An Application Load Balancer refuses to be created in fewer than 2
# Availability Zones — a hard AWS requirement (the ALB itself is an
# AWS-managed HA service that must survive a single AZ outage), not a
# style preference.
#
# Both subnets are public: this project deliberately has no NAT Gateway
# and no private subnets (see security/01-security-groups.sh for the
# compensating security-group controls) — the backend EC2 instance sits
# in one of these same public subnets as the ALB, and the security group
# is the only access boundary.
#
# AZ *names* (e.g. eu-north-1a) are never hardcoded — they map to
# different physical AZs per AWS ACCOUNT, not just per region — so this
# asks AWS which AZs exist for the configured region and picks the
# first two, alphabetically, for determinism across re-runs.
log_info "Resolving Availability Zones for region ${AWS_REGION}..."
mapfile -t AVAILABILITY_ZONES < <(aws ec2 describe-availability-zones \
  --filters "Name=region-name,Values=${AWS_REGION}" "Name=zone-type,Values=availability-zone" \
  --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | sort | head -n 2)

[[ "${#AVAILABILITY_ZONES[@]}" -ge 2 ]] || die "Region ${AWS_REGION} does not expose 2 Availability Zones — cannot build an ALB-ready subnet layout."
log_info "Using AZs: ${AVAILABILITY_ZONES[0]}, ${AVAILABILITY_ZONES[1]}"

create_or_reuse_subnet() {
  local index="$1" cidr="$2" az="$3"
  local name="${PROJECT}-${ENVIRONMENT}-public-${index}"

  local existing
  # shellcheck disable=SC2046
  existing="$(aws ec2 describe-subnets \
    --filters $(tag_filters) "Name=tag:Name,Values=${name}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    log_info "Subnet '${name}' already exists: ${existing} — reusing." >&2
    echo "$existing"
    return
  fi

  log_info "Creating subnet '${name}' (${cidr}) in ${az}..." >&2
  local subnet_id
  subnet_id="$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$cidr" \
    --availability-zone "$az" \
    --tag-specifications "$(tag_spec subnet "$name")" \
    --query 'Subnet.SubnetId' --output text)"

  # This is the other half of "public": a subnet only behaves as public
  # once (a) its route table sends 0.0.0.0/0 to an Internet Gateway
  # (04-route-tables.sh) AND (b) instances launched into it actually get
  # a public IP. This attribute automatically handles (b) for every
  # future instance, so nothing launched here can accidentally end up
  # without one.
  aws ec2 modify-subnet-attribute --subnet-id "$subnet_id" --map-public-ip-on-launch

  echo "$subnet_id"
}

SUBNET_1_ID="$(create_or_reuse_subnet 1 "${PUBLIC_SUBNET_CIDRS[0]}" "${AVAILABILITY_ZONES[0]}")"
SUBNET_2_ID="$(create_or_reuse_subnet 2 "${PUBLIC_SUBNET_CIDRS[1]}" "${AVAILABILITY_ZONES[1]}")"

put_output "$ENVIRONMENT" "network/public-subnet-1-id" "$SUBNET_1_ID"
put_output "$ENVIRONMENT" "network/public-subnet-2-id" "$SUBNET_2_ID"
put_output "$ENVIRONMENT" "network/az-1" "${AVAILABILITY_ZONES[0]}"
put_output "$ENVIRONMENT" "network/az-2" "${AVAILABILITY_ZONES[1]}"

log_info "Public subnets ready: ${SUBNET_1_ID} (${AVAILABILITY_ZONES[0]}), ${SUBNET_2_ID} (${AVAILABILITY_ZONES[1]})"
log_info "Verify manually:  aws ec2 describe-subnets --subnet-ids ${SUBNET_1_ID} ${SUBNET_2_ID}"
log_info "Next: 03-internet-gateway.sh, then 04-route-tables.sh routes these to it."
