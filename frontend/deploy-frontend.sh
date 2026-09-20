#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "deploy-frontend.sh failed at line ${LINENO}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/aws-guard.sh"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/lib/state.sh"

ENVIRONMENT="${1:?Usage: $0 <environment> [path-to-order-pools-app]}"
# Sibling checkout default, same convention as deploy-backend.sh.
FRONTEND_REPO_PATH="${2:-${INFRA_ROOT}/../order-pools-app}"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/common.env"
# shellcheck source=/dev/null
source "${INFRA_ROOT}/config/${ENVIRONMENT}.env"
check_account_region "$ENVIRONMENT"

FRONTEND_REPO_PATH="$(cd "$FRONTEND_REPO_PATH" && pwd)"
[[ -f "${FRONTEND_REPO_PATH}/package.json" ]] || die "No package.json at ${FRONTEND_REPO_PATH} — pass the correct order-pools-app path as the 2nd argument."

BUCKET_NAME="$(get_output "$ENVIRONMENT" frontend/bucket-name)"
DIST_ID="$(get_output "$ENVIRONMENT" frontend/distribution-id)"
for v in BUCKET_NAME DIST_ID; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || die "${v} missing — run the frontend/ and dns-tls/ scripts first."
done

# --- Why the API URL is injected here, not read from a committed file --
# order-pools-app/.env.production currently holds a RELATIVE
# VITE_API_BASE_URL (correct for the old same-origin nginx setup, wrong
# now that CloudFront/S3 and the ALB are different origins). Rather than
# hardcode one absolute URL into that committed file — which would make
# a `dev` build and a future `prod` build fight over the same value —
# this exports VITE_API_BASE_URL as a real environment variable before
# building. Vite's own documented precedence rule is that a variable
# already present in the process environment overrides anything in a
# .env file, specifically so a single command-line/CI value can target
# different backends per environment without editing tracked files.
log_info "Building frontend from ${FRONTEND_REPO_PATH} (VITE_API_BASE_URL=https://${BACKEND_DOMAIN}/api/v1)..."
(
  cd "$FRONTEND_REPO_PATH"
  export VITE_API_BASE_URL="https://${BACKEND_DOMAIN}/api/v1"
  npm ci
  npm run build
)

DIST_DIR="${FRONTEND_REPO_PATH}/dist"
[[ -f "${DIST_DIR}/index.html" ]] || die "Build did not produce dist/index.html — check the build output above."

# --- Two-pass sync: long-cache everything except index.html -----------
# Vite's build output uses content-hashed filenames (e.g.
# assets/index-a1b2c3.js), so it's safe — correct, even — to cache those
# forever: a code change always produces a NEW filename, never
# overwrites an old one. index.html is the one file that must NEVER be
# served stale, because it's the thing that references those hashed
# filenames; caching it would mean visitors' browsers keep an old
# index.html pointing at JS/CSS chunks this deploy's --delete just
# removed from the bucket, i.e. a broken app until their cache expires.
log_info "Syncing hashed assets to s3://${BUCKET_NAME} (long cache, --delete removes files from old builds)..."
aws s3 sync "$DIST_DIR" "s3://${BUCKET_NAME}" \
  --delete \
  --exclude index.html \
  --cache-control "public,max-age=31536000,immutable"

log_info "Uploading index.html separately (no-cache — must always be revalidated)..."
aws s3 cp "${DIST_DIR}/index.html" "s3://${BUCKET_NAME}/index.html" \
  --cache-control "no-cache"

# --- Invalidation --------------------------------------------------
# `/*` counts as a single invalidation path for billing purposes
# (CloudFront bills per path string requested, not per object actually
# invalidated) — the first 1,000 paths/month are free, so a full-site
# invalidation on every deploy costs, in practice, nothing for a
# project at this scale.
log_info "Creating a CloudFront invalidation (/*) on distribution ${DIST_ID}..."
INVALIDATION_ID="$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
  --query 'Invalidation.Id' --output text)"

log_info "Waiting for the invalidation to complete..."
aws cloudfront wait invalidation-completed --distribution-id "$DIST_ID" --id "$INVALIDATION_ID"

log_info "Deployment complete."
log_info "Verify:  curl -sI https://${FRONTEND_DOMAIN}/ | head -n1"
