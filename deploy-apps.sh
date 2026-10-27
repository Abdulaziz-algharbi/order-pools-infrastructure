#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "deploy-apps.sh failed at line ${LINENO}"' ERR

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

# --- Why this exists: catching the apps up after a rebuild -------------
# While an environment is destroyed, every push to main in the two app
# repos is still tested, but its deploy is skipped (their workflows find
# no /order-pool/<env>/state/* and stop with a warning). So a freshly
# provisioned environment has nothing on it, and nothing would deploy
# until the next push. This deploys main's latest commit of both, through
# the same GitHub Actions workflows a push runs — tested, built and
# shipped exactly as CI always does — rather than from this laptop
# (backend/deploy-backend.sh, frontend/deploy-frontend.sh do that).
#
# The backend's config has to go back first: destroy.sh deletes every
# parameter under /order-pool/<env>/, the app's own secrets included, so
# a backend deploy with nothing under /order-pool/<env>/backend/ would
# start a container with no Atlas URI or JWT secrets. They come from
# config/<env>.secrets.env, which destroy.sh leaves on disk.
#
# deploy.sh calls this as its last step when that file exists; it's also
# safe to run on its own at any time (both steps are idempotent: the
# parameters are --overwrite, and a re-deploy of a tag already in ECR
# reuses that image).
readonly GITHUB_OWNER="Abdulaziz-algharbi"
readonly APP_REPOS="order-pools-backend order-pools-app"

require_cmd gh
SECRETS_FILE="${INFRA_ROOT}/config/${ENVIRONMENT}.secrets.env"
[[ -f "$SECRETS_FILE" ]] || die "Missing ${SECRETS_FILE} — the backend's config. Copy config/${ENVIRONMENT}.secrets.env.example to that path and fill it in first (see README §5)."
gh auth status >/dev/null 2>&1 || die "gh isn't logged in to GitHub — run 'gh auth login' (it needs the 'workflow' scope to dispatch a workflow)."

# --- Atlas's Network Access list: the one step that stays manual -------
# Atlas only accepts connections from IPs on its allow-list, and the
# backend reaches it from the instance's own public IP (no NAT Gateway,
# no Elastic IP — see README §14). Every rebuild launches a new instance
# with a new IP, and so does a stop/start, so it's read live here rather
# than from the state recorded at launch. Atlas isn't managed by this
# repo (its API needs credentials this project doesn't hold), so this
# waits for a human to add it: without it, the backend's deploy starts a
# container that can't reach its database and fails its health check.
INSTANCE_ID="$(get_output "$ENVIRONMENT" backend/instance-id)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || die "No backend instance recorded for '${ENVIRONMENT}' — run ./deploy.sh ${ENVIRONMENT} first."
INSTANCE_PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[[ -n "$INSTANCE_PUBLIC_IP" && "$INSTANCE_PUBLIC_IP" != "None" ]] || die "Instance ${INSTANCE_ID} has no public IP (is it running? ./status.sh ${ENVIRONMENT})."

log_info "--- MongoDB Atlas: allow the backend's IP ---"
log_info "The backend instance's public IP is: ${INSTANCE_PUBLIC_IP}"
log_info "In Atlas: Security → Network Access → Add IP Address → ${INSTANCE_PUBLIC_IP}/32"
log_info "(Then remove the previous instance's entry, if it's still there.)"
confirm "Is ${INSTANCE_PUBLIC_IP} on Atlas's Network Access list (and showing Active)?"
echo

log_info "--- Backend config: ${SECRETS_FILE} -> SSM ---"
"${INFRA_ROOT}/backend/env-to-ssm.sh" "$ENVIRONMENT"
echo

# `gh workflow run` only queues the run and returns; each workflow then
# does its own up-check, which now passes. Backend and frontend don't
# depend on each other to deploy, so both are queued at once.
log_info "--- Dispatching each app's deploy workflow on main ---"
for repo in $APP_REPOS; do
  gh workflow run deploy.yml --repo "${GITHUB_OWNER}/${repo}" --ref main -f environment="$ENVIRONMENT"
  log_info "Queued ${GITHUB_OWNER}/${repo}: deploy.yml on main (environment ${ENVIRONMENT})."
done
echo

log_info "Follow them with:"
for repo in $APP_REPOS; do
  log_info "  gh run list --repo ${GITHUB_OWNER}/${repo} --workflow deploy.yml --limit 1"
done
log_info "  gh run watch <run id> --repo ${GITHUB_OWNER}/<repo>"
log_info "Then: ./status.sh ${ENVIRONMENT}"
