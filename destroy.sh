#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "destroy.sh failed at line ${LINENO} — some resources may already be gone; ./status.sh '"'"'${ENVIRONMENT:-<env>}'"'"' shows what remains, and re-running this script is safe (every step below tolerates a resource already being absent)."' ERR

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

# =====================================================================
# S3 BUCKET DESTRUCTION POLICY (documented per project requirement):
# this script ALWAYS empties and then deletes every bucket it created
# (the frontend site bucket and the backend artifact bucket). Both hold
# only rebuildable output — a Vite build and release tarballs — never
# anything this project treats as a system of record. `delete-bucket`
# refuses to run on a non-empty bucket anyway, so "empty first" isn't
# optional if the goal is a clean teardown. Do not point either bucket
# at data you'd mind losing.
# =====================================================================

echo
log_warn "This will PERMANENTLY destroy every AWS resource this project created for environment '${ENVIRONMENT}':"
log_warn "  VPC, subnets, Internet Gateway, route table, security groups,"
log_warn "  IAM role/instance profile, EC2 instance, ALB + target group,"
log_warn "  ACM certificates, Route 53 records, S3 buckets (emptied first),"
log_warn "  CloudFront distribution, SES SMTP IAM user/group."
log_warn "This cannot be undone."
echo
read -r -p "Type the environment name ('${ENVIRONMENT}') to confirm: " CONFIRM_REPLY
[[ "$CONFIRM_REPLY" == "$ENVIRONMENT" ]] || die "Aborted — input did not match '${ENVIRONMENT}'."
echo

# --- Small helpers used throughout -------------------------------
sg_id_exists()   { aws ec2 describe-security-groups --group-ids "$1" >/dev/null 2>&1; }
vpc_id_exists()  { aws ec2 describe-vpcs --vpc-ids "$1" >/dev/null 2>&1; }

delete_alias_record_if_exists() {
  local hosted_zone_id="$1" name="$2"
  [[ -z "$hosted_zone_id" || "$hosted_zone_id" == "None" ]] && { log_warn "No hosted zone recorded — cannot look up ${name}, skipping."; return; }
  local existing
  existing="$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" \
    --query "ResourceRecordSets[?Name=='${name}.' && Type=='A']" --output json 2>/dev/null || echo '[]')"
  if [[ "$(jq 'length' <<<"$existing")" == "0" ]]; then
    log_warn "No A record for ${name} — skipping."
    return
  fi
  log_info "Deleting DNS record ${name}..."
  local record change_batch
  record="$(jq '.[0]' <<<"$existing")"
  change_batch="$(jq -n --argjson rrset "$record" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rrset}]}')"
  aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch "$change_batch" >/dev/null
}

delete_cert_if_exists() {
  local cert_arn="$1" region="$2" label="$3"
  [[ -z "$cert_arn" || "$cert_arn" == "None" ]] && { log_warn "No ${label} certificate recorded — skipping."; return; }
  if ! aws acm describe-certificate --region "$region" --certificate-arn "$cert_arn" >/dev/null 2>&1; then
    log_warn "${label} certificate already gone — skipping."
    return
  fi
  log_info "Deleting ${label} certificate ${cert_arn}..."
  aws acm delete-certificate --region "$region" --certificate-arn "$cert_arn" \
    || log_warn "Could not delete ${label} certificate — it may still be referenced by an ALB listener or CloudFront distribution. Delete it manually once that reference is gone."
}

empty_and_delete_bucket() {
  local bucket="$1" label="$2"
  [[ -z "$bucket" || "$bucket" == "None" ]] && { log_warn "No ${label} bucket recorded — skipping."; return; }
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    log_warn "${label} bucket ${bucket} does not exist — skipping."
    return
  fi
  log_warn "Emptying ${label} bucket ${bucket} (see the destruction policy documented above)..."
  aws s3 rm "s3://${bucket}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "$bucket"
  log_info "${label} bucket ${bucket} deleted."
}

