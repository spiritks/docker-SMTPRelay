#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: create-smtp-user <username> <password>" >&2
  exit 64
fi

username=$1
password=$2
: "${SMTP_HOSTNAME:?SMTP_HOSTNAME must be set}"

mkdir -p /var/lib/sasl2
printf '%s' "$password" | saslpasswd2 -p -c -u "$SMTP_HOSTNAME" "$username"
chown postfix:sasl /var/lib/sasl2/sasldb2
chmod 0640 /var/lib/sasl2/sasldb2
printf 'Created SMTP user: %s\n' "$username"
