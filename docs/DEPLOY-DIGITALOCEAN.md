# Deploying Chatwoot to a DigitalOcean Droplet

A runbook for standing up a self-hosted Chatwoot instance on a single
DigitalOcean Droplet using the prebuilt Docker images.

Every command here runs **on the Droplet** unless stated otherwise. Nothing in
this guide requires a working local Ruby toolchain — the `chatwoot/chatwoot`
image ships its own.

> **Scope.** This deploys *stock* Chatwoot. Branding and any custom product code
> are separate work; see `docs/PROJECT-AUDIT.md` §22–23 for the extension points.

---

## 0. Before you start

**Decide the licensing question first.** The `chatwoot/chatwoot` image bundles
the `enterprise/` directory, which is **not** MIT licensed. `enterprise/LICENSE`
requires a Chatwoot Enterprise subscription for production use and forbids
sublicensing or reselling. This runbook defaults to `DISABLE_ENTERPRISE=true`,
which runs the OSS (MIT) build. Change that only if you hold a subscription.

**You will need:**

| Item | Notes |
|---|---|
| Droplet | **4 GB RAM minimum.** Rails + Sidekiq + Postgres + Redis will thrash on 2 GB. |
| Domain name | Meta/WhatsApp webhooks will not register against a bare IP or plain http. |
| SMTP relay | DigitalOcean blocks outbound port 25, so a local MTA will not deliver. Use SES, Mailgun, Postmark or similar. |

**Sizing note.** Running Postgres on the same Droplet is fine to start, but it
puts your database on the same disk and failure domain as the app. A managed
database is the better choice once you have real data — you get backups and
point-in-time restore without building them yourself.

---

## 1. Create the Droplet

Create an Ubuntu LTS Droplet with at least 4 GB RAM, adding your SSH public key
during creation. DigitalOcean's Marketplace may offer an image with Docker
preinstalled; if you use a plain Ubuntu image, install Docker with the official
convenience script:

```bash
curl -fsSL https://get.docker.com | sh
docker --version && docker compose version
```

Then point an `A` record for your domain (e.g. `chat.example.com`) at the
Droplet's IPv4 address, and wait for it to resolve before requesting a
certificate:

```bash
dig +short chat.example.com
```

---

## 2. Harden the box

Do this before exposing anything. The compose file already binds Postgres,
Redis and Rails to `127.0.0.1`, so only nginx should be reachable publicly.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
ufw status verbose
```

Confirm `ufw status` does **not** list 3000, 5432 or 6379.

---

## 3. Fetch the code and configure

```bash
git clone https://github.com/ajesh2002/chatwoot.git /opt/chatwoot
cd /opt/chatwoot
cp deployment/env.production.example .env
```

Generate the secrets directly into place — do not paste them through a chat
window, ticket or shared document:

```bash
# SECRET_KEY_BASE
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -hex 64)|" .env

# Database and Redis passwords
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" .env
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$(openssl rand -hex 24)|" .env
```

Now edit `.env` by hand and set `FRONTEND_URL`, the `SMTP_*` block and
`MAILER_SENDER_EMAIL`. Then:

```bash
chmod 600 .env
```

### Close the empty-password gap in the compose file

`docker-compose.production.yaml` ships the `postgres` service with an **empty**
`POSTGRES_PASSWORD`. It must match the value you just generated, or Postgres
starts with trust authentication:

```bash
grep '^POSTGRES_PASSWORD=' .env     # note the value
```

Edit `docker-compose.production.yaml` so the `postgres` service reads:

```yaml
    environment:
      - POSTGRES_DB=chatwoot_production
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=<the same value as in .env>
```

Verify the file parses before going further:

```bash
docker compose -f docker-compose.production.yaml config >/dev/null && echo OK
```

---

## 4. Generate the encryption keys

MFA and every encrypted column depend on these. They must exist **before**
first boot.

```bash
docker compose -f docker-compose.production.yaml run --rm \
  rails bundle exec rails db:encryption:init
```

Copy the three printed values into the matching `ACTIVE_RECORD_ENCRYPTION_*`
lines in `.env`.

> **Back these up off the server.** Lose them and every encrypted column becomes
> permanently unreadable — there is no recovery path.

---

## 5. Run migrations

This is the step most people miss. The compose setup has **no release phase**:
`docker/entrypoints/rails.sh` waits for Postgres and then starts the server, but
never migrates. Prepare the schema explicitly, once:

```bash
docker compose -f docker-compose.production.yaml run --rm \
  rails bundle exec rails db:chatwoot_prepare