# =====================================================================
# Teardown, in the REVERSE of deploy.sh's dependency order: things that
# depend on other things go first (DNS records depend on the ALB/
# CloudFront they point at; the ALB depends on the VPC; nothing depends
# on the VPC itself, so it's deleted last).
# =====================================================================

HOSTED_ZONE_ID="$(get_output "$ENVIRONMENT" dns-tls/hosted-zone-id)"

log_info "--- DNS records ---"
delete_alias_record_if_exists "$HOSTED_ZONE_ID" "$FRONTEND_DOMAIN"
delete_alias_record_if_exists "$HOSTED_ZONE_ID" "$BACKEND_DOMAIN"
echo

log_info "--- CloudFront distribution ---"
DIST_ID="$(get_output "$ENVIRONMENT" frontend/distribution-id)"
if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]] && aws cloudfront get-distribution --id "$DIST_ID" >/dev/null 2>&1; then
  # A distribution must be DISABLED, and that disable must finish
  # deploying, before AWS will allow deleting it — the same slow
  # (5-15+ minute) global propagation as creating one, unavoidable here.
  GET_JSON="$(aws cloudfront get-distribution-config --id "$DIST_ID")"
  ENABLED="$(jq -r '.DistributionConfig.Enabled' <<<"$GET_JSON")"
  if [[ "$ENABLED" == "true" ]]; then
    log_info "Disabling distribution ${DIST_ID} (required before deletion)..."
    ETAG="$(jq -r '.ETag' <<<"$GET_JSON")"
    DISABLED_CONFIG_FILE="$(mktemp)"
    jq '.DistributionConfig.Enabled = false | .DistributionConfig' <<<"$GET_JSON" > "$DISABLED_CONFIG_FILE"
    aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" --distribution-config "file://${DISABLED_CONFIG_FILE}" >/dev/null
    rm -f "$DISABLED_CONFIG_FILE"
    log_info "Waiting for the disable to finish deploying globally (slow — often 5-15+ minutes)..."
    aws cloudfront wait distribution-deployed --id "$DIST_ID"
  else
    log_info "Distribution is already disabled."
  fi
  FINAL_ETAG="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'ETag' --output text)"
  log_info "Deleting distribution ${DIST_ID}..."
  aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$FINAL_ETAG"
else
  log_warn "No CloudFront distribution found — skipping."
fi
echo

log_info "--- Frontend S3 bucket ---"
empty_and_delete_bucket "$(get_output "$ENVIRONMENT" frontend/bucket-name)" "Frontend"
echo

log_info "--- Frontend ACM certificate (us-east-1) ---"
delete_cert_if_exists "$(get_output "$ENVIRONMENT" dns-tls/frontend-cert-arn)" "us-east-1" "Frontend"
echo

log_info "--- ALB and target group ---"
ALB_ARN="$(get_output "$ENVIRONMENT" backend/alb-arn)"
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]] && aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" >/dev/null 2>&1; then
  log_info "Deleting ALB ${ALB_ARN} (this also deletes its listeners)..."
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  log_info "Waiting for the ALB to finish deleting..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
else
  log_warn "No ALB found — skipping."
fi
TG_ARN="$(get_output "$ENVIRONMENT" backend/target-group-arn)"
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]] && aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" >/dev/null 2>&1; then
  log_info "Deleting target group ${TG_ARN}..."
  # delete-load-balancer above is asynchronous: the API call returns
  # before the ALB's listener (and its reference to this target group)
  # has actually finished tearing down in the background. The wait
  # right above this can report the ALB itself gone from
  # describe-load-balancers slightly before that listener linkage is
  # fully released, so an immediate delete-target-group can still hit
  # ResourceInUse for a few seconds. Same shape of race as the security
  # group retry further down — retry instead of treating it as fatal.
  for attempt in 1 2 3 4 5 6; do
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && break
    [[ "$attempt" -eq 6 ]] && die "Could not delete target group ${TG_ARN} after 6 attempts — it may still be attached to a listener; check manually: aws elbv2 describe-target-groups --target-group-arns ${TG_ARN}"
    log_info "Target group still in use by a listener — retrying in 5s (attempt ${attempt}/6)..."
    sleep 5
  done
