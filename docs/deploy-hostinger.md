# Deploying to a Hostinger VPS

This runbook puts the monitoring server on one Hostinger VPS. The stack is the same as on EC2 ([`deploy.md`](deploy.md)); only the server setup differs. Read [`CONTEXT.md`](../CONTEXT.md) for the terms (Device, Company Account).

```
Developer Mac (Claude Code) ──OTLP/gRPC over TLS──► otel.<domain>:443 ─┐
Manager's browser ─────────────HTTPS─────────────► grafana.<domain>:443 ┤ Caddy (only public service)
                                                                       ▼
                                   OTel Collector ──► Prometheus ◄── Grafana   (internal Docker network)
```

Any Hostinger KVM plan is enough. The stack needs under 1 GB of memory, and the smallest plan has 4 GB, so no swap is needed.

The steps use `<VPS_IP>` for the VPS's IPv4 address and `DOMAIN` for the hostname base from step 2.

## 1. Prepare the VPS in hPanel

1. Open **hPanel → VPS → your server**. The **Overview** page shows the IPv4 address. That is `<VPS_IP>`.
2. **Operating system:** use **Ubuntu 24.04** (plain, or the "with Docker" template). Changing the OS wipes the VPS, so do it before anything else.
3. **SSH key:** under **Settings → SSH keys**, add your Mac's public key (`cat ~/.ssh/id_ed25519.pub`). Then you log in with the key instead of the root password.
4. **Firewall:** under **Security → Firewall**, create a configuration with these **accept** rules, then activate it for this VPS:

   | Protocol | Port | Source | Why |
   |---|---|---|---|
   | TCP | 22 | your IP (or any, if your IP changes often) | SSH |
   | TCP | 80 | any | Let's Encrypt certificate checks, redirect to HTTPS |
   | TCP | 443 | any | Devices sending usage, and the Grafana website |

   Nothing else is needed. Prometheus (9090), Grafana (3000) and the Collector (4317) are never published by Docker, so they stay private even without these rules.

## 2. Hostnames

Without a domain, use [sslip.io](https://sslip.io): write the IP with dashes and add `.sslip.io`.

```
VPS IP:     82.25.10.7
DOMAIN:     82-25-10-7.sslip.io
Hostnames:  otel.82-25-10-7.sslip.io and grafana.82-25-10-7.sslip.io  → 82.25.10.7
```

With your own domain, create A records for `otel.<domain>` and `grafana.<domain>` pointing to `<VPS_IP>` instead. [`deploy.md` step 3](deploy.md#3-hostnames) has the details and trade-offs.

The hostnames contain the IP, so they stay valid as long as the VPS keeps its IP. A new IP means a new DOMAIN and re-running the install script on every Mac.

## 3. Install Docker

```bash
ssh root@<VPS_IP>

# Skip if you picked the "with Docker" template.
curl -fsSL https://get.docker.com | sh

docker version && docker compose version
ss -tlnp | grep -E ':(80|443)\b'   # must print nothing: Caddy needs both ports
```

## 4. Get the code and write `.env`

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git
cd claude_otel_monitoring

cat > .env <<EOF
COMPOSE_FILE=compose.yaml:compose.prod.yaml
DOMAIN=82-25-10-7.sslip.io    # your value from step 2
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
COMPANY_ACCOUNTS=first@yourcompany.com,second@yourcompany.com    # the real Company Accounts
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
cat .env   # copy OTEL_AUTH_TOKEN and GRAFANA_ADMIN_PASSWORD into your password manager
```

`COMPANY_ACCOUNTS` must be comma-separated with **no spaces**. `.env` is git-ignored and is the only place the token, the password and the company emails live.

## 5. Start the stack

```bash
docker compose up -d
docker compose ps                                    # caddy, otel-collector, prometheus, grafana: running
docker compose logs caddy | grep -i "certificate obtained"
```

Two "certificate obtained successfully" lines mean TLS is ready. Then, from your Mac:

```bash
curl -s https://grafana.<DOMAIN>/api/health   # {"database":"ok",...}
nc -vz -w 3 <VPS_IP> 9090                      # must FAIL
nc -vz -w 3 <VPS_IP> 4317                      # must FAIL
```

## 6. Grafana access, Devices and day-to-day

These are the same as on EC2:

- [Set up Grafana access](deploy.md#8-set-up-grafana-access): the manager's Viewer account.
- [Onboard a Device](deploy.md#9-onboard-a-device): run the install script on each Mac with the new token and DOMAIN, then restart every running Claude Code session.
- [Day-to-day operations](deploy.md#day-to-day-operations): run the commands in `~/claude_otel_monitoring`.

## 7. Backups

All data (Prometheus metrics, Grafana users) lives in Docker volumes on the VPS disk. In hPanel, under **Backups**, check that weekly automatic backups are on. Before risky changes, take a manual **snapshot** there too. Restoring a backup or snapshot brings the whole VPS back, and the stack starts on its own (`restart: unless-stopped`).
