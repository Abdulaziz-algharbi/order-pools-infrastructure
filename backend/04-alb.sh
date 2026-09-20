#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "04-alb.sh failed at line ${LINENO}"' ERR

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

SUBNET_1_ID="$(get_output "$ENVIRONMENT" network/public-subnet-1-id)"
SUBNET_2_ID="$(get_output "$ENVIRONMENT" network/public-subnet-2-id)"
ALB_SG_ID="$(get_output "$ENVIRONMENT" security/alb-sg-id)"
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/backend-cert-arn)"
for v in SUBNET_1_ID SUBNET_2_ID ALB_SG_ID TG_ARN CERT_ARN; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run network/, security/, backend/03-target-group.sh and dns-tls/01-acm-backend.sh first."
done

ALB_NAME="${PROJECT}-${ENVIRONMENT}-backend-alb"

log_info "Checking for an existing ALB ${ALB_NAME}..."
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  log_info "Found existing ALB: ${ALB_ARN} — reusing it."
else
  log_info "Creating internet-facing ALB ${ALB_NAME} across both public subnets..."
  # `--scheme internet-facing` is what makes this ALB reachable from the
  # public internet at all (the counterpart, `internal`, would only be
  # reachable from inside the VPC) — this is the one deliberately public
  # entry point into the whole system, matching the architecture diagram
  # (Route 53 -> ALB -> private... here, SG-locked-but-public-subnet EC2).
  ALB_ARN="$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --type application \
    --scheme internet-facing \
    --subnets "$SUBNET_1_ID" "$SUBNET_2_ID" \
    --security-groups "$ALB_SG_ID" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"

  log_info "Waiting for the ALB to become active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
fi

ALB_DNS_NAME="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
# Every ALB in a given region shares the SAME fixed CanonicalHostedZoneId
# (it identifies "this is an ALB in eu-north-1", not this specific ALB) —
# Route 53's alias record (dns-tls/02-route53-backend-record.sh) needs
# both this value and the DNS name above to point at the ALB without a
# CNAME (aliases work at the zone apex too, which plain CNAMEs cannot).
ALB_HOSTED_ZONE_ID="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)"

HTTPS_LISTENER_EXISTS="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query "length(Listeners[?Port==\`443\`])" --output text)"
if [[ "$HTTPS_LISTENER_EXISTS" == "0" ]]; then
  log_info "Creating HTTPS:443 listener (forwards to the target group)..."
  # ELBSecurityPolicy-TLS13-1-2-2021-06 is AWS's current recommended
  # policy: supports TLS 1.3 while still allowing TLS 1.2 for older
  # clients, and excludes older/weaker ciphers by default.
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates "CertificateArn=${CERT_ARN}" \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
else
  log_info "HTTPS:443 listener already exists — skipping."
fi

HTTP_LISTENER_EXISTS="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query "length(Listeners[?Port==\`80\`])" --output text)"
if [[ "$HTTP_LISTENER_EXISTS" == "0" ]]; then
  log_info "Creating HTTP:80 listener (redirects to HTTPS)..."
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null
else
  log_info "HTTP:80 listener already exists — skipping."
fi

put_output "$ENVIRONMENT" "backend/alb-arn" "$ALB_ARN"
put_output "$ENVIRONMENT" "backend/alb-dns-name" "$ALB_DNS_NAME"
put_output "$ENVIRONMENT" "backend/alb-hosted-zone-id" "$ALB_HOSTED_ZONE_ID"

log_info "ALB ready: ${ALB_DNS_NAME}"
log_info "Verify manually:  aws elbv2 describe-listeners --load-balancer-arn ${ALB_ARN}"
log_info "Next: dns-tls/02-route53-backend-record.sh points ${BACKEND_DOMAIN} at this ALB."
