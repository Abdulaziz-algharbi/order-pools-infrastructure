#!/usr/bin/env bash
# Pre-flight checks. Every top-level script sources this (after
# common.sh) before doing anything else — fails loudly and immediately
# rather than letting an AWS CLI call halfway through a script error out
# with little context.

require_cmd aws jq git

# check_aws_auth — confirms credentials actually work before any resource
# call, so a missing/expired `aws configure` profile produces one clear
# message instead of a confusing "UnauthorizedOperation"/"ExpiredToken"
# error from deep inside some later command.
check_aws_auth() {
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS CLI is not authenticated. Run 'aws configure' (or set AWS_PROFILE) and try again."
}

# check_account_region ENV — the single most important safety check in
# this toolkit: it's what stops './destroy.sh prod' from ever running
# against the wrong AWS account because your shell had a different
# AWS_PROFILE exported than you thought.
#
# The account ID is deliberately never hardcoded in a committed config
# file (Section 5: "avoid hard-coded account IDs"). Instead, the FIRST
# successful run for a given environment records the caller's account ID
# into config/<env>.local.env (gitignored, see .gitignore). Every run
# after that compares the live account against the pinned one and
# refuses to continue on a mismatch.
check_account_region() {
  local env="$1"
  check_aws_auth

  local pin_file="${INFRA_ROOT}/config/${env}.local.env"

  local caller_json actual_account actual_arn
  caller_json="$(aws sts get-caller-identity --output json)"
  actual_account="$(jq -r '.Account' <<<"$caller_json")"
  actual_arn="$(jq -r '.Arn' <<<"$caller_json")"

  [[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is not set — check config/${env}.env was sourced before calling check_account_region."

  if [[ ! -f "$pin_file" ]]; then
    log_warn "First run for environment '${env}' — pinning this AWS account (${actual_account}) as the only one '${env}' may ever run against."
    {
      echo "# Auto-generated on first run. Do NOT commit (see .gitignore)."
      echo "# Delete this file only if you deliberately want to re-point the"
      echo "# '${env}' environment at a different AWS account."
      echo "AWS_ACCOUNT_ID_PINNED=${actual_account}"
    } > "$pin_file"
  fi

  # shellcheck disable=SC1090
  source "$pin_file"
  [[ "$actual_account" == "$AWS_ACCOUNT_ID_PINNED" ]] \
    || die "Refusing to continue: current AWS account (${actual_account}) does not match the account pinned for '${env}' (${AWS_ACCOUNT_ID_PINNED})."

  export AWS_DEFAULT_REGION="$AWS_REGION"

  log_info "AWS Account: ${actual_account} (${actual_arn})"
  log_info "AWS Region:  ${AWS_REGION}"
  log_info "Environment: ${env}"
  log_info "Project:     ${PROJECT}"
}