```

On a fresh database `db:chatwoot_prepare` loads the schema, seeds it and then
migrates; on an existing one it only runs pending migrations. Migrating also
reloads `installation_configs` from `config/installation_config.yml`, so any
unlocked setting you changed in Super Admin is re-applied from the YAML
defaults. Re-run this same command after every upgrade.

---

## 6. Start it

```bash
docker compose -f docker-compose.production.yaml up -d
docker compose -f docker-compose.production.yaml ps
```

All four services (`rails`, `sidekiq`, `postgres`, `redis`) should be `Up`.
Check the app is answering locally before wiring nginx:

```bash
curl -si http://127.0.0.1:3000/api | head -1
docker compose -f docker-compose.production.yaml logs --tail=50 rails
```

If `sidekiq` is not running, background jobs — outbound messages, webhooks,
email, automations — silently never execute. Verify it explicitly.

---

## 7. nginx and TLS

The repo ships a working reverse-proxy config with the websocket upgrade
handling ActionCable needs.

```bash
apt-get update && apt-get install -y nginx certbot python3-certbot-nginx
cp deployment/nginx_chatwoot.conf /etc/nginx/sites-available/chatwoot
sed -i 's/chatwoot\.domain\.com/chat.example.com/g' /etc/nginx/sites-available/chatwoot
ln -sf /etc/nginx/sites-available/chatwoot /etc/nginx/sites-enabled/chatwoot
rm -f /etc/nginx/sites-enabled/default
```

That config references `/etc/ssl/dhparam`, which does not exist by default:

```bash
openssl dhparam -out /etc/ssl/dhparam 2048     # takes a few minutes
```

Issue the certificate, then test and reload:

```bash
certbot --nginx -d chat.example.com
nginx -t && systemctl reload nginx
```

Certbot installs a renewal timer. Confirm it:

```bash
systemctl list-timers | grep certbot
certbot renew --dry-run
```

---

## 8. First login

Open `https://chat.example.com` and create the first account. If you set
`ENABLE_ACCOUNT_SIGNUP=false`, create the super admin from the console instead:

```bash
docker compose -f docker-compose.production.yaml exec rails \
  bundle exec rails c
```

```ruby
SuperAdmin.create!(email: 'you@example.com', password: 'a-strong-password')
```

Super Admin lives at `/super_admin`. Branding (`INSTALLATION_NAME`, `LOGO`,
`BRAND_NAME`, `BRAND_URL`, …) is configured there at runtime — no redeploy
needed. See `docs/PROJECT-AUDIT.md` §20.

---

## 9. Verify before you trust it

| Check | Command / action |
|---|---|
| All services up | `docker compose -f docker-compose.production.yaml ps` |
| Sidekiq processing | Super Admin → Sidekiq dashboard shows a live process |
| Outbound mail | Invite a teammate and confirm the email arrives |
| Websockets | Open a conversation in two browsers; a message should appear without refresh |
| TLS | `curl -sI https://chat.example.com | head -1` returns `HTTP/2 200` |
| Renewal armed | `certbot renew --dry-run` |

---

## 10. Backups

Nothing above backs anything up. Before this holds real data:

```bash
# Database
docker compose -f docker-compose.production.yaml exec -T postgres \
  pg_dump -U postgres chatwoot_production | gzip > chatwoot-$(date +%F).sql.gz
```

Also preserve: the `storage_data` volume (uploads, if `ACTIVE_STORAGE_SERVICE=local`),
the `.env` file, and the three `ACTIVE_RECORD_ENCRYPTION_*` keys. Enable Droplet
backups or snapshots in the DigitalOcean control panel as a second layer.

A backup you have never restored is a hypothesis, not a backup — practise a
restore into a throwaway Droplet at least once.

---

## Upgrading

```bash
cd /opt/chatwoot
docker compose -f docker-compose.production.yaml pull
docker compose -f docker-compose.production.yaml run --rm \
  rails bundle exec rails db:chatwoot_prepare
docker compose -f docker-compose.production.yaml up -d
```

Take a database dump first. Read the upstream release notes for the versions you
are crossing — some releases carry long-running or breaking migrations.

---

## Troubleshooting

**Rails restarts in a loop.** Almost always `.env`. Check
`docker compose -f docker-compose.production.yaml logs rails` for a missing
`SECRET_KEY_BASE` or a Postgres authentication failure (the compose/.env password
mismatch from step 3).

**Blank page or asset 404s.** `FRONTEND_URL` does not match the URL you are
actually visiting. It must be the full public `https://` origin.

**Messages never send; conversations stall.** Sidekiq is down. Everything
outbound flows through it (`SendReplyJob`), so the UI will look fine while
nothing leaves the box.

**Websockets dead (no live updates).** nginx is missing the `Upgrade` /
`Connection` headers — re-copy `deployment/nginx_chatwoot.conf` rather than
hand-writing a server block.

**Meta/WhatsApp webhook registration fails.** The callback URL must be publicly
reachable over valid HTTPS. Self-signed certificates and IP addresses are
rejected.
