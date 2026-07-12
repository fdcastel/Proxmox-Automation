#!/bin/bash

set -e    # Exit when any command fails

# Configures a Proxmox host to deliver system notifications (ZED, smartd, vzdump,
# and any other mail to root) through Amazon SES. Fixes the three things that
# otherwise silently swallow those alerts on a default install:
#   1. No smarthost -- Postfix tries to reach recipient MX on port 25 directly,
#      which is blocked on most networks, so everything sits deferred in the queue.
#   2. No 'root' alias -- ZED (mails "root") and smartd (-m root) target a local
#      mailbox nobody reads; their alerts never even leave the host.
#   3. IPv6 -- on hosts with no working IPv6, half the delivery attempts fail with
#      "Cannot assign requested address" before IPv4 is tried (use --ipv4-only).
#
# Relays through Amazon SES. Idempotent: safe to re-run.


#
# Constants
#

DEFAULT_SMTP_PORT=587


#
# Functions
#

function echo_err() {
    >&2 echo "$@"
}

function show_usage() {
    if [ -n "$1" ]; then
        tput setaf 1
        echo "Error: $1";
        tput sgr0
    fi
    echo_err
    echo_err "Usage: $0 --region <region> --smtp-user <user> --smtp-password <pw> --from <email> --to <email> [OPTIONS]"
    echo_err '    --region            AWS SES region. Builds email-smtp.<region>.amazonaws.com.'
    echo_err '    --smtp-user         SES SMTP username (SES console > SMTP settings). NOT an AWS access key.'
    echo_err '    --smtp-password     SES SMTP password.'
    echo_err '    --from              Sender address. Must be a verified SES identity.'
    echo_err '    --to                Recipient for host notifications (sets the root alias).'
    echo_err
    echo_err 'Additional options:'
    echo_err "    --smtp-host         Override the SMTP endpoint (default = email-smtp.<region>.amazonaws.com)."
    echo_err "    --smtp-port         SMTP submission port (default = $DEFAULT_SMTP_PORT)."
    echo_err '    --ipv4-only         Force Postfix to IPv4 (for hosts without working IPv6).'
    echo_err '    --no-flush          Do not flush the deferred mail queue after configuring.'
    echo_err '    --no-test           Do not send a test message at the end.'
    echo_err "    --help, -h          Display this help message."
    echo_err
    exit 1
}


#
# Main
#

SES_REGION=
SMTP_USER=
SMTP_PASSWORD=
MAIL_FROM=
MAIL_TO=
SMTP_HOST=
SMTP_PORT=$DEFAULT_SMTP_PORT
IPV4_ONLY=0
NO_FLUSH=0
NO_TEST=0

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --region) SES_REGION="$2"; shift; shift;;
    --smtp-user) SMTP_USER="$2"; shift; shift;;
    --smtp-password) SMTP_PASSWORD="$2"; shift; shift;;
    --from) MAIL_FROM="$2"; shift; shift;;
    --to) MAIL_TO="$2"; shift; shift;;

    --smtp-host) SMTP_HOST="$2"; shift; shift;;
    --smtp-port) SMTP_PORT="$2"; shift; shift;;
    --ipv4-only) IPV4_ONLY=1; shift;;
    --no-flush) NO_FLUSH=1; shift;;
    --no-test) NO_TEST=1; shift;;

    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [ -z "$SES_REGION" ]; then show_usage "You must inform an AWS SES region (--region)."; fi;
if [ -z "$SMTP_USER" ]; then show_usage "You must inform a SES SMTP username (--smtp-user)."; fi;
if [ -z "$SMTP_PASSWORD" ]; then show_usage "You must inform a SES SMTP password (--smtp-password)."; fi;
if [ -z "$MAIL_FROM" ]; then show_usage "You must inform a sender address (--from)."; fi;
if [ -z "$MAIL_TO" ]; then show_usage "You must inform a recipient address (--to)."; fi;

# Postfix is required (ships with Proxmox VE and Proxmox Backup Server).
if ! command -v postconf > /dev/null; then
    show_usage "Postfix not found. This script configures Postfix as an SES smarthost.";
fi

# Default the SMTP endpoint from the region unless overridden.
if [ -z "$SMTP_HOST" ]; then
    SMTP_HOST="email-smtp.$SES_REGION.amazonaws.com"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
HOSTFQDN=$(hostname -f)
echo "===== $HOSTFQDN ====="

# Postfix SASL needs the auth plugins; Debian does not pull them in by default.
if ! dpkg -s libsasl2-modules > /dev/null 2>&1; then
    echo "--- installing libsasl2-modules ---"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libsasl2-modules
fi

# Back up everything we touch (timestamped)
for f in /etc/postfix/main.cf /etc/aliases /etc/zfs/zed.d/zed.rc; do
    [ -f "$f" ] && cp -a "$f" "${f}.bak-${STAMP}"
done

