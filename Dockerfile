FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      gettext-base \
      libsasl2-modules \
      postfix \
      rsyslog \
      sasl2-bin \
 && rm -rf /var/lib/apt/lists/* \
 && sed -ri 's|^smtp[[:space:]]+inet[[:space:]]+n|smtp      inet  n|' /etc/postfix/master.cf \
 && sed -ri 's|^submission[[:space:]]+inet[[:space:]]+n|submission inet n|' /etc/postfix/master.cf \
 && sed -ri '/^[[:space:]]*module\(load="imklog"/s/^/# Disabled in an unprivileged container: /' /etc/rsyslog.conf

COPY docker/postfix/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/postfix/create-smtp-user.sh /usr/local/bin/create-smtp-user
COPY docker/postfix/set-smtp-senders.sh /usr/local/bin/set-smtp-senders
COPY docker/postfix/repair-sasl-db.sh /usr/local/bin/repair-sasl-db
COPY docker/postfix/rsyslog.conf /etc/rsyslog.d/10-postfix.conf
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/create-smtp-user /usr/local/bin/set-smtp-senders /usr/local/bin/repair-sasl-db \
 && mkdir -p /var/log/postfix /var/lib/sasl2 \
 && chown postfix:sasl /var/lib/sasl2

EXPOSE 587
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
