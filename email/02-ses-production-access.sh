#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "02-ses-production-access.sh failed at line ${LINENO}"' ERR

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

# =====================================================================
# Request SES production access (leaving the sandbox)
# =====================================================================
# In the sandbox SES only delivers to verified addresses — fine for
# testing, but a real user registering can't receive their verification
# email. Leaving it is a request reviewed by a PERSON at AWS (usually
# within ~24h), not an instant API change, so this is its own deliberate,
# run-once script rather than a step inside email/01-ses.sh.
#
# Sandbox status is per ACCOUNT + REGION, not per environment: granting
# it here applies to everything in ${AWS_REGION} on this account.
#
# AWS may reply asking for more detail (typically about bounce and
# complaint handling) — answer in the AWS Support case it opens.

ACCOUNT_JSON="$(aws sesv2 get-account --output json)"
if [[ "$(jq -r '.ProductionAccessEnabled' <<<"$ACCOUNT_JSON")" == "true" ]]; then
  log_info "SES production access is already enabled in ${AWS_REGION} — nothing to do."
  exit 0
fi

REVIEW_STATUS="$(jq -r '.Details.ReviewDetails.Status // "NONE"' <<<"$ACCOUNT_JSON")"
if [[ "$REVIEW_STATUS" == "PENDING" ]]; then
  log_info "A production-access request is already under review (case $(jq -r '.Details.ReviewDetails.CaseId // "?"' <<<"$ACCOUNT_JSON")) — not submitting another."
  exit 0
fi
[[ "$REVIEW_STATUS" == "DENIED" ]] && log_warn "A previous request was DENIED. Read the reply in AWS Support before resubmitting."

WEBSITE_URL="https://${FRONTEND_DOMAIN}"
# What AWS's reviewers look for: transactional vs marketing, how the
# recipient list is built (only people who signed up themselves), and
# expected volume. Keep this accurate — it's a statement to AWS.
USE_CASE="Order Pool (${WEBSITE_URL}) is a B2B group-buying platform. We send transactional email only, to users of our own platform: an email-address verification link when a user registers themselves, when they request a new link, or when an administrator changes their address. Every recipient has just signed up (or had their address set) on our platform; we never send to purchased or scraped lists and send no marketing email. Expected volume is low (tens of emails per day). Links expire in 24 hours and resends are rate limited per user. Mail is sent from ${SES_FROM_ADDRESS} with DKIM and a custom MAIL FROM domain (${SES_MAIL_FROM_DOMAIN}) configured; replies go to a monitored inbox (${SES_REPLY_TO})."

echo
log_info "This submits a production-access request to AWS for account $(aws sts get-caller-identity --query Account --output text), region ${AWS_REGION}:"
log_info "  Mail type:  TRANSACTIONAL"
log_info "  Website:    ${WEBSITE_URL}"
log_info "  Use case:   ${USE_CASE}"
echo
confirm "Submit this request to AWS?"

aws sesv2 put-account-details \
  --production-access-enabled \
  --mail-type TRANSACTIONAL \
  --website-url "$WEBSITE_URL" \
  --use-case-description "$USE_CASE" \
  --contact-language EN

log_info "Submitted. AWS reviews it (usually within 24 hours) and replies by email and in AWS Support."
log_info "Check status:  aws sesv2 get-account --query '{ProductionAccess:ProductionAccessEnabled,Review:Details.ReviewDetails.Status}'"
