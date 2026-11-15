# Set up your computer (Device onboarding)

This guide connects Claude Code on your Mac or Windows PC to the company's usage dashboard. It takes about 5 minutes.

**What is collected:** usage numbers only. That means tokens, estimated cost, active time, sessions, lines of code changed, commits, PRs, and how many suggested edits were kept. Each number is labelled with your computer's serial number (or hardware ID) and name, and the Claude account's email.

**What is not collected:** your prompts, Claude's replies, file contents, file paths and commands.

Usage from **personal Claude accounts** is dropped by the server and never stored. If the server is down, Claude Code works exactly as before.

## Before you start

You need:

- **A Mac or a Windows PC with Claude Code installed**, signed in to a **company Claude account**. Only accounts on the company list are recorded. Ask the admin if you're unsure whether yours is on it.
- **Admin rights on the computer**: `sudo` on a Mac, "Run as administrator" on Windows.
- **Two values from the admin**, sent to you privately:
  - the **server domain** (for example `claude.example.com`)
  - the **token**, a 64-character code

Then follow the section for your computer: [Mac](#on-a-mac) or [Windows](#on-a-windows-pc).

## On a Mac

### 1. Download the setup script

```bash
mkdir -p ~/claude-monitoring && cd ~/claude-monitoring
curl -fsSLO https://raw.githubusercontent.com/Nikhil7282/claude_otel_monitoring/main/mac_install.sh
chmod +x mac_install.sh
```

The script runs with admin rights, so it's worth a quick look first: `less mac_install.sh` (press `q` to quit). It only writes one file, `/Library/Application Support/ClaudeCode/managed-settings.json`.

### 2. Run it

Type the token in a way that keeps it out of your shell history:

```bash
read -rs TOKEN        # paste the token, press Enter. Nothing is shown; that's expected.
sudo ./mac_install.sh --token "$TOKEN" --domain <server-domain>
unset TOKEN
```

You should see a line like:

```
Wrote /Library/Application Support/ClaudeCode/managed-settings.json (device.id=<serial>, host.name=<name>, endpoint=https://otel.<server-domain>:443)
```

### 3. Check it

```bash
./mac_install.sh --check
```

The last line should say **`Endpoint otel.<server-domain>:443 is reachable`**. The token shows as `****`.

To remove it later: `cd ~/claude-monitoring && sudo ./mac_install.sh --uninstall`.

Now go to [Use Claude Code](#use-claude-code).

## On a Windows PC

### 1. Open PowerShell as administrator

Press the Windows key, type **PowerShell**, right-click **Windows PowerShell** and choose **Run as administrator**. Run every command below in that window.

Windows blocks downloaded scripts by default. This allows them **for this window only**; it changes nothing permanently:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

### 2. Download the setup script

```powershell
New-Item -ItemType Directory -Force "$HOME\claude-monitoring" | Out-Null
cd "$HOME\claude-monitoring"
Invoke-WebRequest -UseBasicParsing -OutFile windows_install.ps1 `
  https://raw.githubusercontent.com/Nikhil7282/claude_otel_monitoring/main/windows_install.ps1
```

The script runs with admin rights, so it's worth a quick look first: `notepad windows_install.ps1`. It only writes one file, `C:\Program Files\ClaudeCode\managed-settings.json`.

### 3. Run it

Type the token in a way that keeps it out of your PowerShell history:

```powershell
$secure = Read-Host 'Token' -AsSecureString    # paste the token, press Enter. It shows as *****.
$token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
.\windows_install.ps1 -Token $token -Domain <server-domain>
Remove-Variable token, secure
```

You should see a line like:

```
Wrote C:\Program Files\ClaudeCode\managed-settings.json (device.id=<serial>, host.name=<PC name>, endpoint=https://otel.<server-domain>:443)
```

The script uses the PC's serial number as its ID, so the PC keeps its history after a rename or a Windows reinstall. Some self-built PCs have no real serial; the script then uses the motherboard's hardware ID. If it has neither, the script stops and asks for `-DeviceId`. Ask the admin for the PC's asset tag and add it, for example `-DeviceId ASSET-0042`.

### 4. Check it

```powershell
.\windows_install.ps1 -Check
```

The last line should say **`Endpoint otel.<server-domain>:443 is reachable`**. The token shows as `****`.

To remove it later, in an administrator PowerShell: `cd "$HOME\claude-monitoring"`, the `Set-ExecutionPolicy` line from step 1, then `.\windows_install.ps1 -Uninstall`.

## Use Claude Code

1. **Open a new terminal window.** Claude Code only reads the settings when it starts, so sessions that were already open won't report.
2. Run `claude` and use it normally for a few minutes. Make sure you're signed in to the company account; `/status` shows which account is active.
3. After about 2 minutes, your computer appears on the dashboard (`https://grafana.<server-domain>`) in the **Usage per Device** table.

**Using the Claude Desktop app?** Its Code tab reports too, but the app replaces the Device labels with its own. It shows up as **Desktop app (&lt;your user name&gt;)** instead of under your computer's name.

After uninstalling, Claude Code stops sending usage from the next session onwards. Data already collected stays on the dashboard.

## Troubleshooting

| Problem | Fix |
|---|---|
| Mac: `must be run as root` | Run the install command with `sudo` in front. |
| Windows: `must be run as administrator` | Close the window and open PowerShell with **Run as administrator** (step 1). |
| Windows: `running scripts is disabled on this system` | Run the `Set-ExecutionPolicy` line from step 1 in the same window. |
| Windows: `no real serial number ... Re-run with -DeviceId` | Ask the admin for the PC's asset tag and add `-DeviceId <tag>` to the install command. |
| Check says **NOT reachable** | Your network may block outgoing port 443 to that host. Try another network, and check the domain for typos. |
| Not on the dashboard after 5 minutes | Start a **new** terminal and `claude` session, and check `/status` shows a company account. If it still doesn't appear, send the admin the output of the check command. |
| `token has unexpected characters` | The token was copied with extra spaces or quotes. Paste it again, exactly as given. |
