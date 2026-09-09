#!/bin/sh
set -eu

db=/var/lib/sasl2/sasldb2

if [ "${1:-}" != "--delete-all-users" ] || [ "$#" -ne 1 ]; then
  echo "Usage: repair-sasl-db --delete-all-users" >&2
  echo "Deletes a damaged SASL database; all SMTP users must then be recreated." >&2
  exit 64
fi

if [ -e "$db" ]; then
  backup="${db}.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$db" "$backup"
  rm -f "$db"
  echo "Removed $db; backup saved as $backup" >&2
else
  echo "No SASL database exists; nothing to delete." >&2
fi

echo "Create replacement accounts with: create-smtp-user USERNAME PASSWORD" >&2