# Envelope-sender + From-header rewrite.
#   The default sender is root@<host>, which SES rejects because it is not a
#   verified identity. Rewrite both envelope and header to MAIL_FROM.
#   Use sender_canonical (envelope_sender ONLY) -- do NOT use smtp_generic_maps
#   here: that rewrites RECIPIENTS as well and would silently misdeliver.
printf '/.+/    %s\n' "$MAIL_FROM" > /etc/postfix/sender_canonical
printf '/^From:.*/ REPLACE From: Proxmox %s <%s>\n' "$HOSTFQDN" "$MAIL_FROM" > /etc/postfix/header_check

# Postfix: SES smarthost, TLS, SASL auth, sender rewrite
postconf -e "relayhost = [${SMTP_HOST}]:${SMTP_PORT}"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "sender_canonical_classes = envelope_sender"
postconf -e "sender_canonical_maps = regexp:/etc/postfix/sender_canonical"
postconf -e "smtp_header_checks = regexp:/etc/postfix/header_check"

# Force IPv4 only on hosts with broken/absent IPv6 (SES itself is dual-stack).
if [ $IPV4_ONLY -eq 1 ]; then
    postconf -e "inet_protocols = ipv4"
fi

umask 077
printf '[%s]:%s %s:%s\n' "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PASSWORD" \
    > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
umask 022

postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_sasl_tls_security_options = noanonymous"

# root -> a real mailbox.  THIS is what ZED and smartd depend on.
if grep -qE '^root:' /etc/aliases; then
    sed -i -E "s|^root:.*|root: ${MAIL_TO}|" /etc/aliases
else
    echo "root: ${MAIL_TO}" >> /etc/aliases
fi
newaliases

# inet_protocols cannot be applied by "reload" -- it needs a full restart.
systemctl restart postfix

# ZED: mail root (now that root resolves) and be verbose enough that a successful
# scrub also mails -- otherwise silence is ambiguous. Skip on hosts without ZFS.
if [ -f /etc/zfs/zed.d/zed.rc ]; then
    sed -i -E 's|^[#[:space:]]*ZED_EMAIL_ADDR=.*|ZED_EMAIL_ADDR="root"|' /etc/zfs/zed.d/zed.rc
    if grep -qE '^[#[:space:]]*ZED_NOTIFY_VERBOSE=' /etc/zfs/zed.d/zed.rc; then
        sed -i -E 's|^[#[:space:]]*ZED_NOTIFY_VERBOSE=.*|ZED_NOTIFY_VERBOSE=1|' /etc/zfs/zed.d/zed.rc
    else
        echo "ZED_NOTIFY_VERBOSE=1" >> /etc/zfs/zed.d/zed.rc
    fi
    systemctl restart zfs-zed || true
fi

# smartd already carries "-m root" in /etc/smartd.conf, which now resolves. Just
# make sure it is up. Tolerate hosts where smartmontools is not installed.
systemctl reset-failed smartmontools.service 2>/dev/null || true
systemctl enable --now smartmontools.service > /dev/null 2>&1 || true

# Deliver anything already deferred in the queue.
if [ $NO_FLUSH -eq 0 ]; then
    echo "--- flushing deferred queue ---"
    postqueue -f || true
fi

# Send a test message TO root -- deliberately exercises the alias path, not just
# direct delivery, so a successful test proves ZED/smartd mail will arrive too.
if [ $NO_TEST -eq 0 ]; then
    printf 'Mail notification test from %s at %s.\nIf you can read this, ZED and smartd alerts can now reach you.\n' \
        "$HOSTFQDN" "$(date -Is)" | mail -s "[${HOSTFQDN}] mail notification test" root
fi

# Verify
echo
echo "----- effective postfix settings -----"
postconf -n | grep -E '^(relayhost|inet_protocols|smtp_sasl_auth_enable|smtp_tls_security_level|sender_canonical_maps) '
echo
echo "----- root alias -----"
grep -E '^root:' /etc/aliases
echo
echo "----- services -----"
for s in postfix zfs-zed smartmontools; do printf '%-16s %s\n' "$s" "$(systemctl is-active $s 2>/dev/null)"; done
echo
if [ -f /etc/zfs/zed.d/zed.rc ]; then
    echo "----- ZED -----"
    grep -E '^ZED_EMAIL_ADDR|^ZED_NOTIFY_VERBOSE' /etc/zfs/zed.d/zed.rc
    echo
fi
echo "----- queue (should drain within ~30s) -----"
sleep 10
mailq | tail -3
echo
echo "----- delivery log -----"
journalctl -t postfix/smtp --since '-3 min' --no-pager 2>/dev/null | tail -5 \
    || tail -5 /var/log/mail.log 2>/dev/null \
    || echo "(no mail log found)"
echo
echo "Check $MAIL_TO for '[${HOSTFQDN}] mail notification test'."
echo "If it did not arrive, look for 'status=bounced' or 'authentication failed' above."
