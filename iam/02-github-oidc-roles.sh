#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-github-oidc-roles.sh failed at line ${LINENO}"' ERR

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

# GitHub owner/repo names — shared across environments, only the
# `environment:` claim in each trust policy varies per-environment.
readonly GITHUB_OWNER="Abdulaziz-algharbi"
readonly GITHUB_INFRA_REPO="order-pools-infrastructure"
readonly GITHUB_BACKEND_REPO="order-pools-backend"
readonly GITHUB_FRONTEND_REPO="order-pools-app"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
readonly OIDC_HOST="token.actions.githubusercontent.com"
readonly OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

# =====================================================================
# 1. OIDC identity provider — account-wide, created ONCE regardless of
# how many environments exist (it's not environment- or repo-specific;
# it's the trust anchor that says "AWS knows how to verify a token
# signed by GitHub Actions"). Each role below decides WHICH GitHub
# repo/environment is allowed to use that trust anchor, individually.
#
# Why OIDC instead of long-lived AWS access keys stored as GitHub
# secrets: a GitHub Actions job exchanges a short-lived, per-run signed
# token (which GitHub itself issues and AWS verifies against this
# provider) for temporary AWS credentials via sts:AssumeRoleWithWebIdentity.
# There is no static credential to leak, rotate, or accidentally commit —
# the token is worthless outside the exact run that requested it, and
# expires within minutes regardless.
# =====================================================================
log_info "Checking for an existing GitHub Actions OIDC provider..."
PROVIDER_EXISTS="$(aws iam list-open-id-connect-providers \
  --query "length(OpenIDConnectProviderList[?Arn=='${OIDC_PROVIDER_ARN}'])" --output text)"

if [[ "$PROVIDER_EXISTS" == "0" ]]; then
  log_info "Creating OIDC provider for ${OIDC_HOST}..."
  # AWS has independently verified and automatically manages the actual
  # TLS certificate chain for GitHub's OIDC endpoint since 2023 — this
  # thumbprint is still a required field on the API call, but is no
  # longer the security-critical value it was when this feature
  # launched (AWS doesn't rely on it matching a live cert byte-for-byte
  # any more). It's GitHub's long-documented root CA thumbprint, kept
  # here because the API demands *a* value.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
    --tags "Key=Project,Value=${PROJECT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" >/dev/null
else
  log_info "OIDC provider already exists — reusing it."
fi

# create_or_update_role ROLE_NAME TRUST_POLICY_JSON
# Trust policies use the `repository` and `environment` claims directly
# (not the composite `sub` string) — these are separate, well-defined
# top-level claims in every GitHub Actions OIDC token, which sidesteps
# any ambiguity about `sub`'s exact string format (which differs subtly
# for pushes vs. pull requests vs. reusable-workflow calls).
create_or_update_role() {
  local role_name="$1" trust_policy="$2"
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    log_info "Role ${role_name} already exists — updating its trust policy..."
    aws iam update-assume-role-policy --role-name "$role_name" --policy-document "$trust_policy"
  else
    log_info "Creating role ${role_name}..."
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_policy" \
      --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" \
      >/dev/null
  fi
}

put_policy() {
  local role_name="$1" policy_name="$2" policy_document="$3"
  aws iam put-role-policy --role-name "$role_name" --policy-name "$policy_name" --policy-document "$policy_document"
}

trust_policy_for() {
  local repo="$1"
  jq -n --arg oidcArn "$OIDC_PROVIDER_ARN" --arg repo "${GITHUB_OWNER}/${repo}" --arg env "$ENVIRONMENT" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: $oidcArn },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:repository": $repo,
          "token.actions.githubusercontent.com:environment": $env
        }
      }
    }]
  }'
}

# =====================================================================
# 2. order-pool-<env>-infra-deploy — the broadest role, since it runs
# deploy.sh/destroy.sh, which between them touch every AWS service this
# project uses. For a real company this would be a much larger effort
# to enumerate a fully minimal action list per service; for this
# project's scale, AWS managed "FullAccess" policies for the services it
# owns are a deliberate, documented simplification — EXCEPT for IAM,
# which gets a narrow, hand-written policy instead, because a CI role
# that can freely create/modify IAM roles and policies is a well-known
# privilege-escalation path (it could grant itself anything). That
# custom IAM policy is also deliberately scoped to exclude the very
# roles this script creates — this role can manage the EC2 instance
# role it's meant to, but not touch its own trust policy or the other
# two deploy roles.
# =====================================================================
INFRA_ROLE_NAME="${PROJECT}-${ENVIRONMENT}-infra-deploy"
create_or_update_role "$INFRA_ROLE_NAME" "$(trust_policy_for "$GITHUB_INFRA_REPO")"

