# Claude Code usage monitoring

Shows how the company's Claude Code accounts are used on each developer Mac: estimated cost, tokens, active time, sessions, lines of code, commits, PRs and how many suggested edits were kept.

The data comes from Claude Code's built-in OpenTelemetry export, so nothing sits between Claude Code and Anthropic. [ADR-0001](docs/adr/0001-telemetry-not-api-proxy.md) explains why this isn't a proxy. Usage from personal Claude accounts is dropped when it arrives and never stored.

```
Mac: Claude Code ──OTLP──► Caddy ──► OTel Collector ──► Prometheus ◄── Grafana ◄── Caddy ◄── browser
                                     (token check +
                                      Company Account filter)
```

| Path | What it is |
|---|---|
| `install.sh` | Sets up a Mac as a Device (writes Claude Code's managed settings) |
| `compose.yaml` | Collector, Prometheus (400-day retention) and Grafana. No public ports. |
| `compose.prod.yaml` | Adds Caddy (TLS, the only public service) and memory limits |
| `compose.local.yaml` | Exposes the stack on localhost for trying it on a laptop |
| `collector/`, `prometheus/`, `grafana/`, `caddy/` | Service configuration. The dashboard is `grafana/dashboards/claude-code-usage.json`. |
| `.env.example` | Server settings: token, Company Account allowlist, Grafana password, domain |
| `docs/deploy.md` | Step-by-step deployment to EC2 and Device onboarding |

## Try it locally

```bash
cp .env.example .env    # fill in the values
docker compose -f compose.yaml -f compose.local.yaml up -d
sudo ./install.sh --token <OTEL_AUTH_TOKEN> --endpoint http://localhost:4317
```

Grafana is at http://127.0.0.1:13000 (user `admin`).

## Tests

```bash
make test
```

This runs four things, all in Docker:

- **Config checks:** Collector, Prometheus, Caddy, shellcheck and the dashboard JSON.
- **Setup script tests:** the install script's own tests.
- **Smoke test:** Company Accounts are stored, Personal Accounts are dropped, data without the token is rejected, and Grafana is locked down.
- **Front-door test:** TLS through Caddy works, and only Caddy is exposed.
