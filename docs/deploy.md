# Deploying to AWS EC2

This runbook covers putting the monitoring server on one EC2 instance and onboarding Devices. Read [`CONTEXT.md`](../CONTEXT.md) for the terms (Device, Company Account). Read [ADR-0001](adr/0001-telemetry-not-api-proxy.md) for why this is telemetry rather than a proxy.

```
Developer Mac (Claude Code) ──OTLP/gRPC over TLS──► otel.<domain>:443 ─┐
Manager's browser ─────────────HTTPS─────────────► grafana.<domain>:443 ┤ Caddy (only public service)
                                                                       ▼
                                   OTel Collector ──► Prometheus ◄── Grafana   (internal Docker network)
```

You need:

- an AWS account
- admin rights on each developer Mac
- **optionally**, a domain. Without one, step 3 uses free sslip.io hostnames.

The later steps use `DOMAIN` for whatever step 3 gives you, for example `13-235-40-7.sslip.io`.

## 1. Launch the instance

### 1.1 Pick the region

1. Sign in to the AWS console.
2. In the top-right corner, open the region menu and choose **Asia Pacific (Mumbai) ap-south-1**. It's the closest region to India, so it has the lowest latency. Every later step happens in this region. If you switch regions, the instance "disappears" from the lists.

### 1.2 Check which free plan you have

1. Search for **Billing and Cost Management** in the top search bar and open it.
2. Look at the home page or **Free Tier**:
   - **Credits** with an end date mean the newer **Free plan**. It includes 2 GB instances (`t4g.small`, `t3.small`).
   - **Free Tier usage** with 750 hours per month means the older **12-month free tier**. It covers only 1 GB instances (`t3.micro`, `t2.micro`).

The launch wizard below also marks eligible instance types with a **Free tier eligible** label.

### 1.3 Launch the instance

Go to **EC2 → Instances → Launch instances** and fill in the form from top to bottom.

**Name and tags**
- Name: `claude-otel-monitoring`

**Application and OS Images**
1. Choose **Quick Start → Ubuntu**.
2. Pick **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type**.
3. Set **Architecture** to match the instance type you'll choose next:
   - **64-bit (Arm)** for `t4g.small` (cheapest when eligible)
   - **64-bit (x86)** for `t3.small`, `t3.micro` or `t2.micro`

**Instance type**
- Pick the largest **Free tier eligible** option from step 1.2: `t4g.small`/`t3.small` (2 GB) if you see it, otherwise `t3.micro` (1 GB).
- If the wizard complains that the architecture doesn't match, go back and change the Architecture.

**Key pair (login)**
1. Click **Create new key pair**.
2. Name: `claude-otel-key`, type **ED25519**, format **.pem**.
3. Click **Create key pair**. The browser downloads `claude-otel-key.pem`. AWS keeps no copy, so if you lose it you lose SSH access.
4. Move it somewhere safe on your Mac:
   ```bash
   mkdir -p ~/.ssh && mv ~/Downloads/claude-otel-key.pem ~/.ssh/ && chmod 400 ~/.ssh/claude-otel-key.pem
   ```

**Network settings.** Click **Edit**:
- VPC: the default VPC
- Subnet: No preference
- Auto-assign public IP: **Enable**
- Firewall: **Create security group**
  - Name: `claude-otel`
  - Description: `SSH from admin, HTTP/HTTPS from anywhere`
- Inbound rules:

  | Type | Source type | Why |
  |---|---|---|
  | **ssh** (port 22) | **My IP** | Only your current network can log in |
  | **HTTP** (port 80) | **Anywhere** | Caddy proves the domain to Let's Encrypt over port 80 |
  | **HTTPS** (port 443) | **Anywhere** | Devices send telemetry and the manager opens Grafana from any network |

  Use **Add security group rule** for the second and third rows. Leave 3000, 4317 and 9090 closed. Only Caddy is published, and the security group is a second guard.

**Configure storage**
- **20** GiB, **gp3**. The older free tier includes up to 30 GB of EBS. On the newer plan, storage comes out of the credits.

**Advanced details** (optional)
- Set **Termination protection** to **Enable**, so the instance can't be deleted by a stray click.

**Summary**
- Number of instances: 1. Click **Launch instance**, then **View all instances**.

Wait until **Instance state** shows **Running** and **Status check** shows **3/3 checks passed**. This takes 1–2 minutes.

> **"My IP" changes when you change networks** (office, home, mobile hotspot). If SSH later times out, go to **EC2 → Security Groups → claude-otel → Edit inbound rules** and set the SSH rule's source to **My IP** again.

## 2. Give it a fixed IP address (Elastic IP)

The public IP that AWS gives at launch changes every time the instance stops and starts. Devices and the hostnames below need an address that never changes, and an **Elastic IP** is exactly that.