for policy_arn in \
  "arn:aws:iam::aws:policy/AmazonVPCFullAccess" \
  "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess" \
  "arn:aws:iam::aws:policy/AmazonS3FullAccess" \
  "arn:aws:iam::aws:policy/CloudFrontFullAccess" \
  "arn:aws:iam::aws:policy/AmazonRoute53FullAccess" \
  "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess" \
  "arn:aws:iam::aws:policy/AmazonSSMFullAccess"; do
  aws iam attach-role-policy --role-name "$INFRA_ROLE_NAME" --policy-arn "$policy_arn"
done

INFRA_IAM_POLICY=$(jq -n \
  --arg roleArn "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-*-ec2-role" \
  --arg profileArn "arn:aws:iam::${ACCOUNT_ID}:instance-profile/${PROJECT}-*-ec2-profile" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ManageOnlyTheEc2InstanceRole",
        Effect: "Allow",
        Action: [
          "iam:CreateRole","iam:GetRole","iam:DeleteRole",
          "iam:PutRolePolicy","iam:GetRolePolicy","iam:DeleteRolePolicy",
          "iam:AttachRolePolicy","iam:DetachRolePolicy",
          "iam:CreateInstanceProfile","iam:GetInstanceProfile","iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile",
          "iam:TagRole","iam:PassRole"
        ],
        Resource: [$roleArn, $profileArn]
      }
    ]
  }')
put_policy "$INFRA_ROLE_NAME" "${PROJECT}-${ENVIRONMENT}-infra-iam-scope" "$INFRA_IAM_POLICY"

INFRA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${INFRA_ROLE_NAME}"
put_output "$ENVIRONMENT" "iam/infra-deploy-role-arn" "$INFRA_ROLE_ARN"
log_info "Infra deploy role ready: ${INFRA_ROLE_ARN}"

# =====================================================================
# 3. order-pool-<env>-frontend-deploy — tightly scoped: only the one S3
# bucket this environment's frontend uses, only the one CloudFront
# distribution, only the SSM parameters needed to look those up.
# =====================================================================
FRONTEND_ROLE_NAME="${PROJECT}-${ENVIRONMENT}-frontend-deploy"
create_or_update_role "$FRONTEND_ROLE_NAME" "$(trust_policy_for "$GITHUB_FRONTEND_REPO")"

FRONTEND_POLICY=$(jq -n \
  --arg bucketArn "arn:aws:s3:::${PROJECT}-${ENVIRONMENT}-frontend" \
  --arg paramArn "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/${ENVIRONMENT}/state/frontend/*" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "SyncFrontendBucket",
        Effect: "Allow",
        Action: ["s3:PutObject","s3:DeleteObject","s3:ListBucket"],
        Resource: [$bucketArn, "\($bucketArn)/*"]
      },
      {
        Sid: "InvalidateOwnDistribution",
        Effect: "Allow",
        Action: ["cloudfront:CreateInvalidation","cloudfront:GetInvalidation"],
        Resource: "*"
      },
      {
        Sid: "ResolveOwnResourceIds",
        Effect: "Allow",
        Action: ["ssm:GetParameter","ssm:GetParametersByPath"],
        Resource: $paramArn
      }
    ]
  }')
# Note: CloudFront's CreateInvalidation/GetInvalidation actions don't
# support resource-level (per-distribution) IAM restriction — Resource
# must be "*" for these specific actions. The distribution ID this role
# can invalidate is still effectively scoped in practice, because it's
# only ever resolved from THIS environment's own SSM parameter path
# above, but be aware this specific statement is broader than the
# others if you're auditing this policy.
put_policy "$FRONTEND_ROLE_NAME" "${PROJECT}-${ENVIRONMENT}-frontend-scope" "$FRONTEND_POLICY"

FRONTEND_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${FRONTEND_ROLE_NAME}"
put_output "$ENVIRONMENT" "iam/frontend-deploy-role-arn" "$FRONTEND_ROLE_ARN"
log_info "Frontend deploy role ready: ${FRONTEND_ROLE_ARN}"

# =====================================================================
# 4. order-pool-<env>-backend-deploy — scoped to the artifact bucket,
# SSM commands against instances tagged for this project/environment
# (not a specific instance ID — IDs aren't known at policy-authoring
# time and can change if the instance is ever relaunched), and reading
# both the state/ and backend/ SSM namespaces this role needs at deploy
# time.
# =====================================================================
BACKEND_ROLE_NAME="${PROJECT}-${ENVIRONMENT}-backend-deploy"
create_or_update_role "$BACKEND_ROLE_NAME" "$(trust_policy_for "$GITHUB_BACKEND_REPO")"

