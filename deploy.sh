#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "deploy.sh failed at line ${LINENO}"' ERR

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# --- Scope: infrastructure only, never application code ---------------
# This provisions AWS resources (network, IAM, EC2, ALB, ACM, Route 53,
# S3, CloudFront). It deliberately does NOT build/ship application code
# itself (backend/env-to-ssm.sh, backend/deploy-backend.sh,
# frontend/deploy-frontend.sh) — those need a real, filled-in
# config/<env>.secrets.env and an actual app build, and they're each app
# repo's own CI/CD pipeline's job, triggered independently of
# infrastructure changes. The one crossing of that line is at the very
# end: once everything is up, it hands over to ./deploy-apps.sh (if the
# secrets file is there), which puts the backend's config back and asks
# those pipelines to deploy main — the commits pushed while the
# environment was down were tested but never deployed.
log_info "=========================================="
log_info " Provisioning ${PROJECT} infrastructure"
log_info " Environment: ${ENVIRONMENT}"
log_info "=========================================="
echo

run_step() {
  local description="$1"; shift
  log_info "--- ${description} ---"
  "$@"
  echo
}

run_step "Network: VPC"                     "${INFRA_ROOT}/network/01-vpc.sh" "$ENVIRONMENT"
run_step "Network: subnets"                 "${INFRA_ROOT}/network/02-subnets.sh" "$ENVIRONMENT"
run_step "Network: Internet Gateway"        "${INFRA_ROOT}/network/03-internet-gateway.sh" "$ENVIRONMENT"
run_step "Network: route tables"            "${INFRA_ROOT}/network/04-route-tables.sh" "$ENVIRONMENT"
run_step "Security groups"                  "${INFRA_ROOT}/security/01-security-groups.sh" "$ENVIRONMENT"
run_step "IAM: EC2 instance role"           "${INFRA_ROOT}/iam/01-ec2-instance-role.sh" "$ENVIRONMENT"
run_step "Backend: EC2 instance"            "${INFRA_ROOT}/backend/01-ec2-instance.sh" "$ENVIRONMENT"
run_step "Backend: ECR image repository"    "${INFRA_ROOT}/backend/05-ecr-repository.sh" "$ENVIRONMENT"
run_step "Backend: CloudWatch log group"    "${INFRA_ROOT}/backend/06-log-group.sh" "$ENVIRONMENT"
run_step "DNS/TLS: backend ACM certificate" "${INFRA_ROOT}/dns-tls/01-acm-backend.sh" "$ENVIRONMENT"
run_step "Backend: target group"            "${INFRA_ROOT}/backend/03-target-group.sh" "$ENVIRONMENT"
run_step "Backend: ALB"                     "${INFRA_ROOT}/backend/04-alb.sh" "$ENVIRONMENT"
run_step "DNS/TLS: backend Route 53 record" "${INFRA_ROOT}/dns-tls/02-route53-backend-record.sh" "$ENVIRONMENT"
run_step "Frontend: S3 bucket"              "${INFRA_ROOT}/frontend/01-s3-bucket.sh" "$ENVIRONMENT"
run_step "DNS/TLS: frontend ACM certificate" "${INFRA_ROOT}/dns-tls/03-acm-frontend.sh" "$ENVIRONMENT"
run_step "Frontend: CloudFront distribution" "${INFRA_ROOT}/frontend/02-cloudfront.sh" "$ENVIRONMENT"
run_step "Frontend: bucket policy"          "${INFRA_ROOT}/frontend/03-bucket-policy.sh" "$ENVIRONMENT"
run_step "DNS/TLS: frontend Route 53 record" "${INFRA_ROOT}/dns-tls/04-route53-frontend-record.sh" "$ENVIRONMENT"

log_info "=========================================="
log_info " Infrastructure ready for '${ENVIRONMENT}'."
log_info "=========================================="
echo

if [[ -f "${INFRA_ROOT}/config/${ENVIRONMENT}.secrets.env" ]]; then
  run_step "Apps: backend config + deploy main via GitHub Actions" "${INFRA_ROOT}/deploy-apps.sh" "$ENVIRONMENT"
else
  log_info "Next (manual — application deployment, not infrastructure):"
  log_info "  1. cp config/${ENVIRONMENT}.secrets.env.example config/${ENVIRONMENT}.secrets.env"
  log_info "     # then fill in the real Atlas password, JWT secrets, etc."
  log_info "  2. ./deploy-apps.sh ${ENVIRONMENT}         # Atlas IP, SES SMTP credentials, config -> SSM,"
  log_info "     #                                        # then both apps' CI deploys main"
  log_info "     # or from this laptop instead: ./email/01-ses.sh, ./backend/env-to-ssm.sh, ./backend/deploy-backend.sh,"
  log_info "     # ./frontend/deploy-frontend.sh ${ENVIRONMENT} (needs docker and node/npm)"
  log_info "  (once, when ready for real users: ./email/02-ses-production-access.sh ${ENVIRONMENT})"
  log_info ""
fi
log_info "Check overall status any time with: ./status.sh ${ENVIRONMENT}"
