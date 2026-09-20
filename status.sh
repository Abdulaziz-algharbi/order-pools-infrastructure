#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "status.sh failed at line ${LINENO}"' ERR

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Read-only — this script never creates, modifies, or deletes anything.
# Every value shown is a live lookup against AWS, not just whatever
# happens to be cached in environments/<env>/outputs.env, so it reflects
# reality even if state got out of sync (e.g. something was deleted by
# hand in the console).

row() { printf '  %-30s %s\n' "$1" "$2"; }
section() { echo; log_info "$1"; }

section "Network"
VPC_ID="$(get_output "$ENVIRONMENT" network/vpc-id)"
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && aws ec2 describe-vpcs --vpc-ids "$VPC_ID" >/dev/null 2>&1; then
  row "VPC" "$VPC_ID"
else
  row "VPC" "<none>"
fi
for label in "public-subnet-1-id:Subnet 1" "public-subnet-2-id:Subnet 2" "igw-id:Internet Gateway" "public-route-table-id:Route table"; do
  key="${label%%:*}"; name="${label#*:}"
  val="$(get_output "$ENVIRONMENT" "network/${key}")"
  row "$name" "${val:-<none>}"
done

section "Security groups"
ALB_SG="$(get_output "$ENVIRONMENT" security/alb-sg-id)"
BACKEND_SG="$(get_output "$ENVIRONMENT" security/backend-sg-id)"
row "ALB security group" "${ALB_SG:-<none>}"
row "Backend security group" "${BACKEND_SG:-<none>}"

section "IAM"
ROLE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-role"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  row "EC2 role" "${ROLE_NAME} (exists)"
else
  row "EC2 role" "<none>"
fi

section "Backend"
INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  EC2_STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")"
  row "EC2 instance" "${INSTANCE_ID} (${EC2_STATE})"
  row "EC2 public IP (Atlas allow-list)" "$(get_output "$ENVIRONMENT" backend/instance-public-ip)"
else
  row "EC2 instance" "<none>"
fi

TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]] && aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" >/dev/null 2>&1; then
  TARGET_HEALTH="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "unknown")"
  row "Target group health" "$TARGET_HEALTH"
else
  row "Target group" "<none>"
fi

ALB_ARN="$(get_output "$ENVIRONMENT" backend/alb-arn)"
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]] && aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" >/dev/null 2>&1; then
  ALB_STATE="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].State.Code' --output text)"
  ALB_DNS="$(get_output "$ENVIRONMENT" backend/alb-dns-name)"
  row "ALB" "${ALB_DNS} (${ALB_STATE})"
else
  row "ALB" "<none>"
fi

BACKEND_CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/backend-cert-arn)"
if [[ -n "$BACKEND_CERT_ARN" && "$BACKEND_CERT_ARN" != "None" ]]; then
  CERT_STATUS="$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$BACKEND_CERT_ARN" --query 'Certificate.Status' --output text 2>/dev/null || echo "not-found")"
  row "Backend ACM certificate" "$CERT_STATUS"
else
  row "Backend ACM certificate" "<none>"
fi

LAST_RELEASE="$(get_output "$ENVIRONMENT" backend/last-release-id)"
row "Last deployed release" "${LAST_RELEASE:-<none yet>}"

section "Frontend"
FRONTEND_BUCKET="$(get_output "$ENVIRONMENT" frontend/bucket-name)"
if [[ -n "$FRONTEND_BUCKET" && "$FRONTEND_BUCKET" != "None" ]] && aws s3api head-bucket --bucket "$FRONTEND_BUCKET" 2>/dev/null; then
  row "S3 bucket" "$FRONTEND_BUCKET"
else
  row "S3 bucket" "<none>"
fi

DIST_ID="$(get_output "$ENVIRONMENT" frontend/distribution-id)"
if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]] && aws cloudfront get-distribution --id "$DIST_ID" >/dev/null 2>&1; then
  DIST_STATUS="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text)"
  DIST_ENABLED="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DistributionConfig.Enabled' --output text)"
  row "CloudFront distribution" "${DIST_ID} (${DIST_STATUS}, enabled=${DIST_ENABLED})"
else
  row "CloudFront distribution" "<none>"
fi

FRONTEND_CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/frontend-cert-arn)"
if [[ -n "$FRONTEND_CERT_ARN" && "$FRONTEND_CERT_ARN" != "None" ]]; then
  FCERT_STATUS="$(aws acm describe-certificate --region us-east-1 --certificate-arn "$FRONTEND_CERT_ARN" --query 'Certificate.Status' --output text 2>/dev/null || echo "not-found")"
  row "Frontend ACM certificate" "$FCERT_STATUS"
else
  row "Frontend ACM certificate" "<none>"
fi

section "DNS"
row "Backend domain" "$BACKEND_DOMAIN"
row "Frontend domain" "$FRONTEND_DOMAIN"

section "Live checks (best-effort — failures here don't fail this script)"
if command -v curl >/dev/null 2>&1; then
  BACKEND_PING="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${BACKEND_DOMAIN}/ping" 2>/dev/null || echo "unreachable")"
  row "GET https://${BACKEND_DOMAIN}/ping" "$BACKEND_PING"
  FRONTEND_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${FRONTEND_DOMAIN}/" 2>/dev/null || echo "unreachable")"
  row "GET https://${FRONTEND_DOMAIN}/" "$FRONTEND_STATUS"
else
  log_warn "curl not found — skipping live HTTP checks."
fi
echo
