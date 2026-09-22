#!/usr/bin/env bash
# Shared helper functions sourced by every script under infrastructure/.
# This file is never executed directly — only `source`d — so it doesn't
# get its own shebang-executed `set -Eeuo pipefail`; each caller sets
# that itself before sourcing this.
#
# PORTABILITY CONSTRAINT, for anything added to this toolkit later:
# stick to bash 3.2 features. Every script here uses
# `#!/usr/bin/env bash`, and macOS still ships bash 3.2.57 as /bin/bash
# (frozen in 2007 over GPLv3), which commonly sits AHEAD of Homebrew's
# modern bash on PATH — so the shebang can resolve to 3.2 even on a
# machine with bash 5 installed. That's not hypothetical: a `mapfile`
# call in network/02-subnets.sh failed exactly this way when deploy.sh
# spawned it as a child process. Avoid bash 4+ constructs —
# `mapfile`/`readarray` (use a `while IFS= read -r` loop), associative
# arrays (`declare -A`), `${var,,}`/`${var^^}` case conversion (use
# `tr`), and namerefs (`local -n`). GitHub Actions runners have bash 5,
# so CI will not catch a regression here; macOS is the constraint.

# --- logging -------------------------------------------------------
# Colors are skipped when stdout isn't a terminal (e.g. a GitHub Actions
# log) so raw ANSI escape codes don't pollute CI output.
if [[ -t 1 ]]; then
  C_INFO=$'\033[0;36m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_RESET=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_RESET=""
fi

log_info()  { printf '%b[INFO]%b  %s\n' "$C_INFO" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }

# die MESSAGE — print an error and exit non-zero. Used instead of
# letting `set -e` kill the script silently, so every failure path has a
# human-readable reason attached to it.
die() {
  log_error "$*"
  exit 1
}

# require_cmd NAME... — fail fast, before touching AWS at all, if a tool
# a script depends on isn't on PATH. Cheaper to fail here with one clear
# line than 40 lines into a script with a cryptic "command not found".
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '${cmd}' not found on PATH."
  done
}

# confirm PROMPT — used before anything destructive (destroy.sh, Phase
# 5). Requires the literal word "yes", not just Enter or "y", so a stray
# keypress can never confirm a deletion.
confirm() {
  local prompt="$1" reply
  read -r -p "${prompt} Type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || die "Aborted — confirmation not given."
}

# tag_spec RESOURCE_TYPE NAME — builds a --tag-specifications JSON blob
# tagging a resource with Project/Environment/ManagedBy plus a
# human-readable Name. Consistent tags are how every idempotency check
# in this project finds "does this already exist?" (via
# `describe-* --filters Tag:...`) without ever treating a remembered
# resource ID as the source of truth.
tag_spec() {
  local resource_type="$1" name="$2"
  jq -n \
    --arg rt "$resource_type" \
    --arg name "$name" \
    --arg project "$PROJECT" \
    --arg env "$ENVIRONMENT" \
    --arg managed "$TAG_MANAGED_BY" \
    '[{ResourceType:$rt, Tags:[
        {Key:"Name",Value:$name},
        {Key:"Project",Value:$project},
        {Key:"Environment",Value:$env},
        {Key:"ManagedBy",Value:$managed}
      ]}]'
}

# tag_filters — expands (unquoted, deliberately — see callers) to two
# `Name=tag:...,Values=...` tokens for `describe-*  --filters`, so a
# resource is looked up by tag rather than a hardcoded/remembered ID.
tag_filters() {
  echo "Name=tag:Project,Values=${PROJECT} Name=tag:Environment,Values=${ENVIRONMENT}"
}