else
  log_warn "No target group found — skipping."
fi
echo

log_info "--- EC2 instance ---"
INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")"
  if [[ "$STATE" != "not-found" && "$STATE" != "terminated" ]]; then
    log_info "Terminating instance ${INSTANCE_ID} (currently: ${STATE})..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
  else
    log_warn "Instance already gone (state: ${STATE}) — skipping."
  fi
else
  log_warn "No EC2 instance recorded — skipping."
fi
echo

log_info "--- Backend artifact S3 bucket ---"
empty_and_delete_bucket "$(get_output "$ENVIRONMENT" backend/artifact-bucket-name)" "Backend artifact"
echo

log_info "--- Backend ACM certificate (${AWS_REGION}) ---"
delete_cert_if_exists "$(get_output "$ENVIRONMENT" dns-tls/backend-cert-arn)" "$AWS_REGION" "Backend"
echo

log_info "--- IAM role and instance profile ---"
ROLE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-role"
PROFILE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-profile"
POLICY_NAME="${PROJECT}-${ENVIRONMENT}-ec2-policy"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log_info "Removing role from instance profile and deleting ${PROFILE_NAME}..."
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
else
  log_warn "Instance profile ${PROFILE_NAME} not found — skipping."
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log_info "Deleting inline policy and role ${ROLE_NAME}..."
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME"
else
  log_warn "Role ${ROLE_NAME} not found — skipping."
fi
echo

