# Set up your Mac (Device onboarding)

This guide connects your Mac's Claude Code to the company's usage dashboard. It takes about 5 minutes.

**What is collected:** usage numbers only. That means tokens, estimated cost, active time, sessions, lines of code changed, commits, PRs, and how many suggested edits were kept. Each number is labelled with your Mac's serial number and hostname and the Claude account's email.

**What is not collected:** your prompts, Claude's replies, file contents, file paths and commands.

Usage from **personal Claude accounts** is dropped by the server and never stored. If the server is down, Claude Code works exactly as before.

## Before you start

You need:

- **A Mac with Claude Code installed**, signed in to a **company Claude account**. Only accounts on the company list are recorded. Ask the admin if you're unsure whether yours is on it.
- **Admin rights on the Mac**, because the setup uses `sudo`.
- **Two values from the admin**, sent to you privately:
  - the **server domain** (for example `13-235-40-7.sslip.io`)
  - the **token**, a 64-character code

## 1. Download the setup script

```bash
mkdir -p ~/claude-monitoring && cd ~/claude-monitoring
curl -fsSLO https://raw.githubusercontent.com/Nikhil7282/claude_otel_monitoring/main/install.sh
chmod +x install.sh
```

The script runs with admin rights, so it's worth a quick look first: `less install.sh` (press `q` to quit). It only writes one file, `/Library/Application Support/ClaudeCode/managed-settings.json`.

## 2. Run it

Type the token in a way that keeps it out of your shell history:

```bash
read -rs TOKEN        # paste the token, press Enter. Nothing is shown; that's expected.
sudo ./install.sh --token "$TOKEN" --domain <server-domain>
unset TOKEN
```

You should see a line like:

```
Wrote /Library/Application Support/ClaudeCode/managed-settings.json (device.id=<serial>, host.name=<name>, endpoint=https://otel.<server-domain>:443)
```

## 3. Check it

```bash
./install.sh --check
```

The last line should say **`Endpoint otel.<server-domain>:443 is reachable`**. The token shows as `****`.

## 4. Use Claude Code

1. **Open a new terminal window.** Claude Code only reads the settings when it starts, so sessions that were already open won't report.
2. Run `claude` and use it normally for a few minutes. Make sure you're signed in to the company account; `/status` shows which account is active.
3. After about 2 minutes, your Mac appears on the dashboard (`https://grafana.<server-domain>`) in the **Usage per Device** table.

## Remove it

```bash
cd ~/claude-monitoring && sudo ./install.sh --uninstall
```

Claude Code stops sending usage from the next session onwards. Data already collected stays on the dashboard.

## Troubleshooting

| Problem | Fix |
|---|---|
| `must be run as root` | Run the install command with `sudo` in front. |
| `--check` says **NOT reachable** | Your network may block outgoing port 443 to that host. Try another network, and check the domain for typos. |
| Not on the dashboard after 5 minutes | Start a **new** terminal and `claude` session, and check `/status` shows a company account. If it still doesn't appear, send the admin the output of `./install.sh --check`. |
| `--token has unexpected characters` | The token was copied with extra spaces or quotes. Paste it again, exactly as given. |
