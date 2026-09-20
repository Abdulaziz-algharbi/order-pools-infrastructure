#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-ec2-instance.sh failed at line ${LINENO}"' ERR

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

SUBNET_ID="$(get_output "$ENVIRONMENT" network/public-subnet-1-id)"
EC2_SG_ID="$(get_output "$ENVIRONMENT" security/backend-sg-id)"
INSTANCE_PROFILE_NAME="$(get_output "$ENVIRONMENT" iam/ec2-instance-profile-name)"
for v in SUBNET_ID EC2_SG_ID INSTANCE_PROFILE_NAME; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run the network/, security/ and iam/ scripts first."
done

INSTANCE_NAME="${PROJECT}-${ENVIRONMENT}-backend"

log_info "Checking for an existing (non-terminated) instance named ${INSTANCE_NAME}..."
# shellcheck disable=SC2046
EXISTING_INSTANCE_ID="$(aws ec2 describe-instances \
  --filters $(tag_filters) "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

if [[ -n "$EXISTING_INSTANCE_ID" && "$EXISTING_INSTANCE_ID" != "None" ]]; then
  log_info "Found existing instance: ${EXISTING_INSTANCE_ID} — reusing it."
  log_info "(This script never re-runs bootstrap on an existing instance — terminate it manually first for a clean rebuild.)"
  INSTANCE_ID="$EXISTING_INSTANCE_ID"
else
  # AMI IDs are region-specific and change every time Canonical ships a
  # patched image — hardcoding one would silently rot. Instead this
  # reads Canonical's own published SSM public parameter, which AWS
  # keeps pointed at the current Ubuntu 24.04 LTS AMI for the region
  # you're asking from.
  log_info "Resolving latest Ubuntu 24.04 LTS AMI for ${AWS_REGION}..."
  AMI_ID="$(aws ssm get-parameters \
    --names "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" \
    --query 'Parameters[0].Value' --output text)"
  log_info "Using AMI: ${AMI_ID}"

  log_info "Rendering bootstrap user-data for Node ${NODE_MAJOR_VERSION}.x, backend port ${BACKEND_PORT}..."
  USER_DATA_FILE="$(mktemp)"
  trap 'rm -f "$USER_DATA_FILE"' EXIT
  sed \
    -e "s|__NODE_MAJOR_VERSION__|${NODE_MAJOR_VERSION}|g" \
    -e "s|__PROJECT__|${PROJECT}|g" \
    "${SCRIPT_DIR}/bootstrap.sh.tmpl" > "$USER_DATA_FILE"

  log_info "Launching ${INSTANCE_TYPE} instance in subnet ${SUBNET_ID}..."
  # --associate-public-ip-address plus the subnet's own
  # map-public-ip-on-launch (set in 02-subnets.sh) both being true is
  # belt-and-suspenders for "this instance gets a public IP" — the
  # explicit flag here makes that intent visible in this script instead
  # of depending silently on subnet-level state alone.
  # --user-data runs bootstrap.sh.tmpl (rendered above) once, on first
  # boot only, as root, via cloud-init.
  # --metadata-options HttpTokens=required enforces IMDSv2 (token-based
  # instance metadata requests), closing off the classic SSRF-to-stolen-
  # credentials path that IMDSv1 is vulnerable to.
  INSTANCE_ID="$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$EC2_SG_ID" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
    --associate-public-ip-address \
    --user-data "file://${USER_DATA_FILE}" \
    --metadata-options "HttpTokens=required" \
    --tag-specifications "$(tag_spec instance "$INSTANCE_NAME")" \
    --query 'Instances[0].InstanceId' --output text)"

  log_info "Waiting for instance ${INSTANCE_ID} to reach 'running' state..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi

put_output "$ENVIRONMENT" "backend/instance-id" "$INSTANCE_ID"

# Since there's no NAT Gateway (see security/01-security-groups.sh), the
# instance's OWN public IP — not a stable NAT Gateway Elastic IP — is
# what MongoDB Atlas's Network Access list needs to allow. It's captured
# here so status.sh and the README can surface it without a separate
# manual `describe-instances` call. It stays the same for the life of a
# running instance (a plain reboot or `systemctl restart` never changes
# it) but WOULD change if this instance were ever terminated and
# relaunched — re-run this script's output check (or ./status.sh) and
# update Atlas's allow-list if that ever happens.
INSTANCE_PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
put_output "$ENVIRONMENT" "backend/instance-public-ip" "$INSTANCE_PUBLIC_IP"

log_info "Instance ready: ${INSTANCE_ID} (public IP: ${INSTANCE_PUBLIC_IP})"
log_info "Add ${INSTANCE_PUBLIC_IP} to MongoDB Atlas's Network Access list if you haven't already."
log_info "Verify manually:  aws ec2 describe-instances --instance-ids ${INSTANCE_ID} --query 'Reservations[0].Instances[0].State.Name'"
log_info ""
log_info "No SSH is exposed — to look at the bootstrap log, use SSM Session Manager:"
log_info "  aws ssm start-session --target ${INSTANCE_ID}"
log_info "  (then, on the instance) cat /var/log/order-pool-bootstrap.log"
log_info ""
log_info "Node.js and the systemd unit are installed, but the service is NOT started —"
log_info "there is no application code on the instance until Phase 3's deploy-backend.sh runs."
log_info "Next (Phase 3): backend/02-target-group.sh and backend/03-alb.sh."