BACKEND_POLICY=$(jq -n \
  --arg bucketArn "arn:aws:s3:::${PROJECT}-${ENVIRONMENT}-backend-artifacts" \
  --arg stateArn "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/${ENVIRONMENT}/state/backend/*" \
  --arg secretsArn "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/${ENVIRONMENT}/backend/*" \
  --arg documentArn "arn:aws:ssm:${AWS_REGION}::document/AWS-RunShellScript" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "UploadReleaseArtifacts",
        Effect: "Allow",
        Action: ["s3:PutObject"],
        Resource: "\($bucketArn)/*"
      },
      {
        Sid: "ResolveOwnResourceIds",
        Effect: "Allow",
        Action: ["ssm:GetParameter","ssm:GetParametersByPath"],
        Resource: $stateArn
      },
      {
        Sid: "SendDeployCommand",
        Effect: "Allow",
        Action: ["ssm:SendCommand"],
        Resource: ["arn:aws:ec2:*:*:instance/*", $documentArn],
        Condition: {
          StringEquals: { "ssm:resourceTag/Project": "order-pool", "ssm:resourceTag/Environment": "ENV_PLACEHOLDER" }
        }
      },
      {
        Sid: "ReadCommandResults",
        Effect: "Allow",
        Action: ["ssm:GetCommandInvocation","ssm:ListCommandInvocations"],
        Resource: "*"
      },
      {
        Sid: "CheckTargetHealth",
        Effect: "Allow",
        Action: ["elbv2:DescribeTargetHealth"],
        Resource: "*"
      }
    ]
  }' | sed "s/ENV_PLACEHOLDER/${ENVIRONMENT}/")
# Notes on two statements above:
#  - The `ssm:resourceTag/...` condition restricts SendCommand to EC2
#    instances tagged Project=order-pool, Environment=<this env> — the
#    exact tags every instance this project creates already carries
#    (see lib/common.sh's tag_spec) — rather than a specific instance
#    ARN, which would break the moment an instance is replaced.
#  - GetCommandInvocation/DescribeTargetHealth don't support resource-
#    level restriction to a single command ID or target group the way
#    S3/SSM-parameter actions do, so Resource is "*" for those two —
#    the SendCommand condition above is what actually bounds which
#    instances this role can ever act on in the first place.
put_policy "$BACKEND_ROLE_NAME" "${PROJECT}-${ENVIRONMENT}-backend-scope" "$BACKEND_POLICY"
# Secrets read permission (SecureString) — kept as its own statement via
# a second put-role-policy call would be equivalent; combined here isn't
# possible since PROD_MONGO_URI etc. need KMS decrypt implicitly granted
# by the default aws/ssm key policy (see iam/01-ec2-instance-role.sh's
# note on this) — no extra kms:Decrypt statement required.
BACKEND_SECRETS_POLICY=$(jq -n --arg secretsArn "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/${ENVIRONMENT}/backend/*" '{
  Version: "2012-10-17",
  Statement: [{ Sid: "PushAppSecrets", Effect: "Allow", Action: ["ssm:PutParameter","ssm:GetParameter","ssm:GetParametersByPath"], Resource: $secretsArn }]
}')
put_policy "$BACKEND_ROLE_NAME" "${PROJECT}-${ENVIRONMENT}-backend-secrets-scope" "$BACKEND_SECRETS_POLICY"

BACKEND_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${BACKEND_ROLE_NAME}"
put_output "$ENVIRONMENT" "iam/backend-deploy-role-arn" "$BACKEND_ROLE_ARN"
log_info "Backend deploy role ready: ${BACKEND_ROLE_ARN}"

echo
log_info "=========================================="
log_info " GitHub Actions OIDC setup complete"
log_info "=========================================="
log_info "Configure these as repository/environment VARIABLES (not secrets — none of these are"
log_info "sensitive, they're role ARNs) in each repo's Settings > Environments > ${ENVIRONMENT}:"
log_info ""
log_info "  ${GITHUB_INFRA_REPO}:    INFRA_DEPLOY_ROLE_ARN    = ${INFRA_ROLE_ARN}"
log_info "  ${GITHUB_FRONTEND_REPO}: FRONTEND_DEPLOY_ROLE_ARN = ${FRONTEND_ROLE_ARN}"
log_info "  ${GITHUB_BACKEND_REPO}:  BACKEND_DEPLOY_ROLE_ARN  = ${BACKEND_ROLE_ARN}"
log_info "  All three repos also need: AWS_REGION = ${AWS_REGION}"
log_info ""
log_info "Can be set via: gh variable set NAME --env ${ENVIRONMENT} --body VALUE --repo <owner>/<repo>"
