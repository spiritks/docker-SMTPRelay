#!/bin/sh
set -eu

required() {
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    echo "ERROR: required environment variable $1 is empty" >&2
    exit 64
  fi
}

required SMTP_HOSTNAME
required MAIL_DOMAIN
required SMTP_HOST
required SMTP_PORT

: "${TRUSTED_NETWORKS:=127.0.0.0/8 [::1]/128}"
: "${UPSTREAM_TLS_SECURITY:=verify}"
: "${UPSTREAM_SASL_ENABLE:=no}"
# Microsoft 365 submission is reachable over IPv4. Docker's embedded resolver can
# return a temporary failure while resolving an AAAA record, which makes Postfix
# defer the message before it attempts the usable A record.
: "${SMTP_INET_PROTOCOLS:=ipv4}"
: "${TLS_CERT_PATH:=/etc/letsencrypt/live/${SMTP_HOSTNAME}/fullchain.pem}"
: "${TLS_KEY_PATH:=/etc/letsencrypt/live/${SMTP_HOSTNAME}/privkey.pem}"

if [ "$UPSTREAM_TLS_SECURITY" != "encrypt" ] && [ "$UPSTREAM_TLS_SECURITY" != "verify" ]; then
  echo "ERROR: UPSTREAM_TLS_SECURITY must be encrypt or verify" >&2
  exit 64
fi
if [ "$UPSTREAM_SASL_ENABLE" != "yes" ] && [ "$UPSTREAM_SASL_ENABLE" != "no" ]; then
  echo "ERROR: UPSTREAM_SASL_ENABLE must be yes or no" >&2
  exit 64
fi
if [ "$SMTP_INET_PROTOCOLS" != "ipv4" ] && [ "$SMTP_INET_PROTOCOLS" != "ipv6" ] && [ "$SMTP_INET_PROTOCOLS" != "all" ]; then
  echo "ERROR: SMTP_INET_PROTOCOLS must be ipv4, ipv6, or all" >&2
  exit 64
fi

# A relay must never start in plaintext mode. Bootstrap the certificate first.
if [ ! -r "$TLS_CERT_PATH" ] || [ ! -r "$TLS_KEY_PATH" ]; then
  echo "ERROR: TLS certificate/key not readable: $TLS_CERT_PATH / $TLS_KEY_PATH" >&2
  echo "Run the certbot-init profile after configuring .env, then restart postfix." >&2
  exit 78
fi

mkdir -p /var/log/postfix /var/lib/sasl2 /etc/postfix/relay-policy
chown postfix:sasl /var/lib/sasl2
# This persistent map binds each authenticated SMTP login to allowed MAIL FROM values.
# The directory is a host bind mount. Postfix check rejects configuration files
# below /etc/postfix that are writable by a non-root owner, including .gitkeep.
chown root:postfix /etc/postfix/relay-policy
chmod 0750 /etc/postfix/relay-policy
touch /etc/postfix/relay-policy/sender_login_maps
chown root:postfix /etc/postfix/relay-policy/sender_login_maps
chmod 0640 /etc/postfix/relay-policy/sender_login_maps
if [ -e /etc/postfix/relay-policy/.gitkeep ]; then
  chown root:postfix /etc/postfix/relay-policy/.gitkeep
  chmod 0640 /etc/postfix/relay-policy/.gitkeep
fi
postmap /etc/postfix/relay-policy/sender_login_maps
chown root:postfix /etc/postfix/relay-policy/sender_login_maps.db
chmod 0640 /etc/postfix/relay-policy/sender_login_maps.db
# saslpasswd2 creates a valid Berkeley DB file on first user creation. Never
# create it with touch: an empty regular file is not a Berkeley DB and causes
# Cyrus SASL to fail every AUTH attempt with "Invalid argument".
if [ -e /var/lib/sasl2/sasldb2 ] && [ ! -s /var/lib/sasl2/sasldb2 ]; then
  echo "WARNING: removing empty SASL database; create the SMTP users again" >&2
  rm -f /var/lib/sasl2/sasldb2
fi
if [ -e /var/lib/sasl2/sasldb2 ]; then
  chown postfix:sasl /var/lib/sasl2/sasldb2
  chmod 0640 /var/lib/sasl2/sasldb2
fi

cat >/etc/postfix/sasl/smtpd.conf <<'EOF'
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: /var/lib/sasl2/sasldb2
mech_list: PLAIN LOGIN
EOF
chmod 0644 /etc/postfix/sasl/smtpd.conf