1. Go to **EC2 → Network & Security → Elastic IPs → Allocate Elastic IP address**.
2. Keep the defaults: network border group `ap-south-1` and **Amazon's pool of IPv4 addresses**. Click **Allocate**.
3. Optionally, give it a Name tag: select it, open the **Tags** tab, and add `Name = claude-otel-monitoring`.
4. With the new address selected, choose **Actions → Associate Elastic IP address**.
   - Resource type: **Instance**
   - Instance: `claude-otel-monitoring`
   - Private IP address: pick the only option
   - Click **Associate**.
5. Open **EC2 → Instances → claude-otel-monitoring**. **Public IPv4 address** now shows the Elastic IP. Write it down (example: `13.235.40.7`).
6. Test SSH from your Mac. Type `yes` at the first fingerprint prompt.
   ```bash
   ssh -i ~/.ssh/claude-otel-key.pem ubuntu@13.235.40.7
   ```

An Elastic IP is free while it's attached to a running instance (within the free tier). AWS charges for one that is **not** attached. If you ever terminate the instance, release the IP: **Actions → Release Elastic IP addresses**.

## 3. Hostnames

Caddy needs two hostnames that point to the Elastic IP, `otel.<DOMAIN>` and `grafana.<DOMAIN>`, so it can get TLS certificates. Pick **one** of the two options below. Either way you end up with a `DOMAIN` value for step 6.

### Option A: no domain (sslip.io)

