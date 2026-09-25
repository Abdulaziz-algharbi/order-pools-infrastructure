#!/usr/bin/env bash
set -Eeuo pipefail
trap 'log_error "01-ses.sh failed at line ${LINENO}"' ERR

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

# openssl + xxd + base64 derive the SES SMTP password (step 6) locally,
# so the IAM secret key never leaves this machine except as that password.
require_cmd openssl xxd base64

for v in SES_DOMAIN SES_MAIL_FROM_DOMAIN SES_FROM_ADDRESS SES_FROM_NAME SES_REPLY_TO; do
  [[ -n "${!v:-}" ]] || die "${v} is not set in config/${ENVIRONMENT}.env."
done

SECRETS_FILE="${INFRA_ROOT}/config/${ENVIRONMENT}.secrets.env"
[[ -f "$SECRETS_FILE" ]] || die "Missing ${SECRETS_FILE}. Copy config/${ENVIRONMENT}.secrets.env.example to that path first — this script writes the SMTP_* values into it."

# =====================================================================
# What this sets up, and why SES over SMTP
# =====================================================================
# The backend sends email (currently: email-verification links) through
# nodemailer over SMTP. In AWS that means Amazon SES's SMTP interface:
#
#   1. A verified DOMAIN identity (${SES_DOMAIN}) with Easy DKIM — SES
#      signs every message with a key published in DNS, which is what
#      lets Gmail/Outlook trust that mail "from" this domain really is.
#   2. A custom MAIL FROM subdomain (${SES_MAIL_FROM_DOMAIN}) with its own
#      MX + SPF records, so SPF passes for OUR domain rather than
#      amazonses.com — needed for SPF to count towards DMARC alignment.
#   3. A DMARC record, if the domain doesn't already have one.
#   4. An IAM user whose only permission is ses:SendRawEmail, as this
#      domain's From address, plus an access key converted into an SES
#      SMTP password (SMTP_USER = the key ID, SMTP_PASS = the derived
#      password), written into config/<env>.secrets.env for env-to-ssm.sh,
#      along with SMTP_REPLY_TO (SES_REPLY_TO) so replies to the no-reply
#      From address reach a real inbox.
#
# The one deliberate exception to "no long-lived keys" in this toolkit:
# SES's SMTP interface only accepts these derived IAM credentials — it
# cannot use the EC2 instance role. The alternative that could (the SES
# HTTPS API with the instance role) would mean changing the backend off
# SMTP; SMTP was chosen to keep the app provider-agnostic. The key is
# therefore scoped as tightly as SES allows (below), and lives only in
# the gitignored secrets file and an SSM SecureString.
#
# Region: SES is regional. Identities, sending quotas, sandbox status and
# SMTP credentials all belong to ${AWS_REGION} (the same region as the
# rest of this environment), and the SMTP endpoint is region-specific.
SMTP_HOST="email-smtp.${AWS_REGION}.amazonaws.com"
SMTP_PORT="587"
SMTP_FROM="${SES_FROM_NAME} <${SES_FROM_ADDRESS}>"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SMTP_USER_NAME="${PROJECT}-${ENVIRONMENT}-ses-smtp"
SENDERS_GROUP="${PROJECT}-${ENVIRONMENT}-ses-senders"
SEND_POLICY_NAME="${PROJECT}-${ENVIRONMENT}-ses-send"

# ---------------------------------------------------------------------
# 1. Domain identity (Easy DKIM)
# ---------------------------------------------------------------------
if aws sesv2 get-email-identity --email-identity "$SES_DOMAIN" >/dev/null 2>&1; then
  log_info "SES domain identity ${SES_DOMAIN} already exists — reusing."
