#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-ec2-instance-role.sh failed at line ${LINENO}"' ERR

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

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-role"
POLICY_NAME="${PROJECT}-${ENVIRONMENT}-ec2-policy"
PROFILE_NAME="${PROJECT}-${ENVIRONMENT}-ec2-profile"
ARTIFACT_BUCKET_NAME="${PROJECT}-${ENVIRONMENT}-backend-artifacts"

# --- Why this role exists --------------------------------------------
# The EC2 instance needs to act as an AWS API caller for three things,
# none of which should ever involve a long-lived access key sitting on
# its disk:
#   1. Registering with SSM Systems Manager, so it can be administered
#      (Session Manager, Run Command) with ZERO open inbound ports —
#      this is what replaces SSH entirely.
#   2. Reading its own application config/secrets out of SSM Parameter
#      Store at deploy time (JWT secrets, Atlas URI, etc.).
#   3. Downloading the backend release artifact from the private S3
#      bucket that Phase 3's deploy-backend.sh uploads it to.
# An IAM Instance Profile is how these permissions attach to an EC2
# instance: the instance calls AWS APIs using short-lived credentials
# that IAM rotates automatically, never a static key/secret pair.

log_info "Checking for existing IAM role ${ROLE_NAME}..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log_info "Role ${ROLE_NAME} already exists — reusing."
else
  log_info "Creating IAM role ${ROLE_NAME}..."
  # The trust policy says WHO can assume this role: only the EC2 service
  # itself, and only when an instance is launched with this role
  # attached. This is what stops the role from being assumable by, say,
  # a Lambda function or a principal in a different AWS account.
  TRUST_POLICY=$(jq -n '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Service: "ec2.amazonaws.com" },
      Action: "sts:AssumeRole"
    }]
  }')
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
    >/dev/null
fi

# AmazonSSMManagedInstanceCore is the AWS-managed policy documented as
# the minimum required for the SSM Agent to register an instance and
# accept Session Manager / Run Command traffic — the standard way to get
# "SSM instead of SSH", not something worth hand-rolling.
SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
log_info "Ensuring ${SSM_POLICY_ARN} is attached..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SSM_POLICY_ARN"

# The custom policy below is intentionally narrow: Resource ARNs are
# scoped to THIS project's own parameter path and THIS project's own
# artifact bucket, never "*". A leaked or misused instance credential
# can only ever read order-pool's own config and artifacts — nothing
# else in the account.
CUSTOM_POLICY_DOCUMENT=$(jq -n \
  --arg paramArn "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/${ENVIRONMENT}/backend/*" \
  --arg bucketArn "arn:aws:s3:::${ARTIFACT_BUCKET_NAME}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ReadOwnParameters",
        Effect: "Allow",
        Action: ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
        Resource: $paramArn
      },
      {
        Sid: "ReadOwnArtifacts",
        Effect: "Allow",
        Action: ["s3:GetObject"],
        Resource: "\($bucketArn)/*"
      },
      {
        Sid: "ListOwnArtifactBucket",
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: $bucketArn
      }
    ]
  }')
# Note: SecureString parameters use the AWS-managed `alias/aws/ssm` KMS
# key by default, whose key policy already permits decryption for any
# principal holding ssm:GetParameter — no separate kms:Decrypt statement
# is needed unless a customer-managed KMS key is introduced later.

log_info "Applying inline policy ${POLICY_NAME}..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$CUSTOM_POLICY_DOCUMENT"

log_info "Checking for existing instance profile ${PROFILE_NAME}..."
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log_info "Instance profile ${PROFILE_NAME} already exists — reusing."
else
  log_info "Creating instance profile ${PROFILE_NAME}..."
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  # IAM is eventually consistent — a freshly created instance profile
  # can take several seconds to become usable by `run-instances`. This
  # wait avoids a flaky "InvalidParameterValue: not authorized" failure
  # if backend/01-ec2-instance.sh is run immediately afterward.
  log_info "Waiting for instance profile to propagate..."
  sleep 10
fi

put_output "$ENVIRONMENT" "iam/ec2-role-name" "$ROLE_NAME"
put_output "$ENVIRONMENT" "iam/ec2-instance-profile-name" "$PROFILE_NAME"
put_output "$ENVIRONMENT" "iam/artifact-bucket-name" "$ARTIFACT_BUCKET_NAME"

log_info "EC2 IAM role ready: ${ROLE_NAME}"
log_info "Instance profile:   ${PROFILE_NAME}"
log_info "Verify manually:  aws iam get-role --role-name ${ROLE_NAME} && aws iam list-attached-role-policies --role-name ${ROLE_NAME}"
log_info "Next: backend/01-ec2-instance.sh attaches this instance profile to the launched instance."
