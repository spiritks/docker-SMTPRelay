#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "Usage: set-smtp-senders <username> <sender-address-or-@domain> [...]" >&2
  exit 64
fi

username=$1
shift
policy_dir=/etc/postfix/relay-policy
map_file="$policy_dir/sender_login_maps"

case "$username" in
  *[!A-Za-z0-9._@+-]*|'')
    echo "ERROR: username contains unsupported characters" >&2
    exit 64
    ;;
esac

mkdir -p "$policy_dir"
touch "$map_file"
chown root:postfix "$map_file"
chmod 0640 "$map_file"

for sender in "$@"; do
  sender=$(printf '%s' "$sender" | tr '[:upper:]' '[:lower:]')
  case "$sender" in
    @*.*|?*@?*.*) ;;
    *)
      echo "ERROR: sender must be an email address or an @domain pattern: $sender" >&2
      exit 64
      ;;
  esac
  # A given envelope sender may be owned by only one authenticated user.
  if awk -v key="$sender" '$1 == key { found=1 } END { exit !found }' "$map_file"; then
    existing=$(awk -v key="$sender" '$1 == key { print; exit }' "$map_file")
    echo "ERROR: sender already has a policy entry: $existing" >&2
    exit 65
  fi
  printf '%s\t%s\n' "$sender" "$username" >>"$map_file"
done

postmap "$map_file"
chown root:postfix "$map_file" "$map_file.db"
chmod 0640 "$map_file" "$map_file.db"
postfix reload
printf 'Allowed envelope senders for %s:\n' "$username"
awk -v user="$username" '$2 == user { print }' "$map_file"
