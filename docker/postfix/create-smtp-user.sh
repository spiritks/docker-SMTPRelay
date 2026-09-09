#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: create-smtp-user <username> <password>" >&2
  exit 64
fi

username=$1
password=$2
: "${SMTP_HOSTNAME:?SMTP_HOSTNAME must be set}"

db=/var/lib/sasl2/sasldb2
mkdir -p /var/lib/sasl2
# saslpasswd2 defaults to /etc/sasldb2 on Debian. The smtpd SASL
# configuration uses /var/lib/sasl2/sasldb2, so name the database explicitly.
printf '%s' "$password" | saslpasswd2 -p -c -f "$db" -u "$SMTP_HOSTNAME" "$username"

if [ ! -s "$db" ]; then
  echo "ERROR: saslpasswd2 completed but did not create a valid SASL database: $db" >&2
  exit 70
fi
chown postfix:sasl "$db"
chmod 0640 "$db"
printf 'Created SMTP user: %s\n' "$username"