log_info "--- Email: SES SMTP IAM user and group ---"
# Only the environment-scoped sending credentials are removed. The SES
# domain identity (${SES_DOMAIN:-<unset>}) and its DKIM/MAIL FROM/DMARC DNS
# records are deliberately LEFT: an identity belongs to the account +
# region, not to an environment — another environment sending from the
# same domain would silently stop working if this deleted it. It costs
# nothing to keep. To remove it for good, by hand:
#   aws sesv2 delete-email-identity --email-identity <domain>
#   (then delete its _domainkey CNAMEs and MAIL FROM MX/TXT in Route 53)
SES_SMTP_USER="${PROJECT}-${ENVIRONMENT}-ses-smtp"
SES_SENDERS_GROUP="${PROJECT}-${ENVIRONMENT}-ses-senders"
if aws iam get-user --user-name "$SES_SMTP_USER" >/dev/null 2>&1; then
  log_info "Deleting access keys, group membership and IAM user ${SES_SMTP_USER}..."
  for key_id in $(aws iam list-access-keys --user-name "$SES_SMTP_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$SES_SMTP_USER" --access-key-id "$key_id"
  done
  aws iam remove-user-from-group --user-name "$SES_SMTP_USER" --group-name "$SES_SENDERS_GROUP" 2>/dev/null || true
  aws iam delete-user --user-name "$SES_SMTP_USER"
else
  log_warn "SES SMTP user ${SES_SMTP_USER} not found — skipping."
fi
if aws iam get-group --group-name "$SES_SENDERS_GROUP" >/dev/null 2>&1; then
  log_info "Deleting IAM group ${SES_SENDERS_GROUP}..."
  aws iam delete-group-policy --group-name "$SES_SENDERS_GROUP" --policy-name "${PROJECT}-${ENVIRONMENT}-ses-send" 2>/dev/null || true
  aws iam delete-group --group-name "$SES_SENDERS_GROUP"
else
  log_warn "SES senders group ${SES_SENDERS_GROUP} not found — skipping."
fi
log_info "SES domain identity ${SES_DOMAIN:-<unset>} left in place (shared per account+region — see comment above)."
echo

log_info "--- Security groups ---"
BACKEND_SG_ID="$(get_output "$ENVIRONMENT" security/backend-sg-id)"
ALB_SG_ID="$(get_output "$ENVIRONMENT" security/alb-sg-id)"
for sg in "$BACKEND_SG_ID" "$ALB_SG_ID"; do
  [[ -z "$sg" || "$sg" == "None" ]] && continue
  if sg_id_exists "$sg"; then
    log_info "Deleting security group ${sg}..."
    # A security group can briefly fail to delete right after its last
    # attached ENI (the terminated instance's) disappears — AWS needs a
    # few seconds to release that dependency. Retrying tolerates that
    # instead of treating it as a hard failure.
    for attempt in 1 2 3 4 5; do
      aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && break
      [[ "$attempt" -eq 5 ]] && log_warn "Could not delete ${sg} after 5 attempts — delete manually: aws ec2 delete-security-group --group-id ${sg}"
      sleep 5
    done
  else
    log_warn "Security group ${sg} not found — skipping."
  fi
done
echo

log_info "--- Networking (route table, Internet Gateway, subnets, VPC) ---"
VPC_ID="$(get_output "$ENVIRONMENT" network/vpc-id)"
RT_ID="$(get_output "$ENVIRONMENT" network/public-route-table-id)"
IGW_ID="$(get_output "$ENVIRONMENT" network/igw-id)"
SUBNET_1_ID="$(get_output "$ENVIRONMENT" network/public-subnet-1-id)"
SUBNET_2_ID="$(get_output "$ENVIRONMENT" network/public-subnet-2-id)"

if [[ -n "$RT_ID" && "$RT_ID" != "None" ]] && aws ec2 describe-route-tables --route-table-ids "$RT_ID" >/dev/null 2>&1; then
  log_info "Disassociating and deleting route table ${RT_ID}..."
  ASSOC_IDS="$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text)"
  for assoc_id in $ASSOC_IDS; do
    aws ec2 disassociate-route-table --association-id "$assoc_id"
  done
  aws ec2 delete-route-table --route-table-id "$RT_ID"
else
  log_warn "Route table not found — skipping."
fi

for subnet_id in "$SUBNET_1_ID" "$SUBNET_2_ID"; do
  [[ -z "$subnet_id" || "$subnet_id" == "None" ]] && continue
  if aws ec2 describe-subnets --subnet-ids "$subnet_id" >/dev/null 2>&1; then
    log_info "Deleting subnet ${subnet_id}..."
    aws ec2 delete-subnet --subnet-id "$subnet_id"
  else
    log_warn "Subnet ${subnet_id} not found — skipping."
  fi
done

if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]] && aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" >/dev/null 2>&1; then
  log_info "Detaching and deleting Internet Gateway ${IGW_ID}..."
  [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
else
  log_warn "Internet Gateway not found — skipping."
fi

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && vpc_id_exists "$VPC_ID"; then
  log_info "Deleting VPC ${VPC_ID}..."
  aws ec2 delete-vpc --vpc-id "$VPC_ID"
else
  log_warn "VPC not found — skipping."
fi
echo

log_info "--- Cleaning up recorded state ---"
# Resource-ID state (the /state/ branch) and, deliberately, the actual
# app secrets under /backend/ too — a destroyed environment shouldn't
# leave its Atlas password or JWT secrets sitting in Parameter Store.
PARAM_NAMES="$(aws ssm get-parameters-by-path --path "/${PROJECT}/${ENVIRONMENT}/" --recursive --query 'Parameters[].Name' --output text 2>/dev/null || true)"
if [[ -n "$PARAM_NAMES" ]]; then
  # delete-parameters accepts at most 10 names per call.
  echo "$PARAM_NAMES" | tr '\t' '\n' | xargs -n 10 aws ssm delete-parameters --names >/dev/null
  log_info "Deleted all SSM parameters under /${PROJECT}/${ENVIRONMENT}/."
else
  log_warn "No SSM parameters found under /${PROJECT}/${ENVIRONMENT}/ — skipping."
fi
rm -f "${INFRA_ROOT}/environments/${ENVIRONMENT}/outputs.env"
log_info "Cleared local outputs cache for '${ENVIRONMENT}'."

echo
log_info "=========================================="
log_info " Environment '${ENVIRONMENT}' destroyed."
log_info "=========================================="
log_info "Note: config/${ENVIRONMENT}.local.env (your account pin) and config/${ENVIRONMENT}.secrets.env"
log_info "were left untouched on disk — delete them yourself if you're done with this environment for good."
