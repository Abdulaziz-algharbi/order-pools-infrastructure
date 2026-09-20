#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-vpc.sh failed at line ${LINENO}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/aws-guard.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/state.sh"

ENVIRONMENT="${1:?Usage: $0 <environment> (e.g. dev)}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

# --- What this script does and why --------------------------------
# Creates (or reuses) the VPC everything else in this project lives in.
# A VPC is just an isolated private IP address range — nothing inside it
# can reach, or be reached from, anywhere else until an Internet Gateway
# and routes are explicitly wired up (03/04 in this directory).
#
# CIDR choice: VPC_CIDR (10.20.0.0/16, from config/dev.env) gives 65,536
# addresses — far more than this project needs, but a VPC's CIDR is
# essentially free to over-provision and expensive/disruptive to resize
# after subnets exist, so starting with a full /16 is the conventional
# default.

log_info "Checking for an existing VPC tagged Project=${PROJECT} Environment=${ENVIRONMENT}..."

# Idempotency check: look up by TAG, never by a remembered ID, so
# re-running this script can never create a duplicate VPC.
# shellcheck disable=SC2046
EXISTING_VPC_ID="$(aws ec2 describe-vpcs \
  --filters $(tag_filters) \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"

if [[ -n "$EXISTING_VPC_ID" && "$EXISTING_VPC_ID" != "None" ]]; then
  log_info "Found existing VPC: ${EXISTING_VPC_ID} — reusing it."
  VPC_ID="$EXISTING_VPC_ID"
else
  log_info "No existing VPC found. Creating one with CIDR ${VPC_CIDR}..."
  # `--query 'Vpc.VpcId' --output text` extracts just the ID out of the
  # full JSON response, so command substitution ($()) captures a bare
  # string (vpc-0123456789abcdef0) instead of a whole JSON document —
  # every "extract one ID" call in this project follows this pattern.
  VPC_ID="$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tag_spec vpc "${PROJECT}-${ENVIRONMENT}-vpc")" \
    --query 'Vpc.VpcId' --output text)"

  # DNS support/hostnames are OFF by default on a brand-new VPC. Both
  # are needed: DNS support so instances can resolve public hostnames at
  # all (required for the Atlas SRV lookup and for apt/npm registries),
  # DNS hostnames so the instance gets a resolvable internal hostname
  # (SSM and other AWS tooling expect this).
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "Value=true"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "Value=true"

  log_info "Created VPC: ${VPC_ID}"
fi

# Written to SSM Parameter Store (canonical) + the local outputs.env
# cache — see lib/state.sh. Every later script reads this back via
# get_output instead of you having to pass IDs around by hand.
put_output "$ENVIRONMENT" "network/vpc-id" "$VPC_ID"

log_info "Saved network/vpc-id = ${VPC_ID}"
log_info "Verify manually:  aws ec2 describe-vpcs --vpc-ids ${VPC_ID}"
log_info "Next: 02-subnets.sh reads this VPC_ID to create subnets inside it."
