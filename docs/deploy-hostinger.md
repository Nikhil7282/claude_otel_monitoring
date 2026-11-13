# Deploying to the Hostinger VPS (behind its nginx)

The company's Hostinger VPS already runs other apps, and its nginx owns ports 80 and 443. So the monitoring stack runs **behind that nginx** instead of bringing its own Caddy:

```
Developer Mac (Claude Code) ──OTLP/gRPC over TLS──► otel.<domain>:443 ─┐
Manager's browser ─────────────HTTPS─────────────► grafana.<domain>:443 ┤ the server's nginx (+ certbot)
                                                                       ▼
                    127.0.0.1:14317 → OTel Collector ──► Prometheus ◄── Grafana ← 127.0.0.1:13000
```

- `compose.nginx.yaml` publishes the Collector and Grafana on **localhost-only** ports. Prometheus isn't published at all.
- `nginx/claude-otel.conf.template` is one extra nginx site. It terminates TLS for the two hostnames. It sends gRPC to the Collector and the web traffic to Grafana.
- certbot issues and renews the certificate, the same way it does for the other sites on the server.

The other sites are never edited. The new site is a separate file, and every change is checked with `nginx -t` before a **graceful reload**, which doesn't drop connections. On an empty server with nothing on 80/443, use Caddy instead ([`deploy.md`](deploy.md)).

The steps use `<VPS_IP>` for the server's IPv4 address. For `72.61.196.129`, `DOMAIN` is `72-61-196-129.sslip.io` ([sslip.io](https://sslip.io): the IP with dashes). All commands run as root on the server.

## 1. Check the server

```bash
ssh root@<VPS_IP>
docker version && docker compose version       # Docker is already installed
nginx -v && certbot --version                   # nginx and certbot are already installed
ss -tlnp | grep -E ':(14317|13000)\b'          # must print nothing: the stack's localhost ports
```

The hPanel firewall must allow TCP 80 and 443. It already does, for the other sites.

## 2. Get the code and write `.env`

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git ~/claude_otel_monitoring
cd ~/claude_otel_monitoring

cat > .env <<EOF
COMPOSE_FILE=compose.yaml:compose.nginx.yaml
DOMAIN=72-61-196-129.sslip.io
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
COMPANY_ACCOUNTS=first@yourcompany.com,second@yourcompany.com    # the real Company Accounts
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
```

`COMPANY_ACCOUNTS` must be comma-separated with **no spaces**. `.env` is git-ignored and is the only place the token, the password and the company emails live. Copy `OTEL_AUTH_TOKEN` and `GRAFANA_ADMIN_PASSWORD` into your password manager.

## 3. Start the stack

```bash
docker compose up -d
docker compose ps                               # otel-collector, prometheus, grafana: running
curl -s http://127.0.0.1:13000/api/health      # {"database":"ok",...}
```

## 4. Get the certificate

One certificate covers both hostnames. certbot's nginx plugin answers the Let's Encrypt check on port 80 by itself:

```bash
. ./.env
certbot certonly --nginx --cert-name claude-otel \
  -d "otel.$DOMAIN" -d "grafana.$DOMAIN" \
  --deploy-hook "systemctl reload nginx"
```

The `--deploy-hook` makes nginx load the new certificate after each automatic renewal. The existing `certbot.timer` runs the renewals.

## 5. Add the nginx site

```bash
nginx/render.sh "$DOMAIN" 127.0.0.1:14317 127.0.0.1:13000 /etc/letsencrypt/live/claude-otel \
  > /etc/nginx/sites-available/claude-otel
ln -s /etc/nginx/sites-available/claude-otel /etc/nginx/sites-enabled/claude-otel
nginx -t && systemctl reload nginx
```

If `nginx -t` fails, nginx keeps running with the old configuration. Remove the link (`rm /etc/nginx/sites-enabled/claude-otel`) and check the error.

From your Mac:

```bash
curl -s https://grafana.<DOMAIN>/api/health    # {"database":"ok",...}
nc -vz -w 3 <VPS_IP> 13000                      # must FAIL (localhost only)
nc -vz -w 3 <VPS_IP> 14317                      # must FAIL (localhost only)
nc -vz -w 3 <VPS_IP> 9090                       # must FAIL (never published)
```

## 6. Grafana access and Devices

These are the same as on EC2:

- [Set up Grafana access](deploy.md#8-set-up-grafana-access): the manager's Viewer account.
- [Onboard a Device](deploy.md#9-onboard-a-device): run the install script on each Mac with the token and DOMAIN, then restart every running Claude Code session.

## Day-to-day operations

Commands run in `~/claude_otel_monitoring`.

| Task | Steps |
|---|---|
| **Update to the latest code** | `git pull && docker compose up -d` |
| **Change the nginx site** (after the template changes) | Re-run the `render.sh` line from step 5, then `nginx -t && systemctl reload nginx` |
| **Add a Company Account** or **rotate the token** | Same as [EC2](deploy.md#day-to-day-operations) |
| **Check the certificate** | `certbot certificates --cert-name claude-otel` |
| **Remove the whole stack** | `rm /etc/nginx/sites-enabled/claude-otel && nginx -t && systemctl reload nginx`, then `docker compose down` (add `-v` to delete the data too) |

## Backups

All data (Prometheus metrics, Grafana users) lives in Docker volumes on the VPS disk. In hPanel, under **Backups**, check that weekly automatic backups are on. They cover the whole VPS, including the other apps.
