#!/usr/bin/env bash
# Shared helper for running a script on an instance through SSM Run
# Command, sourced by backend/deploy-backend.sh and
# backend/rollback-backend.sh. Like lib/common.sh, only ever `source`d.

# ssm_run_script INSTANCE_ID COMMENT SCRIPT_FILE [TIMEOUT_SECONDS]
# Sends SCRIPT_FILE to the instance as an AWS-RunShellScript command,
# waits until it finishes, prints its stdout/stderr, and returns 0 only
# if it succeeded.
#
# Why not `aws ssm wait command-executed`: that waiter gives up after
# ~100s (20 polls x 5s) and then just reports the command as still in
# progress. A deploy pulls an image, seeds, restarts and then allows the
# app up to ~90s to answer — it can legitimately take longer than that.
# This polls the command's status itself, for up to TIMEOUT_SECONDS
# (default 600). --timeout-seconds on send-command is a different limit:
# how long the command may wait to be DELIVERED to the agent.
ssm_run_script() {
  local instance_id="$1" comment="$2" script_file="$3" timeout="${4:-600}"
  local commands_json command_id status waited=0

  commands_json="$(jq -n --arg script "$(cat "$script_file")" '{commands: [$script]}')"
  # --comment is limited to 100 characters by the API.
  command_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "${comment:0:100}" \
    --parameters "$commands_json" \
    --query 'Command.CommandId' --output text)"
  log_info "SSM command ${command_id} sent to ${instance_id}; waiting for it to finish (up to ${timeout}s)..."

  while :; do
    # get-command-invocation fails (InvocationDoesNotExist) for a moment
    # right after send-command, before the agent has picked it up.
    status="$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")"
    case "$status" in
      Pending|InProgress|Delayed) ;;
      *) break ;;
    esac
    if (( waited >= timeout )); then
      log_error "Still ${status} after ${timeout}s — giving up waiting (the command may still finish on the instance)."
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  echo "--- remote stdout ---"
  aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text
  echo "--- remote stderr ---"
  aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text
  # SSM keeps only the first 24,000 characters of each in this API; the
  # full output, if ever needed, is in the Run Command console.

  [[ "$status" == "Success" ]] || { log_error "Remote script finished with status: ${status}"; return 1; }
}

# wait_target_healthy TG_ARN INSTANCE_ID — polls the ALB target group
# for up to 100s. The instance's own health check has already passed by
# then; this confirms the ALB agrees (its checks run every few seconds
# and need a couple in a row).
wait_target_healthy() {
  local tg_arn="$1" instance_id="$2" health i
  for i in $(seq 1 20); do
    health="$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --targets "Id=${instance_id}" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
    [[ "$health" == "healthy" ]] && return 0
    [[ "$i" -eq 20 ]] && { log_error "Target group never reported healthy within 100s (last state: ${health})."; return 1; }
    sleep 5
  done
}