else
  log_info "Creating SES domain identity ${SES_DOMAIN} (Easy DKIM, RSA 2048)..."
  # With no --dkim-signing-attributes, SESv2 uses Easy DKIM: SES generates
  # and rotates the signing keys itself and hands back three tokens to
  # publish as CNAMEs pointing at keys it hosts.
  aws sesv2 create-email-identity \
    --email-identity "$SES_DOMAIN" \
    --tags "Key=Project,Value=${PROJECT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" >/dev/null
fi

log_info "Setting ${SES_MAIL_FROM_DOMAIN} as the custom MAIL FROM domain..."
# USE_DEFAULT_VALUE: if the MAIL FROM MX record is ever missing, SES
# falls back to its own amazonses.com MAIL FROM instead of refusing to
# send — degraded SPF alignment beats undelivered verification emails.
aws sesv2 put-email-identity-mail-from-attributes \
  --email-identity "$SES_DOMAIN" \
  --mail-from-domain "$SES_MAIL_FROM_DOMAIN" \
  --behavior-on-mx-failure USE_DEFAULT_VALUE

IDENTITY_JSON="$(aws sesv2 get-email-identity --email-identity "$SES_DOMAIN" --output json)"
DKIM_TOKENS="$(jq -r '.DkimAttributes.Tokens[]' <<<"$IDENTITY_JSON")"
[[ -n "$DKIM_TOKENS" ]] || die "SES returned no DKIM tokens for ${SES_DOMAIN} — check: aws sesv2 get-email-identity --email-identity ${SES_DOMAIN}"

# ---------------------------------------------------------------------
# 2. DNS records in Route 53
# ---------------------------------------------------------------------
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN_ROOT}." \
  --query "HostedZones[?Name=='${DOMAIN_ROOT}.'].Id | [0]" --output text | sed 's#/hostedzone/##')"
[[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] || die "No Route 53 hosted zone found for ${DOMAIN_ROOT}."

CHANGES='[]'

# queue_record NAME TYPE VALUE MODE — adds an UPSERT to the change batch
# unless it's unnecessary. MODE:
#   ours           — a record only SES uses (the DKIM CNAMEs are named
#                    after SES-issued tokens): always set it.
#   keep-existing  — a record at a name something else might already
#                    own (DMARC, the MAIL FROM MX/SPF): create it if
#                    absent, but never overwrite someone else's value —
#                    warn instead and leave it to a human.
queue_record() {
  local name="$1" type="$2" value="$3" mode="$4" current
  current="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${name}.' && Type=='${type}'].ResourceRecords[].Value" \
    --output json)"
  if [[ "$(jq -r --arg v "$value" 'index($v) != null' <<<"$current")" == "true" && "$(jq 'length' <<<"$current")" == "1" ]]; then
    log_info "${type} ${name} already correct — skipping."
    return
  fi
  if [[ "$mode" == "keep-existing" && "$(jq 'length' <<<"$current")" != "0" ]]; then
    log_warn "${type} ${name} already exists with a different value (${current}) — leaving it untouched. Wanted: ${value}"
    return
  fi
  CHANGES="$(jq --arg n "$name" --arg t "$type" --arg v "$value" \
    '. + [{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:$t,TTL:1800,ResourceRecords:[{Value:$v}]}}]' <<<"$CHANGES")"
}

# Easy DKIM: three CNAMEs, <token>._domainkey.<domain> -> <token>.dkim.amazonses.com
# (the DKIM host is dkim.amazonses.com in every region this project uses;
# only a handful of newer regions use a regional one).
for token in $DKIM_TOKENS; do
  queue_record "${token}._domainkey.${SES_DOMAIN}" CNAME "${token}.dkim.amazonses.com" ours
done

# MAIL FROM: MX routes bounces back to SES's feedback endpoint for this
# region; the SPF TXT authorizes SES's servers to send as this subdomain.
queue_record "$SES_MAIL_FROM_DOMAIN" MX "10 feedback-smtp.${AWS_REGION}.amazonses.com" keep-existing
queue_record "$SES_MAIL_FROM_DOMAIN" TXT '"v=spf1 include:amazonses.com ~all"' keep-existing

