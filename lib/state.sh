#!/usr/bin/env bash
# Cross-run, cross-machine "state" for resource IDs — the thing Terraform
# would give you for free as tfstate, done explicitly since this project
# uses plain bash instead. Two tiers:
#
#   1. SSM Parameter Store, under /<project>/<env>/<key> — canonical.
#      Both your laptop AND a GitHub Actions runner can read this; a
#      local-only file never could.
#   2. environments/<env>/outputs.env — a gitignored local mirror, purely
#      so re-running a script on your own machine doesn't need a network
#      round trip for a value you just wrote 10 seconds ago.
#
# Resource IDs (subnet-xxxx, sg-xxxx, ...) are NOT secrets, so these are
# plain String parameters, not SecureString — no KMS involved here.
#
# Everything here is written under /<project>/<env>/state/<key> — a
# dedicated branch, deliberately kept separate from
# /<project>/<env>/backend/<KEY>, which is where env-to-ssm.sh puts
# actual application secrets (PORT, PROD_MONGO_URI, JWT_TOKEN_SECRET,
# ...). deploy-remote.sh.tmpl builds the app's .env file with
# `get-parameters-by-path --path /<project>/<env>/backend/` — if
# resource-ID state lived under that same prefix, every deploy would
# also write junk keys like `instance-id=i-0abc...` into the app's .env.
# The `state/` branch keeps the two namespaces from ever colliding.

put_output() {
  local env="$1" key="$2" value="$3"
  aws ssm put-parameter \
    --name "/${PROJECT}/${env}/state/${key}" \
    --type String \
    --value "$value" \
    --overwrite \
    --output json >/dev/null

  local cache_file="${INFRA_ROOT}/environments/${env}/outputs.env"
  mkdir -p "$(dirname "$cache_file")"
  local var_name
  var_name="$(echo "$key" | tr '/-' '__' | tr '[:lower:]' '[:upper:]')"
  if [[ -f "$cache_file" ]] && grep -q "^${var_name}=" "$cache_file"; then
    sed -i.bak "s|^${var_name}=.*|${var_name}=${value}|" "$cache_file" && rm -f "${cache_file}.bak"
  else
    echo "${var_name}=${value}" >> "$cache_file"
  fi
}

# get_output ENV KEY — local cache first, SSM as fallback (e.g. a fresh
# clone, or a GitHub Actions runner that has no local cache at all).
# Prints the value on stdout, or an empty string if not found.
get_output() {
  local env="$1" key="$2"
  local cache_file="${INFRA_ROOT}/environments/${env}/outputs.env"
  local var_name
  var_name="$(echo "$key" | tr '/-' '__' | tr '[:lower:]' '[:upper:]')"
  if [[ -f "$cache_file" ]] && grep -q "^${var_name}=" "$cache_file"; then
    grep "^${var_name}=" "$cache_file" | cut -d= -f2-
    return 0
  fi
  aws ssm get-parameter --name "/${PROJECT}/${env}/state/${key}" --query 'Parameter.Value' --output text 2>/dev/null || true
}