[sslip.io](https://sslip.io) is a free public DNS service. Any name that contains an IP address resolves to that IP. It needs no sign-up and no DNS records. Write the Elastic IP with dashes instead of dots:

```
Elastic IP:  13.235.40.7
DOMAIN:      13-235-40-7.sslip.io
Hostnames:   otel.13-235-40-7.sslip.io      → 13.235.40.7
             grafana.13-235-40-7.sslip.io   → 13.235.40.7
```

Check it from your Mac:

```bash
dig +short otel.13-235-40-7.sslip.io grafana.13-235-40-7.sslip.io   # both print 13.235.40.7
```

Trade-offs:

- You depend on a free third-party DNS service. If sslip.io is down, Devices can't look up the server, and those minutes of telemetry are lost. Claude Code itself keeps working.
- The hostnames contain the IP, so a new Elastic IP means a new DOMAIN, and re-running the install script on every Mac.
- Caddy gets certificates from Let's Encrypt. If that fails (for example, because of shared rate limits on sslip.io), Caddy falls back to ZeroSSL by itself.

That's fine for starting out. To move to a real domain later, change `DOMAIN` in `.env`, run `docker compose up -d`, and re-run the install script on each Mac.

### Option B: your own domain

At your DNS provider, create two **A records** pointing to the Elastic IP:

```
otel.example.com     A   13.235.40.7
grafana.example.com  A   13.235.40.7
```

Then `DOMAIN=example.com`. If the DNS is on Cloudflare, set both records to **DNS only** (grey cloud). Caddy gets its own certificates, and gRPC from Devices has to reach Caddy directly, not through Cloudflare's proxy.

Check both records before going further, because Let's Encrypt fails if DNS isn't live yet:

```bash
dig +short otel.example.com grafana.example.com   # both lines show the Elastic IP
```

## 4. Install Docker

```bash
ssh -i ~/path/to/key.pem ubuntu@<elastic-ip>

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
exit   # log out and back in so the group change applies
```

Log back in and check that Docker works:

```bash
docker version && docker compose version
```

## 5. Add swap (1 GB instances only)

Skip this step on a 2 GB instance.

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h   # Swap: 2.0Gi
```

`compose.prod.yaml` caps each container's memory (Caddy 64 MB, Collector 192 MB, Prometheus 384 MB, Grafana 256 MB), so one service can't starve the others.

## 6. Get the code and write `.env`

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git
cd claude_otel_monitoring

cat > .env <<EOF
COMPOSE_FILE=compose.yaml:compose.prod.yaml
DOMAIN=13-235-40-7.sslip.io    # your value from step 3
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
COMPANY_ACCOUNTS=first@yourcompany.com,second@yourcompany.com    # the real Company Accounts
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
cat .env   # copy OTEL_AUTH_TOKEN and GRAFANA_ADMIN_PASSWORD into your password manager
```

- `COMPOSE_FILE` makes a plain `docker compose ...` command use the production setup (Caddy, ports 80/443, memory limits).
- `COMPANY_ACCOUNTS` must be comma-separated with **no spaces**. A space becomes part of the address, and that account's data is silently dropped.
- `.env` is git-ignored. It is the only place the token, the password and the company emails live.

## 7. Start the stack

```bash
docker compose up -d
docker compose ps                        # caddy, otel-collector, prometheus, grafana: running
docker compose logs caddy | grep -i "certificate obtained"
```

Two "certificate obtained successfully" lines (one per hostname) mean TLS is ready. This usually takes under a minute. If it doesn't appear, check `docker compose logs caddy` for DNS or port 80 errors (steps 1 and 3).

From your Mac:

```bash
curl -s https://grafana.<DOMAIN>/api/health    # {"database":"ok",...}
nc -vz -w 3 <elastic-ip> 9090                          # must FAIL (Prometheus not exposed)
nc -vz -w 3 <elastic-ip> 4317                          # must FAIL (Collector only via Caddy)
```

## 8. Set up Grafana access

1. Open `https://grafana.<DOMAIN>` and log in as `admin` with `GRAFANA_ADMIN_PASSWORD`.
2. Create the manager's account: go to **Administration → Users and access → Users → New user**. Enter their name, email, username and a password, then **Create user**. Open the user and set the organization role to **Viewer**.
3. Check that the dashboard is at **Dashboards → Claude Code usage**.

Anonymous access and sign-up are turned off, so no one can see the dashboard without an account.

## 9. Onboard a Device

To have someone else set up their own Mac, send them [`onboard-device.md`](onboard-device.md) together with the domain and the token (privately). The steps below are the same, done by you.

Do this on each developer Mac. You need the repo (or just `install.sh`) and the token from `.env`.

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git
cd claude_otel_monitoring
sudo ./install.sh --token <OTEL_AUTH_TOKEN> --domain <DOMAIN>
./install.sh --check      # settings (token masked) + "Endpoint otel.<DOMAIN>:443 is reachable"
```

The script reads the Mac's serial number and hostname on its own. Then:

1. **Open a new terminal** and start `claude` signed in to a Company Account. Settings apply only to sessions started after the install.
2. Use it for a minute or two.
3. Check that the Device appears on the dashboard within about two minutes. Claude Code sends metrics every 60 seconds.

**Your own Mac** currently points at the local test stack. Running the install command above replaces that setting. Then stop the local stack:

```bash
cd ~/Desktop/claude_proxy && docker compose -f compose.yaml -f compose.local.yaml down
```

## 10. Schedule backups

All data (Prometheus metrics, Grafana users) lives in Docker volumes on the root EBS volume. Snapshot that volume weekly:

1. Go to **EC2 → Volumes**, select the instance's volume, and add the tag `Backup = claude-otel`.
2. Go to **EC2 → Lifecycle Manager → Create lifecycle policy → EBS snapshot policy**.
   - Target resource: **Volume**, with the target tag `Backup = claude-otel`.
   - Schedule: **Weekly**, a day of your choice, 03:00 UTC.
   - Retention: **count 4** (about a month of weekly copies).
   - Create the default IAM role when asked, then **Create policy**.

**To restore:**

1. Go to **EC2 → Snapshots**, pick a snapshot, then **Actions → Create image from snapshot**. Choose the same architecture, set the root device to `/dev/sda1`, and enable ENA.
2. Launch an instance from that image, with the same security group.
3. Move the Elastic IP to the new instance (step 2).

DNS doesn't change, and the stack starts on its own (`restart: unless-stopped`).

## Day-to-day operations

All commands run on the server, in `~/claude_otel_monitoring`.

| Task | Steps |
|---|---|
| **Add a Company Account** | Add the email to `COMPANY_ACCOUNTS` in `.env` (comma, no spaces), then run `docker compose up -d`. Compose recreates the Collector with the new list. |
| **Rotate the token** | Put a new `openssl rand -hex 32` value in `.env`, run `docker compose up -d`, then re-run `sudo ./install.sh --token <new> --domain ...` on every Mac. Each Mac stops reporting until it's updated. |
| **Update to the latest code** | `git pull && docker compose up -d` |
| **View logs** | `docker compose logs -f otel-collector` (or `caddy`, `prometheus`, `grafana`) |
| **Remove a Device** | On the Mac, run `sudo ./install.sh --uninstall`. Its history stays on the dashboard. |
| **Find a silent Device** | Sort the per-Device table by **Last seen**. |

## What to tell developers

> Claude Code on your company Mac sends **usage metrics** to our monitoring server: token counts, estimated cost, active time, sessions, lines of code changed, commits, PRs, and whether suggested edits were kept. Each metric is labelled with the Mac's serial number and hostname, and the Claude account's email.
>
> It does **not** send your prompts, Claude's responses, file contents, file paths or commands. Those options are left off.
>
> Usage from **personal Claude accounts** is dropped by the server as soon as it arrives and is never stored. Only the company's Claude accounts are recorded. Monitoring never slows or blocks Claude Code: if the server is down, nothing changes for you.

## Costs after the free tier

Charges start once the free tier ends: when the credits run out (newer plan) or after 12 months (older plan). You then pay for the instance hours, the 20 GB EBS volume, the snapshots and the public IPv4 address. Check **Billing → Free Tier** to see where your account stands.
