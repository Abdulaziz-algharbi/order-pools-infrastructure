#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "verify-dev.sh failed at line ${LINENO}"' ERR

# Read-only. Never creates, modifies, or deletes anything — every check
# below is a `describe-*`/`get-*`/`list-*` call or a live HTTP request.
# This formalizes the manual console walkthrough from the first
# end-to-end build (VPC through GitHub OIDC) into explicit pass/fail
# assertions, so re-verifying an environment after a change doesn't
# require re-clicking through eight AWS console pages by hand. It is
# the closest thing a plain-bash toolkit has to a test suite — not a
# replacement for actually reading `status.sh`'s live values when
# something here fails, just a fast, structured way to know WHAT failed
# before going and looking.

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/aws-guard.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/state.sh"

# Defaults to 'dev' (unlike every other script, which requires the
# environment explicitly) — this script's filename already commits to
# one environment; pass a different one explicitly if this ever gets
# reused for 'prod'.
ENVIRONMENT="${1:-dev}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

PASS=0
FAIL=0
FAILURES=()

pass() { log_info "✓ $1"; PASS=$((PASS + 1)); }
fail() { log_error "✗ $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# check_nonempty DESCRIPTION VALUE — passes if VALUE is set and isn't
# the AWS-CLI-text-output "None" placeholder for a null field.
check_nonempty() {
  local desc="$1" val="$2"
  if [[ -n "$val" && "$val" != "None" ]]; then pass "${desc} (${val})"; else fail "${desc} — not found"; fi
}

# check_eq DESCRIPTION ACTUAL EXPECTED
check_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$desc"; else fail "${desc} (expected '${expected}', got '${actual}')"; fi
}

echo
log_info "=== Network ==="
VPC_ID="$(get_output "$ENVIRONMENT" network/vpc-id)"
check_nonempty "VPC exists" "$VPC_ID"
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  ACTUAL_CIDR="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || echo "")"
  check_eq "VPC CIDR matches config (${VPC_CIDR})" "$ACTUAL_CIDR" "$VPC_CIDR"
fi

SUBNET_1_ID="$(get_output "$ENVIRONMENT" network/public-subnet-1-id)"
SUBNET_2_ID="$(get_output "$ENVIRONMENT" network/public-subnet-2-id)"
check_nonempty "Public subnet 1 exists" "$SUBNET_1_ID"
check_nonempty "Public subnet 2 exists" "$SUBNET_2_ID"
i=1
for subnet_id in "$SUBNET_1_ID" "$SUBNET_2_ID"; do
  [[ -z "$subnet_id" || "$subnet_id" == "None" ]] && { i=$((i + 1)); continue; }
  MAP_PUBLIC="$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --query 'Subnets[0].MapPublicIpOnLaunch' --output text 2>/dev/null || echo "")"
  check_eq "Subnet ${i} auto-assigns a public IP" "$MAP_PUBLIC" "True"
  i=$((i + 1))
done

IGW_ID="$(get_output "$ENVIRONMENT" network/igw-id)"
check_nonempty "Internet Gateway exists" "$IGW_ID"
if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
  IGW_STATE="$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" --query 'InternetGateways[0].Attachments[0].State' --output text 2>/dev/null || echo "")"
  check_eq "Internet Gateway attached to the VPC" "$IGW_STATE" "available"
fi

