# Claude Code usage monitoring

Shows how the company's Claude Code accounts are used on each developer Mac: estimated cost, tokens, active time, sessions, lines of code, commits, PRs and how many suggested edits were kept.

The data comes from Claude Code's built-in OpenTelemetry export, so nothing sits between Claude Code and Anthropic. [ADR-0001](docs/adr/0001-telemetry-not-api-proxy.md) explains why this isn't a proxy. Usage from personal Claude accounts is dropped when it arrives and never stored.

```
Mac: Claude Code ──OTLP──► nginx ──► OTel Collector ──► Prometheus ◄── Grafana ◄── nginx ◄── browser
                                     (token check +
                                      Company Account filter)
```

| Path | What it is |
|---|---|
| `mac_install.sh` | Sets up a Mac as a Device (writes Claude Code's managed settings) |
| `windows_install.ps1` | Sets up a Windows PC as a Device (the same settings) |
| `compose.yaml` | Collector, Prometheus (400-day retention) and Grafana. No public ports. |
| `compose.nginx.yaml`, `nginx/` | Production setup behind the server's nginx (the only front door, [ADR-0002](docs/adr/0002-nginx-is-the-only-front-door.md)): localhost-only ports, memory limits and an nginx site template |
| `compose.local.yaml` | Exposes the stack on localhost for trying it on a laptop |
| `collector/`, `prometheus/`, `grafana/` | Service configuration. The dashboard is `grafana/dashboards/claude-code-usage.json`. |
| `.env.example` | Server settings: token, Company Account allowlist, Grafana password, domain |
| `docs/deploy-hostinger.md` | Step-by-step deployment behind an existing nginx (the current Hostinger server) |
| `docs/deploy.md` | Step-by-step deployment to EC2 and Device onboarding |
| `docs/onboard-device.md` | Guide to send someone so they can set up their own Mac or Windows PC |

## Known limit: the Claude Desktop app

The Code tab in the Claude Desktop app sends usage too, but it replaces the Device labels (serial number and hostname) with its own. Nothing in the managed settings can override that. The dashboard shows this usage as **Desktop app (&lt;Mac user name&gt;)**. It counts towards cost, tokens and sessions, but not towards Active Devices.

## Try it locally

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

This runs five things, all in Docker:

- **Config checks:** Collector, Prometheus, the production Compose setup, shellcheck and the dashboard JSON.
- **Setup script tests:** the Mac script's tests, and the Windows script's Pester tests (in a PowerShell container).
- **Smoke test:** Company Accounts are stored, Personal Accounts are dropped, data without the token is rejected, and Grafana is locked down.
- **Front-door test:** OTLP over TLS and Grafana over HTTPS work through the nginx site, and the stack itself listens on localhost only.
