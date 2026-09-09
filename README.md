# SMTP relay: STARTTLS in, authenticated STARTTLS to Microsoft 365

This stack exposes SMTP submission on TCP 587. It requires STARTTLS before SMTP AUTH, persists Postfix queue/SASL/log data in named Docker volumes, and relays outbound mail to Microsoft 365 using authenticated STARTTLS. Postfix scans the deferred queue every 10 seconds.

The default outbound route is Microsoft 365 authenticated client SMTP submission: `smtp.office365.com:587`, with required STARTTLS and SMTP AUTH. No Exchange Online connector is used.

The Microsoft 365 account used by this relay must have Authenticated SMTP enabled. Its permitted `From:`/envelope sender addresses are governed by Microsoft 365 mailbox permissions; keep the Postfix per-user sender authorization aligned with those permissions.

## Initial deployment

1. Copy the configuration and replace every example value:

   `cp .env.example .env`

2. Create public DNS A (and, if used, AAAA) records for `SMTP_HOSTNAME` pointing to this Docker host. TCP/80 must be reachable from the Internet during issuance and renewal.

3. Create the Microsoft 365 credential file. The username is normally the account's full UPN/email address. The single line must exactly match the configured host and port:

   `printf '%s\n' '[smtp.office365.com]:587 smtp-user@yourdomain.example:password-or-app-password' > secrets/sasl_passwd && chmod 600 secrets/sasl_passwd`

   Keep this file mode `0600` and do not commit it. It is mounted read-only into the relay container and converted to Postfix's hashed credential map at startup.

4. Start only nginx for the ACME HTTP-01 challenge:

   `docker-compose up -d nginx`

5. Request the first certificate:

   `docker-compose --profile bootstrap run --rm certbot-init`

6. Build and start relay, certificate renewal, and nginx:

   `docker-compose up -d --build postfix certbot-renew nginx`

7. Create an inbound SMTP account. The login is the `USERNAME` argument:

   `docker-compose exec postfix create-smtp-user USERNAME 'A-long-random-password'`

The password is supplied as an argument and can remain in your terminal history. For production, prefer an interactive shell plus `saslpasswd2` or a secrets manager.

### SASL database repair

The SASL credential store is a Berkeley DB file. It must be created by `create-smtp-user`/`saslpasswd2`, not by `touch`. If Postfix logs `unable to open Berkeley db ... Invalid argument`, rebuild the image containing the fix and restart the relay. An empty database is removed automatically on startup:

`docker compose up -d --build --force-recreate postfix`

If the database is non-empty but damaged, save the old file and deliberately remove all inbound SMTP users with:

`docker compose exec postfix repair-sasl-db --delete-all-users`

Then recreate every SMTP account and its sender policy. The command preserves a timestamped copy alongside the database in the `postfix-sasl` volume.

## Per-user sender authorization

Every SMTP-authenticated account must be explicitly assigned its permitted envelope `MAIL FROM` address(es). A user with no assignment is denied with `553 5.7.1 Sender address rejected: not owned by user`.

After the first `docker-compose up -d --build postfix`, create the account and then assign one or more exact addresses:

`docker-compose exec postfix create-smtp-user printer 'A-long-random-password'`

`docker-compose exec postfix set-smtp-senders printer printer@yourdomain.example alerts@yourdomain.example`

To allow a dedicated account to send from every address in one domain, use an `@domain` pattern:

`docker-compose exec postfix set-smtp-senders monitoring @yourdomain.example`

The restriction applies to the SMTP envelope sender (`MAIL FROM`), which is the relevant anti-spoofing control. The client should also set the visible `From:` header to the same permitted address; Postfix intentionally does not rewrite message headers.

The command persists its policy on the host in `./data/relay-policy/`, runs `postmap`, and reloads Postfix. A sender address cannot be assigned to two logins. The directory contains the authorization map and its Postfix `.db` index, so treat it as operational state and back it up together with the SMTP credentials. To view the effective assignments:

`docker-compose exec postfix postmap -s /etc/postfix/relay-policy/sender_login_maps`

## Client parameters

- Server: value of `SMTP_HOSTNAME`
- Port: 587
- Encryption: STARTTLS (required)
- Authentication: normal password / LOGIN
- Username: `USERNAME`

Use firewall or security-group rules to limit TCP/587 to known/VPN source networks. Do not expose it broadly unless you intentionally operate an Internet-facing submission service.

## Detailed logs and queue

All Postfix mail events are written both to Docker logs and persistent volume `smtp-relay_postfix-logs`:

- Follow all SMTP/TLS/delivery events: `docker-compose logs -f postfix`
- Inspect the live queue: `docker-compose exec postfix postqueue -p`
- Force an immediate queue run: `docker-compose exec postfix postqueue -f`
- Show active configuration: `docker-compose exec postfix postconf -n`
- Locate volume: `docker volume inspect smtp-relay_postfix-logs`

TLS log level `2` is enabled for inbound and outbound SMTP, so negotiation, peer certificate and delivery status are recorded. Postfix deliberately does not log complete message bodies or SMTP AUTH passwords. Debug-level SMTP transaction logging should not be permanently enabled because it can leak recipient and message metadata.

Queue settings: `queue_run_delay=10s`, `minimal_backoff_time=10s`, `maximal_backoff_time=10m`, and a one-day queue lifetime. The Postfix queue volume survives container recreation.

## Microsoft 365 authenticated upstream

The supplied `.env.example` sets `SMTP_HOST=smtp.office365.com`, `SMTP_PORT=587`, `UPSTREAM_TLS_SECURITY=verify`, `UPSTREAM_SASL_ENABLE=yes`, and `SMTP_INET_PROTOCOLS=ipv4`. IPv4 avoids Docker embedded-DNS deferrals such as `Name service error for name=smtp.office365.com type=AAAA`. Set `SMTP_INET_PROTOCOLS=all` only when IPv6 and the Docker resolver are known to work. The relay refuses to start if `secrets/sasl_passwd` is missing or empty.

If you deliberately change to another upstream, update both `SMTP_HOST`/`SMTP_PORT` and the bracketed endpoint on the only line in `secrets/sasl_passwd`, then restart Postfix:

`docker-compose up -d --build postfix`

## Certificate validation and renewal

`certbot-renew` validates the active leaf certificate once per 24 hours. It logs its UTC expiry time and remaining lifetime to `docker-compose logs certbot-renew`.

A certificate with more than 7 days remaining is left untouched. At 7 days or less, the service explicitly requests a replacement. A missing or invalid certificate also causes a replacement request; errors are retained in the container logs and retried after 24 hours. Postfix reloads hourly, so it picks up a renewed certificate without recreating the relay container.

Check the active certificate expiry directly:

`docker-compose run --rm certbot certificates`

Watch validation and renewal decisions:

`docker-compose logs -f certbot-renew`

## Verification

After deployment, from a separate machine with OpenSSL:

`openssl s_client -starttls smtp -connect relay.example.com:587 -servername relay.example.com`

The handshake must show the Let's Encrypt certificate for the relay name. Verify a test submission and confirm a line such as `status=sent` in `docker-compose logs postfix`.

## Security boundaries

- The relay is not an open relay: external delivery requires SMTP AUTH over TLS.
- Exchange Online Authenticated SMTP must be enabled for the configured upstream account. If tenant security policy disables password SMTP AUTH, this password-based route will not work; use an approved app password where available or move to an OAuth-capable relay/Exchange connector.
- Do not put real credentials in Git. `.env` and `secrets/` are ignored.
- Back up named volumes if you need queue/log/account durability across Docker-host loss.