# DMARC tells receivers what to do when DKIM/SPF alignment fails.
# p=none = monitor only, never causes a rejection — safe to add to a
# domain that may send mail from elsewhere too, while still giving
# receivers (Gmail/Yahoo check for its presence) a published policy.
# If the domain already has one, it's left exactly as it is.
queue_record "_dmarc.${SES_DOMAIN}" TXT '"v=DMARC1; p=none"' keep-existing

if [[ "$(jq 'length' <<<"$CHANGES")" != "0" ]]; then
  log_info "Publishing $(jq 'length' <<<"$CHANGES") DNS record(s) to Route 53..."
  CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$(jq -n --argjson c "$CHANGES" '{Changes:$c}')" \
    --query 'ChangeInfo.Id' --output text)"
  aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
  log_info "DNS records are live in Route 53."
fi

# ---------------------------------------------------------------------
# 3. Wait for SES to verify the domain
# ---------------------------------------------------------------------
# There's no SES waiter, so this polls. DKIM verification is usually
# done within minutes, but SES allows up to 72 hours — so a timeout here
# is a warning, not a failure: everything above is already in place and
# re-running this script later just re-checks.
log_info "Waiting for SES to verify ${SES_DOMAIN} (usually a few minutes)..."
VERIFIED="false"
for _ in $(seq 1 30); do
  IDENTITY_JSON="$(aws sesv2 get-email-identity --email-identity "$SES_DOMAIN" --output json)"
  VERIFIED="$(jq -r '.VerifiedForSendingStatus' <<<"$IDENTITY_JSON")"
  [[ "$VERIFIED" == "true" ]] && break
  sleep 20
done
DKIM_STATUS="$(jq -r '.DkimAttributes.Status' <<<"$IDENTITY_JSON")"
MAIL_FROM_STATUS="$(jq -r '.MailFromAttributes.MailFromDomainStatus' <<<"$IDENTITY_JSON")"
if [[ "$VERIFIED" == "true" ]]; then
  log_info "Domain verified for sending (DKIM: ${DKIM_STATUS}, MAIL FROM: ${MAIL_FROM_STATUS})."
else
  log_warn "Not verified yet (DKIM: ${DKIM_STATUS}, MAIL FROM: ${MAIL_FROM_STATUS}). Continuing — re-run this script later to re-check."
fi

# ---------------------------------------------------------------------
# 4. IAM: a group allowed to send, and a user that belongs to it
# ---------------------------------------------------------------------
# AWS's current guidance for SMTP users is a group policy rather than an
# inline user policy. The permission is as narrow as SES allows:
#   - Action: only ses:SendRawEmail (what the SMTP interface uses).
#   - Resource: this account's SES identities in this region. `identity/*`
#     rather than just the domain, because while the account is in the
#     SES sandbox SES also authorizes against the (verified) RECIPIENT
#     identity — pinning only the domain would make every sandbox send
#     fail with AccessDenied.
#   - Condition: the From address must be exactly SES_FROM_ADDRESS, so a
#     leaked key can't send as anyone else, even another verified identity.
if aws iam get-group --group-name "$SENDERS_GROUP" >/dev/null 2>&1; then
  log_info "IAM group ${SENDERS_GROUP} already exists — reusing."
else
  log_info "Creating IAM group ${SENDERS_GROUP}..."
  aws iam create-group --group-name "$SENDERS_GROUP" >/dev/null
