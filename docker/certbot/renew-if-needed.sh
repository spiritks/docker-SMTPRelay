#!/bin/sh
set -eu

: "${SMTP_HOSTNAME:?SMTP_HOSTNAME is required}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required}"

CERT_PATH="${CERT_PATH:-/etc/letsencrypt/live/${SMTP_HOSTNAME}/fullchain.pem}"
RENEW_BEFORE_SECONDS="${RENEW_BEFORE_SECONDS:-604800}"

certificate_state() {
  python3 - "$CERT_PATH" "$RENEW_BEFORE_SECONDS" <<'PY'
import os
import ssl
import sys
import time
from datetime import datetime, timezone

path = sys.argv[1]
threshold = int(sys.argv[2])
try:
    decoded = ssl._ssl._test_decode_cert(path)
    expires_at = ssl.cert_time_to_seconds(decoded["notAfter"])
except Exception as exc:
    print(f"certificate unreadable or invalid ({path}): {exc}", file=sys.stderr)
    raise SystemExit(20)

now = time.time()
remaining = int(expires_at - now)
expires_iso = datetime.fromtimestamp(expires_at, timezone.utc).isoformat()
if remaining > threshold:
    print(f"certificate valid; expires={expires_iso}; remaining_seconds={remaining}; renewal_threshold_seconds={threshold}")
    raise SystemExit(0)

print(f"certificate renewal required; expires={expires_iso}; remaining_seconds={remaining}; renewal_threshold_seconds={threshold}")
raise SystemExit(10)
PY
}

set +e
certificate_state
STATE=$?
set -e

case "$STATE" in
  0)
    exit 0
    ;;
  10)
    echo "Certificate expires in seven days or less; requesting renewal for ${SMTP_HOSTNAME}."
    ;;
  20)
    echo "Certificate is missing or invalid; requesting a replacement for ${SMTP_HOSTNAME}." >&2
    ;;
  *)
    echo "Unexpected certificate validation result: ${STATE}" >&2
    exit "$STATE"
    ;;
esac

certbot certonly --webroot -w /var/www/certbot \
  --email "$LETSENCRYPT_EMAIL" --agree-tos --no-eff-email \
  --cert-name "$SMTP_HOSTNAME" --force-renewal -d "$SMTP_HOSTNAME"

echo "Certificate request completed; validating the resulting certificate."
certificate_state
