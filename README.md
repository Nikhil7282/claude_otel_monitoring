# Claude Code usage monitoring

A small server and a setup script that show how your company's Claude Code accounts are used on each developer computer: estimated cost, tokens, active time, sessions, lines of code, commits, PRs and how many suggested edits were kept.

The data comes from Claude Code's built-in OpenTelemetry export, so nothing sits between Claude Code and Anthropic ([ADR-0001](docs/adr/0001-telemetry-not-api-proxy.md) explains why this isn't a proxy). Usage from personal Claude accounts is dropped when it arrives and never stored. If the server is down, Claude Code keeps working; only monitoring data is lost.

```
Mac / Windows PC                      your server
Claude Code ──OTLP/gRPC over TLS──►  nginx ──► OTel Collector ──► Prometheus ◄── Grafana ◄── nginx ◄── browser
                (otel.<domain>)               (token check +       (400 days)                (grafana.<domain>)
                                               Company Account
                                               filter)
```

Words used below: a **Device** is one developer computer (Mac or Windows PC) with the setup installed. A **Company Account** is a Claude account the company pays for; only those are recorded. See [`CONTEXT.md`](CONTEXT.md).

## Choose how to run the server

| | **Single VM** (recommended) | **Existing Kubernetes cluster** |
|---|---|---|
| For | Everyone without a cluster | Teams that already run one (EKS, AKS, GKE, k3s…) |
| Runs on | One Ubuntu VM with Docker Compose, on any provider: AWS EC2, Azure, Hostinger, … | Your cluster, in its own namespace |
| Front door | The VM's nginx, certificate from certbot | Your ingress-nginx, certificate from cert-manager |
| Cost | A 2 GB VM (or 1 GB with swap) | A few hundred MB of cluster memory, 11 GB of volumes |
| Steps | [Single VM](#single-vm) | [Kubernetes cluster](#kubernetes-cluster) |

Don't create a cluster just for this. The stack is one Prometheus with local storage, so a cluster adds parts and cost without making it more available ([ADR-0002](docs/adr/0002-nginx-is-the-only-front-door.md)).

Both paths end with [onboarding Devices](#onboard-devices).

**You need:**

- a domain where you can add DNS records. A **company subdomain** is best, for example `claude.yourcompany.com`. The steps call it `DOMAIN`.
- admin rights on each developer computer
- the email addresses of your Company Accounts

---

## Single VM

Every step is the same on every provider except step 1.

### 1. Create the VM

> **What you need from your provider**
> - **Ubuntu 24.04 LTS**
> - **2 GB RAM** (1 GB works with the swap step) and **20 GB disk**
> - a **public IPv4 address that doesn't change**
> - inbound firewall: **22** (SSH) from your IP only, **80** and **443** from anywhere. Nothing else.

Open the section for your provider, follow it, and come back with the VM's **public IP** and an **SSH command** that works.

<details>
<summary><b>AWS EC2</b></summary>

1. **Region.** In the AWS console, top right, pick the region closest to your developers, for example **Asia Pacific (Mumbai) ap-south-1**. Stay in it for every step.
2. **Free tier.** Open **Billing and Cost Management → Free Tier**. *Credits* with an end date means the newer Free plan, which covers 2 GB instances (`t4g.small`, `t3.small`). *750 hours per month* means the older 12-month free tier, which covers only 1 GB instances (`t3.micro`, `t2.micro`). The launch wizard marks eligible types with **Free tier eligible**.
3. **EC2 → Instances → Launch instances:**
   - Name: `claude-otel-monitoring`
   - Image: **Ubuntu Server 24.04 LTS**. Architecture **64-bit (Arm)** for `t4g.*`, **64-bit (x86)** for `t3.*` / `t2.*`.
   - Instance type: `t4g.small` or `t3.small` (2 GB) if eligible, otherwise `t3.micro` (1 GB).
   - Key pair: **Create new key pair**, name `claude-otel-key`, ED25519, `.pem`. Then on your computer: `mkdir -p ~/.ssh && mv ~/Downloads/claude-otel-key.pem ~/.ssh/ && chmod 400 ~/.ssh/claude-otel-key.pem`. AWS keeps no copy.
   - Network settings → **Edit**: auto-assign public IP **Enable**, **Create security group** `claude-otel` with three inbound rules: **SSH** from **My IP**, **HTTP** from **Anywhere**, **HTTPS** from **Anywhere**.
   - Storage: **20 GiB gp3**.
   - Advanced details: **Termination protection → Enable** (optional, recommended).
   - **Launch instance**. Wait for **Running** and **3/3 checks passed**.
4. **Fixed IP (Elastic IP).** The launch IP changes on every stop/start. **EC2 → Elastic IPs → Allocate Elastic IP address → Allocate**, then **Actions → Associate Elastic IP address** → Instance `claude-otel-monitoring` → **Associate**. This is your **public IP**. It's free while attached to a running instance; release it if you ever terminate the instance.
5. **SSH:** `ssh -i ~/.ssh/claude-otel-key.pem ubuntu@<public-ip>`

   If SSH later times out, your network's IP changed: **EC2 → Security Groups → claude-otel → Edit inbound rules** and set the SSH source to **My IP** again.
6. **Backups.** Tag the instance's volume `Backup = claude-otel` (**EC2 → Volumes → Tags**), then **EC2 → Lifecycle Manager → Create lifecycle policy → EBS snapshot policy**: target volumes with that tag, weekly, keep 4. To restore, create an image from a snapshot, launch it with the same security group, and move the Elastic IP to it.

After the free tier ends you pay for instance hours, the 20 GB volume, snapshots and the public IPv4 address.

</details>

<details>
<summary><b>Azure VM</b></summary>

1. In the Azure portal: **Create a resource → Virtual machine → Create**.
2. **Basics:**
   - Resource group: **Create new** `claude-otel`
   - Virtual machine name: `claude-otel-monitoring`
   - Region: the closest to your developers, for example **(Asia Pacific) Central India**
   - Image: **Ubuntu Server 24.04 LTS - x64 Gen2**
   - Size: **B1ms** (1 vCPU, 2 GB) is enough; **B2s** (4 GB) if you want headroom
   - Authentication: **SSH public key**, username `azureuser`, **Generate new key pair**, name `claude-otel-key`
   - Inbound ports: **Allow selected ports** → **SSH (22), HTTP (80), HTTPS (443)**
3. **Disks:** OS disk 30 GiB **Standard SSD** (the default size is fine).
4. **Networking:** Public IP **(new)**. New public IPs use the **Standard** SKU, which is always **static**, so the IP never changes. NIC network security group: **Basic**.
5. **Review + create → Create.** Download the private key when asked, then on your computer: `mkdir -p ~/.ssh && mv ~/Downloads/claude-otel-key.pem ~/.ssh/ && chmod 400 ~/.ssh/claude-otel-key.pem`.
6. Open the VM → **Overview**: **Public IP address** is your **public IP**.
7. **Lock SSH to your IP.** VM → **Networking → Network settings** → the inbound rule for port 22 → **Source: My IP address** → **Save**. Leave 80 and 443 open to Any.
8. **SSH:** `ssh -i ~/.ssh/claude-otel-key.pem azureuser@<public-ip>`
9. **Backups.** VM → **Backup** → create a Recovery Services vault and the **DefaultPolicy** (daily), or a weekly policy, → **Enable backup**.

</details>

<details>
<summary><b>Hostinger VPS</b></summary>

1. In hPanel, open the VPS. For a new VPS, choose the plain **Ubuntu 24.04** operating system (no control panel). If the VPS already runs other sites, keep it as it is: step 3 then just skips the nginx install, and the new nginx site sits next to the others without changing them.
2. The VPS's IP on its overview page is fixed. That's your **public IP**.
3. In the VPS's **Firewall** settings, make sure there are *accept* rules for TCP **22** (better: only from your IP), **80** and **443**. A VPS that already serves websites has 80 and 443 open.
4. **SSH:** `ssh root@<public-ip>`, with the root password shown under the VPS's SSH access details, or your SSH key.
5. **Backups:** in the VPS's **Backups** settings, check that weekly automatic backups are on. They cover the whole VPS, including other apps.

</details>

<details>
<summary><b>Any other provider</b> (DigitalOcean, GCP, Linode, Vultr, OVH, a server in your office…)</summary>

1. Create an **Ubuntu 24.04** VM with 2 GB RAM (or 1 GB) and 20 GB disk, and an SSH key.
2. Give it a **static / reserved / elastic public IPv4** (names differ), so the IP survives a reboot.
3. In the provider's **firewall / security group**: allow inbound TCP 22 from your IP, 80 and 443 from anywhere. Block everything else.
4. Note the public IP and test `ssh <user>@<public-ip>`.
5. Turn on the provider's disk snapshots or backups (weekly is enough).

</details>

### 2. Point your domain at the VM

At your DNS provider (Cloudflare, Route 53, GoDaddy, Hostinger DNS, Azure DNS, …) add two **A records**, both pointing at the VM's public IP, with a short TTL such as 300 seconds:

```
otel.claude.yourcompany.com      A   <public-ip>      ← Devices send usage here
grafana.claude.yourcompany.com   A   <public-ip>      ← the dashboard
```

Here `DOMAIN` is `claude.yourcompany.com`. Devices only know these names, so if you ever move the server, you change these two records and nothing on the Devices.

> **On Cloudflare, set both records to "DNS only" (grey cloud).** Cloudflare's proxy (orange cloud) breaks the gRPC connection from the Devices, and nginx needs to get its own certificate.

This has to happen **now**, before step 6: Let's Encrypt checks that these names point at your server before it issues a certificate. Check from your computer; both lines must print the public IP:

```bash
dig +short otel.claude.yourcompany.com grafana.claude.yourcompany.com
```

New records usually show up within a few minutes.

> **Just trying it out, without a domain?** Use [sslip.io](https://sslip.io): write the IP with dashes, `DOMAIN=13-235-40-7.sslip.io`, and skip the DNS records (`otel.13-235-40-7.sslip.io` already resolves to `13.235.40.7`). Don't onboard real Devices on it: the IP is part of the name, so a new IP means re-running setup on every Device, and you depend on a free third-party DNS service.

### 3. Prepare the server

SSH in (step 1) and run these on the server.

**nginx and certbot.** Skip this if `nginx -v && certbot --version` already works, as on a server that hosts other sites:

```bash
sudo apt-get update
sudo apt-get install -y nginx certbot python3-certbot-nginx
```

**Docker:**

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
exit      # log out and SSH in again, so the group change applies
```

After logging in again: `docker version && docker compose version`.

**Swap (1 GB VMs only):**

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

**Host firewall:** cloud images usually have `ufw` off. If `sudo ufw status` says *active*, run `sudo ufw allow OpenSSH && sudo ufw allow 'Nginx Full'`.

### 4. Get the code and write `.env`

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git ~/claude_otel_monitoring
cd ~/claude_otel_monitoring
```

Write `.env`. Change `DOMAIN` and `COMPANY_ACCOUNTS` in the block first; the token and password are generated for you:

```bash
cat > .env <<EOF
COMPOSE_FILE=compose.yaml:compose.nginx.yaml
DOMAIN=claude.yourcompany.com
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
COMPANY_ACCOUNTS=first@yourcompany.com,second@yourcompany.com
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
cat .env
```

- `COMPANY_ACCOUNTS` is comma-separated with **no spaces**. A space becomes part of the address, and that account's data is silently dropped.
- Don't put quotes around values or comments after them. Docker Compose would cope, but the same file is used as-is on Kubernetes.
- Copy `OTEL_AUTH_TOKEN` and `GRAFANA_ADMIN_PASSWORD` into your password manager. `.env` is git-ignored; it is the only place the token, the password and the company emails live.
- `COMPOSE_FILE` makes a plain `docker compose …` use the production setup: the stack listens on **localhost-only** ports (Collector 14317, Grafana 13000; Prometheus isn't published at all), and every container has a memory limit.

### 5. Start the stack

```bash
docker compose up -d
docker compose ps                              # otel-collector, prometheus, grafana: running
curl -s http://127.0.0.1:13000/api/health     # {"database":"ok",...}
```

### 6. Get the certificate

One certificate covers both names. certbot's nginx plugin answers Let's Encrypt's check on port 80 by itself. The first time, it asks for an email for expiry notices and to accept the terms:

```bash
. ./.env
sudo certbot certonly --nginx --cert-name claude-otel \
  -d "otel.$DOMAIN" -d "grafana.$DOMAIN" \
  --deploy-hook "systemctl reload nginx"
```

certbot renews it automatically (`certbot.timer`), and `--deploy-hook` makes nginx load each renewed certificate. If this fails with a DNS or connection error, recheck step 2 and that port 80 is open (step 1).

### 7. Add the nginx site

The site is one new file. It never touches other sites on the server, and `nginx -t` checks it before a graceful reload, which doesn't drop connections:

```bash
nginx/render.sh "$DOMAIN" 127.0.0.1:14317 127.0.0.1:13000 /etc/letsencrypt/live/claude-otel \
  | sudo tee /etc/nginx/sites-available/claude-otel >/dev/null
sudo ln -sf /etc/nginx/sites-available/claude-otel /etc/nginx/sites-enabled/claude-otel
sudo nginx -t && sudo systemctl reload nginx
```

If `nginx -t` fails, nginx keeps running with its old configuration. Remove the link (`sudo rm /etc/nginx/sites-enabled/claude-otel`) and look at the error.

### 8. Check it from your computer

```bash
curl -s https://grafana.<DOMAIN>/api/health   # {"database":"ok",...}
nc -vz -w 3 <public-ip> 13000                  # must FAIL: Grafana is localhost-only
nc -vz -w 3 <public-ip> 14317                  # must FAIL: the Collector is only reachable through nginx
nc -vz -w 3 <public-ip> 9090                   # must FAIL: Prometheus is never published
```

### 9. Set up Grafana access

1. Open `https://grafana.<DOMAIN>` and log in as `admin` with `GRAFANA_ADMIN_PASSWORD`.
2. For each person who should see the dashboard: **Administration → Users and access → Users → New user**, then set their organization role to **Viewer**.
3. The dashboard is at **Dashboards → Claude Code usage**. Anonymous access and sign-up are off, so nobody sees it without an account.

The server is done. Next: [onboard Devices](#onboard-devices).

---

## Kubernetes cluster

For teams that already run a cluster. Everything goes into its own namespace, `claude-otel`, and only two Ingresses are exposed. The manifests are in `k8s/`; the `kustomization.yaml` at the repo root builds the ConfigMaps from the same `collector/`, `prometheus/` and `grafana/` files the VM uses, and `make test` checks that the images, Prometheus flags, memory limits and Grafana settings match the Compose setup, so the two paths can't drift apart unnoticed.

### 1. Check the cluster has what it needs

```bash
kubectl version                                  # client 1.27 or newer (built-in Kustomize 5)
kubectl get ingressclass                         # a class named "nginx" (ingress-nginx)
kubectl get clusterissuer                        # a cert-manager ClusterIssuer, e.g. letsencrypt-prod
kubectl get storageclass                         # one marked "(default)"
```

- **ingress-nginx** terminates TLS and talks gRPC to the Collector (`nginx.ingress.kubernetes.io/backend-protocol: GRPC`).
- **cert-manager** issues one certificate per hostname with your ClusterIssuer. A Let's Encrypt issuer with an HTTP-01 solver on the `nginx` class works out of the box.
- **A default StorageClass** gives Prometheus 10 GiB and Grafana 1 GiB.

> **ingress-nginx was retired in March 2026** and no longer gets security fixes. Many clusters still run it, which is why it's the default here. On another controller, edit `k8s/ingress.yaml`: set `ingressClassName`, and replace the `backend-protocol: GRPC` annotation with your controller's way of saying "the backend speaks gRPC" (F5 NGINX Ingress Controller: `nginx.org/grpc-services: otel-collector`; AWS Load Balancer Controller: `alb.ingress.kubernetes.io/backend-protocol-version: GRPC`, with an ACM certificate instead of cert-manager). On Gateway API, write a `GRPCRoute` to the `otel-collector` Service (port 4317) and an `HTTPRoute` to `grafana` (port 3000) instead. Either way, the gRPC hop needs HTTP/2.

### 2. Get the code and write the two settings files

```bash
git clone https://github.com/Nikhil7282/claude_otel_monitoring.git
cd claude_otel_monitoring
cp k8s/settings.env.example k8s/settings.env     # set DOMAIN and CLUSTER_ISSUER
```

Then `.env`, the same file the VM path uses (change `COMPANY_ACCOUNTS` first):

```bash
cat > .env <<EOF
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
COMPANY_ACCOUNTS=first@yourcompany.com,second@yourcompany.com
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
```

Both files are git-ignored. `.env` becomes the `claude-otel` Secret. The same rules apply, and here they're strict because Kustomize reads values literally: no spaces in `COMPANY_ACCOUNTS`, no quotes around values, and no comments after a value. A quoted token would keep its quotes, and every Device would be rejected.

### 3. Point your domain at the ingress

Find the ingress controller's external address:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller     # the EXTERNAL-IP column (names can differ per install)
```

At your DNS provider, add `otel.<DOMAIN>` and `grafana.<DOMAIN>`:

- **an IP address** (AKS, GKE, most bare-metal load balancers) → two **A records** to that IP
- **a hostname** such as `a1b2….elb.amazonaws.com` (EKS) → two **CNAME records** to that hostname

On Cloudflare, **DNS only** (grey cloud), as on the VM. Check with `dig +short otel.<DOMAIN> grafana.<DOMAIN>`.

### 4. Deploy

```bash
kubectl apply -k .
```

### 5. Check it

```bash
kubectl -n claude-otel get pods                  # otel-collector, prometheus-0, grafana: Running, Ready
kubectl -n claude-otel get certificate           # otel-collector-tls, grafana-tls: READY True (can take a minute)
curl -s https://grafana.<DOMAIN>/api/health      # {"database":"ok",...}
```

If a certificate stays not ready, `kubectl -n claude-otel describe certificate` and `kubectl -n claude-otel get challenges` show why (usually DNS that isn't live yet).

Then [set up Grafana access](#9-set-up-grafana-access) exactly as on the VM, and [onboard Devices](#onboard-devices).

**Backups** are up to your cluster's own tooling: volume snapshots of the `data-prometheus-0` and `grafana-data` PVCs, or Velero.

---

## Onboard Devices

Do this on each developer computer, or send the person [`docs/onboard-device.md`](docs/onboard-device.md) together with `DOMAIN` and the token (privately). The guide has the full steps, the safe way to type the token, and troubleshooting.

**Mac** (the script reads the serial number and hostname by itself):

```bash
curl -fsSLO https://raw.githubusercontent.com/Nikhil7282/claude_otel_monitoring/main/mac_install.sh
chmod +x mac_install.sh
sudo ./mac_install.sh --token <OTEL_AUTH_TOKEN> --domain <DOMAIN>
./mac_install.sh --check     # settings (token masked) + "Endpoint otel.<DOMAIN>:443 is reachable"
```

**Windows**, in PowerShell opened with **Run as administrator**:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force    # this window only
Invoke-WebRequest -UseBasicParsing -OutFile windows_install.ps1 `
  https://raw.githubusercontent.com/Nikhil7282/claude_otel_monitoring/main/windows_install.ps1
.\windows_install.ps1 -Token <OTEL_AUTH_TOKEN> -Domain <DOMAIN>
.\windows_install.ps1 -Check
```

The Windows script uses the BIOS serial number as the Device ID, or the motherboard's hardware UUID if the serial is a placeholder (common on self-built PCs). If both are placeholders it stops and asks for `-DeviceId <asset-tag>`, so two PCs never merge into one Device.

Both scripts write Claude Code's **managed settings** file, which developers can't override from their own or a project's settings. Then:

1. **Open a new terminal** and start `claude` signed in to a Company Account. Only sessions started after the setup report.
2. Within about two minutes, the Device shows on the dashboard. Claude Code sends metrics every 60 seconds.

**What to tell developers:**

> Claude Code on your company computer sends **usage metrics** to our monitoring server: token counts, estimated cost, active time, sessions, lines of code changed, commits, PRs, and whether suggested edits were kept. Each metric is labelled with the computer's serial number (or hardware ID) and name, and the Claude account's email.
>
> It does **not** send your prompts, Claude's responses, file contents, file paths or commands. Those options are left off.
>
> Usage from **personal Claude accounts** is dropped by the server as soon as it arrives and is never stored. Monitoring never slows or blocks Claude Code: if the server is down, nothing changes for you.

---

## Day-to-day operations

On the VM, commands run in `~/claude_otel_monitoring`. On Kubernetes, they run in your clone of the repo, and every change is "edit a file, then `kubectl apply -k .`": the ConfigMap and Secret names change with their content, so the pods restart with the new values by themselves.

| Task | Single VM | Kubernetes |
|---|---|---|
| **Add a Company Account** | Add the email to `COMPANY_ACCOUNTS` in `.env` (comma, no spaces), then `docker compose up -d`. | The same edit to `.env`, then `kubectl apply -k .` |
| **Rotate the token** | A new `openssl rand -hex 32` in `.env`, `docker compose up -d` | The same edit, `kubectl apply -k .` |
| **Update to the latest code** | `git pull && docker compose up -d --force-recreate`. The config files are mounted, so a plain `up -d` wouldn't restart the Collector for a changed `collector/config.yaml`; the recreate takes a few seconds and Devices retry. If `nginx/` changed, re-run the `render.sh` line from step 7, then `sudo nginx -t && sudo systemctl reload nginx`. | `git pull && kubectl apply -k .` |
| **View logs** | `docker compose logs -f otel-collector` (or `prometheus`, `grafana`) | `kubectl -n claude-otel logs -f deploy/otel-collector` (or `statefulset/prometheus`, `deploy/grafana`) |
| **Check the certificate** | `sudo certbot certificates --cert-name claude-otel` | `kubectl -n claude-otel get certificate` |
| **Change `DOMAIN`** | New A records, `DOMAIN` in `.env`, `docker compose up -d`, the certbot command from step 6 with the new names (same `--cert-name`), then the `render.sh` line from step 7 | New DNS records, `DOMAIN` in `k8s/settings.env`, `kubectl apply -k .` |
| **Move to another server** | Set up the new VM with the old `.env` (same token and `DOMAIN`), copy the Docker volumes if you want the history, point the two A records at the new IP, then get the certificate (step 6). No Device changes. | Apply to the new cluster with the same two files, restore the PVCs if you want the history, point the DNS records at the new ingress. No Device changes. |
| **Remove a Device** | On the Mac: `sudo ./mac_install.sh --uninstall`. On Windows, in an administrator PowerShell after the `Set-ExecutionPolicy` line: `.\windows_install.ps1 -Uninstall`. Its history stays on the dashboard. | Same |
| **Find a silent Device** | The **Active Devices** tile counts silent Devices; sort the per-Device table by **Last seen (ago)**. | Same |
| **Remove everything** | `sudo rm /etc/nginx/sites-enabled/claude-otel && sudo nginx -t && sudo systemctl reload nginx`, then `docker compose down` (add `-v` to delete the data too) | `kubectl delete -k .` (this deletes the namespace, so the data goes too) |
| **Backups** | Your provider's disk snapshots or backups (step 1). All data is in Docker volumes on the VM's disk. | Your cluster's volume snapshots or Velero |

After rotating the token or changing `DOMAIN`, re-run the setup script on every Device with the new value. Each Device stops reporting until it's updated.

## Known limit: the Claude Desktop app

The Code tab in the Claude Desktop app sends usage too, but it replaces the Device labels (serial number and hostname) with its own. Nothing in the managed settings can override that. The dashboard shows this usage as **Desktop app (&lt;user name&gt;)**. It counts towards cost, tokens and sessions, but not towards Active Devices.

## Try it on your own computer

```bash
cp .env.example .env    # fill in the values
docker compose -f compose.yaml -f compose.local.yaml up -d
sudo ./mac_install.sh --token <OTEL_AUTH_TOKEN> --endpoint http://localhost:4317
```

Grafana is at http://127.0.0.1:13000 (user `admin`).

## Tests

```bash
make test
```

This runs, all in Docker:

- **Config checks:** the Collector and Prometheus configs, the production Compose setup, shellcheck, PSScriptAnalyzer and the dashboard JSON.
- **Setup script tests:** the Mac script's tests, and the Windows script's Pester tests in a PowerShell container (including a check that both write the same settings).
- **Smoke test:** Company Accounts are stored, Personal Accounts are dropped, data without the token is rejected, Grafana is locked down, and the dashboard's queries give the right numbers on known data.
- **Front-door test:** OTLP over TLS and Grafana over HTTPS work through the nginx site, and the stack itself listens on localhost only.
- **Kubernetes checks:** the kustomization renders, is valid against the Kubernetes schemas, uses the same config files as Compose, and exposes nothing but the two Ingresses.

`make test-k8s` runs the Kubernetes path end to end in a throwaway [kind](https://kind.sigs.k8s.io) cluster with ingress-nginx and cert-manager: OTLP over TLS through the Ingress, Company Account kept, Personal Account dropped. It takes a few minutes, so it isn't part of `make test`; run it when you change `k8s/` or `kustomization.yaml`. It needs `kubectl`, and downloads `kind` if it isn't installed.

## What's in the repo

| Path | What it is |
|---|---|
| `mac_install.sh`, `windows_install.ps1` | Device setup for a Mac and a Windows PC (write Claude Code's managed settings) |
| `compose.yaml` | Collector, Prometheus (400-day retention) and Grafana. No published ports. |
| `compose.nginx.yaml`, `nginx/` | Production on a VM: localhost-only ports, memory limits and the nginx site template |
| `kustomization.yaml`, `k8s/` | The Kubernetes path: manifests, Ingresses and the settings example |
| `compose.local.yaml` | Exposes the stack on localhost for trying it on your own computer |
| `collector/`, `prometheus/`, `grafana/` | Service configuration. The dashboard is `grafana/dashboards/claude-code-usage.json`. |
| `.env.example` | Server settings: domain, token, Company Account allowlist, Grafana password |
| `docs/onboard-device.md` | Guide to send someone so they can set up their own Mac or Windows PC |
| `docs/adr/`, `CONTEXT.md` | Why it's built this way, and the words it uses |
| `tests/` | Everything `make test` runs |