RT_ID="$(get_output "$ENVIRONMENT" network/public-route-table-id)"
check_nonempty "Public route table exists" "$RT_ID"
if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
  ROUTE_STATE="$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].State | [0]" --output text 2>/dev/null || echo "")"
  check_eq "Default route (0.0.0.0/0 -> IGW) is active" "$ROUTE_STATE" "active"
  ASSOC_COUNT="$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --query "length(RouteTables[0].Associations[?Main==\`false\`])" --output text 2>/dev/null || echo "0")"
  check_eq "Both public subnets associated with the route table" "$ASSOC_COUNT" "2"
fi

echo
log_info "=== Security groups ==="
ALB_SG_ID="$(get_output "$ENVIRONMENT" security/alb-sg-id)"
BACKEND_SG_ID="$(get_output "$ENVIRONMENT" security/backend-sg-id)"
check_nonempty "ALB security group exists" "$ALB_SG_ID"
check_nonempty "Backend security group exists" "$BACKEND_SG_ID"

if [[ -n "$ALB_SG_ID" && "$ALB_SG_ID" != "None" ]]; then
  for port in 80 443; do
    OPEN="$(aws ec2 describe-security-groups --group-ids "$ALB_SG_ID" --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`${port}\`])" --output text 2>/dev/null || echo "0")"
    check_eq "ALB SG allows ${port}/tcp inbound" "$OPEN" "1"
  done
fi

if [[ -n "$BACKEND_SG_ID" && "$BACKEND_SG_ID" != "None" ]]; then
  FROM_ALB="$(aws ec2 describe-security-groups --group-ids "$BACKEND_SG_ID" \
    --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`${BACKEND_PORT}\`].UserIdGroupPairs[] | [?GroupId=='${ALB_SG_ID}'])" --output text 2>/dev/null || echo "0")"
  check_eq "Backend SG allows ${BACKEND_PORT}/tcp only from the ALB SG" "$FROM_ALB" "1"

  FROM_ANY="$(aws ec2 describe-security-groups --group-ids "$BACKEND_SG_ID" \
    --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`${BACKEND_PORT}\`].IpRanges[] | [?CidrIp=='0.0.0.0/0'])" --output text 2>/dev/null || echo "0")"
  check_eq "Backend SG has NO 0.0.0.0/0 ingress on ${BACKEND_PORT}" "$FROM_ANY" "0"

  SSH_RULE="$(aws ec2 describe-security-groups --group-ids "$BACKEND_SG_ID" --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`22\`])" --output text 2>/dev/null || echo "0")"
  check_eq "Backend SG has NO SSH (22) ingress rule" "$SSH_RULE" "0"

  for port in 443 80 27017; do
    EGRESS="$(aws ec2 describe-security-groups --group-ids "$BACKEND_SG_ID" --query "length(SecurityGroups[0].IpPermissionsEgress[?ToPort==\`${port}\` && IpProtocol=='tcp'])" --output text 2>/dev/null || echo "0")"
    check_eq "Backend SG egress allows ${port}/tcp" "$EGRESS" "1"
  done

  DEFAULT_EGRESS="$(aws ec2 describe-security-groups --group-ids "$BACKEND_SG_ID" --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'])" --output text 2>/dev/null || echo "0")"
  check_eq "Backend SG has NO default allow-all egress" "$DEFAULT_EGRESS" "0"
fi

echo
log_info "=== IAM (EC2 instance role) ==="
EC2_ROLE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-role"
EC2_PROFILE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-profile"
if aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1; then pass "EC2 IAM role exists (${EC2_ROLE_NAME})"; else fail "EC2 IAM role missing (${EC2_ROLE_NAME})"; fi
if aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1; then pass "EC2 instance profile exists (${EC2_PROFILE_NAME})"; else fail "EC2 instance profile missing (${EC2_PROFILE_NAME})"; fi

echo
log_info "=== Backend compute ==="
INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
check_nonempty "EC2 instance recorded" "$INSTANCE_ID"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "")"
  check_eq "EC2 instance is running" "$STATE" "running"
  PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "")"
  check_nonempty "EC2 instance has a public IP (add to Atlas Network Access)" "$PUBLIC_IP"
  KEY_NAME="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName' --output text 2>/dev/null || echo "None")"
  check_eq "EC2 instance has NO SSH key pair attached" "$KEY_NAME" "None"
  IMDS_TOKENS="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text 2>/dev/null || echo "")"
  check_eq "IMDSv2 enforced (HttpTokens=required)" "$IMDS_TOKENS" "required"
fi

ARTIFACT_BUCKET="$(get_output "$ENVIRONMENT" backend/artifact-bucket-name)"
check_nonempty "Artifact bucket recorded" "$ARTIFACT_BUCKET"
if [[ -n "$ARTIFACT_BUCKET" && "$ARTIFACT_BUCKET" != "None" ]]; then
  if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then pass "Artifact bucket is accessible"; else fail "Artifact bucket is not accessible"; fi
  ARTIFACT_PAB="$(aws s3api get-public-access-block --bucket "$ARTIFACT_BUCKET" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "false")"
  check_eq "Artifact bucket blocks public access" "$ARTIFACT_PAB" "True"
fi

echo
log_info "=== Backend TLS / ALB / DNS ==="
BACKEND_CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/backend-cert-arn)"
check_nonempty "Backend ACM certificate recorded" "$BACKEND_CERT_ARN"
if [[ -n "$BACKEND_CERT_ARN" && "$BACKEND_CERT_ARN" != "None" ]]; then
  CERT_STATUS="$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$BACKEND_CERT_ARN" --query 'Certificate.Status' --output text 2>/dev/null || echo "")"
  check_eq "Backend ACM certificate is ISSUED (${AWS_REGION})" "$CERT_STATUS" "ISSUED"
fi

TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
check_nonempty "Target group recorded" "$TG_ARN"
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  HEALTH_PATH="$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].HealthCheckPath' --output text 2>/dev/null || echo "")"
  check_eq "Target group health check path is /ping" "$HEALTH_PATH" "/ping"
  TARGET_HEALTH="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "")"
  check_eq "Registered target is healthy" "$TARGET_HEALTH" "healthy"
fi

ALB_ARN="$(get_output "$ENVIRONMENT" backend/alb-arn)"
check_nonempty "ALB recorded" "$ALB_ARN"
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  ALB_STATE="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "")"
  check_eq "ALB is active" "$ALB_STATE" "active"
  L443="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "length(Listeners[?Port==\`443\`])" --output text 2>/dev/null || echo "0")"
  check_eq "ALB has an HTTPS:443 listener" "$L443" "1"
  L80="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "length(Listeners[?Port==\`80\`])" --output text 2>/dev/null || echo "0")"
  check_eq "ALB has an HTTP:80 (redirect) listener" "$L80" "1"
fi

HOSTED_ZONE_ID="$(get_output "$ENVIRONMENT" dns-tls/hosted-zone-id)"
check_nonempty "Hosted zone recorded" "$HOSTED_ZONE_ID"
if [[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]]; then
  BACKEND_RR="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --query "length(ResourceRecordSets[?Name=='${BACKEND_DOMAIN}.' && Type=='A'])" --output text 2>/dev/null || echo "0")"
  check_eq "Route 53 A record exists for ${BACKEND_DOMAIN}" "$BACKEND_RR" "1"
fi

echo
log_info "=== Frontend ==="
FRONTEND_BUCKET="$(get_output "$ENVIRONMENT" frontend/bucket-name)"
check_nonempty "Frontend bucket recorded" "$FRONTEND_BUCKET"
if [[ -n "$FRONTEND_BUCKET" && "$FRONTEND_BUCKET" != "None" ]]; then
  if aws s3api head-bucket --bucket "$FRONTEND_BUCKET" >/dev/null 2>&1; then pass "Frontend bucket is accessible"; else fail "Frontend bucket is not accessible"; fi
  FRONTEND_PAB="$(aws s3api get-public-access-block --bucket "$FRONTEND_BUCKET" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "false")"
  check_eq "Frontend bucket blocks public access" "$FRONTEND_PAB" "True"
  FRONTEND_POLICY="$(aws s3api get-bucket-policy --bucket "$FRONTEND_BUCKET" --query Policy --output text 2>/dev/null || echo "")"
  check_nonempty "Frontend bucket has a policy (scoped to CloudFront)" "${FRONTEND_POLICY:+present}"
fi

FRONTEND_CERT_ARN="$(get_output "$ENVIRONMENT" dns-tls/frontend-cert-arn)"
check_nonempty "Frontend ACM certificate recorded" "$FRONTEND_CERT_ARN"
if [[ -n "$FRONTEND_CERT_ARN" && "$FRONTEND_CERT_ARN" != "None" ]]; then
  FCERT_STATUS="$(aws acm describe-certificate --region us-east-1 --certificate-arn "$FRONTEND_CERT_ARN" --query 'Certificate.Status' --output text 2>/dev/null || echo "")"
  check_eq "Frontend ACM certificate is ISSUED (us-east-1)" "$FCERT_STATUS" "ISSUED"
fi

DIST_ID="$(get_output "$ENVIRONMENT" frontend/distribution-id)"
check_nonempty "CloudFront distribution recorded" "$DIST_ID"
if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
  DIST_STATUS="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text 2>/dev/null || echo "")"
  check_eq "CloudFront distribution is Deployed" "$DIST_STATUS" "Deployed"
  DIST_ENABLED="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DistributionConfig.Enabled' --output text 2>/dev/null || echo "")"
  check_eq "CloudFront distribution is enabled" "$DIST_ENABLED" "True"
fi

if [[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]]; then
  FRONTEND_RR="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --query "length(ResourceRecordSets[?Name=='${FRONTEND_DOMAIN}.' && Type=='A'])" --output text 2>/dev/null || echo "0")"
  check_eq "Route 53 A record exists for ${FRONTEND_DOMAIN}" "$FRONTEND_RR" "1"
fi

echo
log_info "=== Application deployment ==="
# `--query 'length(Parameters)'` on a paginated call like this one gets
# applied PER PAGE, not to the merged total — with more than one page
# of results (page size 10) it prints one length per page on separate
# lines (e.g. "10" then "7") instead of a single combined count. Letting
# the CLI's automatic pagination merge everything into one JSON document
# first, then counting with jq, sidesteps that entirely.
PARAM_COUNT="$(aws ssm get-parameters-by-path --path "/${PROJECT}/${ENVIRONMENT}/backend/" --output json 2>/dev/null | jq '.Parameters | length' || echo "0")"
if [[ "$PARAM_COUNT" -gt 0 ]]; then pass "Backend secrets present in SSM Parameter Store (${PARAM_COUNT} parameters)"; else fail "No backend secrets found under /${PROJECT}/${ENVIRONMENT}/backend/"; fi

if command -v curl >/dev/null 2>&1; then
  BACKEND_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${BACKEND_DOMAIN}/ping" 2>/dev/null || echo "000")"
  check_eq "GET https://${BACKEND_DOMAIN}/ping returns 200" "$BACKEND_CODE" "200"
  BACKEND_BODY="$(curl -s --max-time 10 "https://${BACKEND_DOMAIN}/ping" 2>/dev/null || echo "")"
  check_eq "Backend /ping response body is 'pong'" "$BACKEND_BODY" "pong"

  FRONTEND_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${FRONTEND_DOMAIN}/" 2>/dev/null || echo "000")"
  check_eq "GET https://${FRONTEND_DOMAIN}/ returns 200" "$FRONTEND_CODE" "200"
else
  log_warn "curl not found — skipping live HTTP checks."
fi

echo
log_info "=== GitHub Actions OIDC ==="
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
OIDC_EXISTS="$(aws iam list-open-id-connect-providers --query "length(OpenIDConnectProviderList[?Arn=='${OIDC_PROVIDER_ARN}'])" --output text 2>/dev/null || echo "0")"
check_eq "GitHub OIDC provider exists" "$OIDC_EXISTS" "1"

for role_suffix in infra-deploy frontend-deploy backend-deploy; do
  role_name="${PROJECT}-${ENVIRONMENT}-${role_suffix}"
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    pass "IAM role exists (${role_name})"
  else
    fail "IAM role missing (${role_name})"
  fi
done

echo
log_info "=========================================="
log_info " ${PASS} passed, ${FAIL} failed"
log_info "=========================================="
if [[ "$FAIL" -gt 0 ]]; then
  log_error "Failed checks:"
  for f in "${FAILURES[@]}"; do log_error "  - ${f}"; done
  exit 1
fi
log_info "All checks passed."