postconf -e "myhostname = $SMTP_HOSTNAME"
postconf -e "mydomain = $MAIL_DOMAIN"
postconf -e 'myorigin = $mydomain'
postconf -e 'mydestination ='
postconf -e "mynetworks = $TRUSTED_NETWORKS"
postconf -e "relayhost = [$SMTP_HOST]:$SMTP_PORT"
postconf -e 'inet_interfaces = all'
postconf -e "inet_protocols = $SMTP_INET_PROTOCOLS"
postconf -e 'smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, defer_unauth_destination'
postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
postconf -e 'smtpd_sasl_auth_enable = yes'
postconf -e 'smtpd_sasl_security_options = noanonymous'
postconf -e 'smtpd_sender_login_maps = hash:/etc/postfix/relay-policy/sender_login_maps'
postconf -e 'smtpd_sender_restrictions = reject_authenticated_sender_login_mismatch'
postconf -e 'smtpd_tls_auth_only = yes'
postconf -e "smtpd_tls_cert_file = $TLS_CERT_PATH"
postconf -e "smtpd_tls_key_file = $TLS_KEY_PATH"
postconf -e 'smtpd_tls_security_level = may'
postconf -e 'smtpd_tls_loglevel = 2'
postconf -e 'smtpd_tls_received_header = yes'
postconf -e 'smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache'
postconf -e "smtp_tls_security_level = $UPSTREAM_TLS_SECURITY"
postconf -e 'smtp_tls_loglevel = 2'
postconf -e 'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt'
postconf -e 'smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache'
postconf -e "smtp_sasl_auth_enable = $UPSTREAM_SASL_ENABLE"
postconf -e 'smtp_sasl_security_options = noanonymous'
postconf -e 'smtp_sasl_tls_security_options = noanonymous'
postconf -e 'smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd'
# The Postfix smtp(8) delivery daemon is chrooted by Debian's default master.cf.
# It therefore cannot read the container's /etc/resolv.conf. Without this copy,
# getent works in `docker compose exec`, but outgoing mail fails with dsn=4.4.3.
mkdir -p /var/spool/postfix/etc
cp -L /etc/resolv.conf /var/spool/postfix/etc/resolv.conf
chmod 0644 /var/spool/postfix/etc/resolv.conf
postconf -e 'queue_run_delay = 10s'
postconf -e 'minimal_backoff_time = 10s'
postconf -e 'maximal_backoff_time = 10m'
postconf -e 'maximal_queue_lifetime = 1d'
postconf -e 'bounce_queue_lifetime = 1d'
postconf -e 'delay_warning_time = 1h'
postconf -e 'smtpd_client_connection_count_limit = 20'
postconf -e 'smtpd_client_message_rate_limit = 60'
postconf -e 'message_size_limit = 26214400'

# Enforce TLS on the public submission service even if the base smtp service exists internally.
postconf -M 'submission/inet=submission inet n       -       n       -       -       smtpd'
postconf -P 'submission/inet/syslog_name=postfix/submission'
postconf -P 'submission/inet/smtpd_tls_security_level=encrypt'
postconf -P 'submission/inet/smtpd_tls_auth_only=yes'
postconf -P 'submission/inet/smtpd_sasl_auth_enable=yes'
# Do not reject at smtpd_client_restrictions: remote clients must reach AUTH first.
# Relay permission is enforced later by smtpd_relay_restrictions.

if [ "$UPSTREAM_SASL_ENABLE" = "yes" ]; then
  if [ ! -s /run/secrets/sasl_passwd ]; then
    echo "ERROR: UPSTREAM_SASL_ENABLE=yes but /run/secrets/sasl_passwd is missing or empty" >&2
    exit 78
  fi
  cp /run/secrets/sasl_passwd /etc/postfix/sasl_passwd
  chmod 0600 /etc/postfix/sasl_passwd
  postmap /etc/postfix/sasl_passwd
  chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
fi

rsyslogd
# Stream detailed mail logs to Docker while keeping a persistent copy in the mounted log volume.
tail -n 0 -F /var/log/postfix/mail.log &
TAIL_PID=$!
trap 'kill "$TAIL_PID" 2>/dev/null || true; postfix stop; exit 0' INT TERM

postfix check
postfix start
printf '%s postfix relay started: inbound STARTTLS 587; upstream [%s]:%s; queue run delay 10s\n' "$(date -Is)" "$SMTP_HOST" "$SMTP_PORT" >&2

# Renewed certificates are picked up without recreating the container.
while :; do
  sleep 3600 & wait $! || true
  postfix reload || true
done