fi
SEND_POLICY="$(jq -n \
  --arg identities "arn:aws:ses:${AWS_REGION}:${ACCOUNT_ID}:identity/*" \
  --arg from "$SES_FROM_ADDRESS" \
  '{Version:"2012-10-17",Statement:[{
      Effect:"Allow",
      Action:"ses:SendRawEmail",
      Resource:$identities,
      Condition:{StringEquals:{"ses:FromAddress":$from}}
  }]}')"
log_info "Applying the send-only policy to ${SENDERS_GROUP} (overwritten on every run, so it always matches this script)..."
aws iam put-group-policy --group-name "$SENDERS_GROUP" --policy-name "$SEND_POLICY_NAME" --policy-document "$SEND_POLICY"

if aws iam get-user --user-name "$SMTP_USER_NAME" >/dev/null 2>&1; then
  log_info "IAM user ${SMTP_USER_NAME} already exists — reusing."
else
  log_info "Creating IAM user ${SMTP_USER_NAME} (no console access, no permissions of its own)..."
  aws iam create-user --user-name "$SMTP_USER_NAME" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENVIRONMENT}" "Key=ManagedBy,Value=${TAG_MANAGED_BY}" >/dev/null
fi
aws iam add-user-to-group --user-name "$SMTP_USER_NAME" --group-name "$SENDERS_GROUP"

# ---------------------------------------------------------------------
# 5. Credentials: reuse the key already in the secrets file if it's
#    still this user's active key; otherwise mint one.
# ---------------------------------------------------------------------
secret_value() { grep -E "^$1=" "$SECRETS_FILE" | head -n 1 | cut -d= -f2- || true; }

# set_secret KEY VALUE — replaces KEY's line in the secrets file (or
# appends it). awk reads the value from the environment rather than the
# command line, so an SMTP password full of '/', '+' and '=' needs no
# escaping and never appears in `ps` output.
set_secret() {
  local tmp
  tmp="$(mktemp)"
  KEY="$1" VALUE="$2" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$SECRETS_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SECRETS_FILE"
}

CURRENT_SMTP_USER="$(secret_value SMTP_USER)"
# shellcheck disable=SC2016  # the backticks are a JMESPath literal, not shell
ACTIVE_KEYS="$(aws iam list-access-keys --user-name "$SMTP_USER_NAME" \
  --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text)"
ALL_KEY_COUNT="$(aws iam list-access-keys --user-name "$SMTP_USER_NAME" --query 'length(AccessKeyMetadata)' --output text)"

KEY_IS_CURRENT="false"
for key_id in $ACTIVE_KEYS; do
  [[ "$key_id" == "$CURRENT_SMTP_USER" ]] && KEY_IS_CURRENT="true"
done

if [[ "$KEY_IS_CURRENT" == "true" ]]; then
  log_info "config/${ENVIRONMENT}.secrets.env already holds an active key for ${SMTP_USER_NAME} (${CURRENT_SMTP_USER}) — not minting a new one."
else
  if [[ -n "$CURRENT_SMTP_USER" ]]; then
    log_warn "config/${ENVIRONMENT}.secrets.env currently has SMTP credentials that are NOT this SES user's (SMTP_HOST=$(secret_value SMTP_HOST), SMTP_USER=${CURRENT_SMTP_USER})."
    confirm "Replace them with new AWS SES SMTP credentials?"
  fi
  [[ "$ALL_KEY_COUNT" -lt 2 ]] || die "${SMTP_USER_NAME} already has 2 access keys (the IAM maximum). Delete the one that's no longer deployed first: aws iam list-access-keys --user-name ${SMTP_USER_NAME}; aws iam delete-access-key --user-name ${SMTP_USER_NAME} --access-key-id <old-id>"

  log_info "Creating an access key for ${SMTP_USER_NAME}..."
  KEY_JSON="$(aws iam create-access-key --user-name "$SMTP_USER_NAME" --output json)"
  NEW_KEY_ID="$(jq -r '.AccessKey.AccessKeyId' <<<"$KEY_JSON")"
  NEW_SECRET="$(jq -r '.AccessKey.SecretAccessKey' <<<"$KEY_JSON")"
  unset KEY_JSON

  # ---------------------------------------------------------------
  # 6. Derive the SES SMTP password from the secret key
  # ---------------------------------------------------------------
  # AWS's documented algorithm: an HMAC-SHA256 chain over fixed strings
  # (date "11111111", the region, "ses", "aws4_request", "SendRawEmail"),
  # keyed initially with "AWS4"+secret; then a 0x04 version byte + the
  # final digest, base64-encoded. The password is region-specific — it
  # only works against this region's SMTP endpoint.
  # https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
  # (Verified against AWS's reference Python implementation.)
  hmac_sha256_hex() {
    printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary | xxd -p -c 256
  }
  signing_key="$(printf '%s' "AWS4${NEW_SECRET}" | xxd -p -c 256)"
  for part in 11111111 "$AWS_REGION" ses aws4_request SendRawEmail; do
    signing_key="$(hmac_sha256_hex "$signing_key" "$part")"
  done
  SMTP_PASSWORD="$({ printf '\004'; printf '%s' "$signing_key" | xxd -r -p; } | base64)"
  unset NEW_SECRET signing_key

  set_secret SMTP_USER "$NEW_KEY_ID"
  set_secret SMTP_PASS "$SMTP_PASSWORD"
  unset SMTP_PASSWORD
  log_info "Wrote the new SMTP credentials (key ${NEW_KEY_ID}) into config/${ENVIRONMENT}.secrets.env. The secret itself is never printed."

  for key_id in $ACTIVE_KEYS; do
    log_warn "Older key ${key_id} is still active. Once the new credentials are deployed, delete it: aws iam delete-access-key --user-name ${SMTP_USER_NAME} --access-key-id ${key_id}"
  done
fi

set_secret SMTP_HOST "$SMTP_HOST"
set_secret SMTP_PORT "$SMTP_PORT"
set_secret SMTP_FROM "$SMTP_FROM"
set_secret SMTP_REPLY_TO "$SES_REPLY_TO"

put_output "$ENVIRONMENT" "email/ses-domain" "$SES_DOMAIN"
put_output "$ENVIRONMENT" "email/smtp-iam-user" "$SMTP_USER_NAME"

# ---------------------------------------------------------------------
# 7. Sandbox status
# ---------------------------------------------------------------------
# New SES accounts start in the sandbox: they can only send TO verified
# addresses, capped at 200 emails/day. Real users can't receive a
# verification email until production access is granted.
PRODUCTION_ACCESS="$(aws sesv2 get-account --query 'ProductionAccessEnabled' --output text)"
echo
log_info "SMTP host:   ${SMTP_HOST}:${SMTP_PORT} (STARTTLS)"
log_info "From:        ${SMTP_FROM}"
log_info "Reply-To:    ${SES_REPLY_TO}"
log_info "IAM user:    ${SMTP_USER_NAME} (group ${SENDERS_GROUP})"
if [[ "$PRODUCTION_ACCESS" == "True" || "$PRODUCTION_ACCESS" == "true" ]]; then
  log_info "Account:     production access — can send to any address."
else
  log_warn "Account:     SES SANDBOX — can only send to verified addresses."
  log_warn "  To test now, verify a recipient (SES emails it a confirmation link):"
  log_warn "    aws sesv2 create-email-identity --email-identity you@example.com"
  log_warn "  To send to real users: ./email/02-ses-production-access.sh ${ENVIRONMENT}"
fi
echo
log_info "Verify manually:  aws sesv2 get-email-identity --email-identity ${SES_DOMAIN} --query '{Verified:VerifiedForSendingStatus,Dkim:DkimAttributes.Status,MailFrom:MailFromAttributes.MailFromDomainStatus}'"
log_info "Next: ./backend/env-to-ssm.sh ${ENVIRONMENT}, then redeploy the backend so it picks up the SMTP_* values."
log_info "      (The backend security group must allow 587/tcp outbound — ./security/01-security-groups.sh ${ENVIRONMENT} adds it.)"
