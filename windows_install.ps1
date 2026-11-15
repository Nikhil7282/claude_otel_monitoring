<#
.SYNOPSIS
Device setup for a Windows PC: points Claude Code's OpenTelemetry metrics at the monitoring
server.

.DESCRIPTION
Writes Claude Code's managed-settings file, which developers cannot override. It is the
Windows counterpart of mac_install.sh and writes the same settings. Works in Windows
PowerShell 5.1 and PowerShell 7.

Usage (in a PowerShell window opened with "Run as administrator"):
  .\windows_install.ps1 -Token TOKEN -Domain DOMAIN      endpoint becomes https://otel.DOMAIN:443
  .\windows_install.ps1 -Token TOKEN -Endpoint URL       e.g. http://localhost:4317
  .\windows_install.ps1 ... -DeviceId ASSET-TAG          when the PC has no real serial number
  .\windows_install.ps1 -Check                           show settings (token masked), test endpoint
  .\windows_install.ps1 -Uninstall                       remove the settings file
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$Domain,
    [string]$Endpoint,
    [string]$DeviceId,
    [switch]$Check,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Claude Code reads this location only; older guides show a path it no longer reads.
$SettingsFile = 'C:\Program Files\ClaudeCode\managed-settings.json'
if ($env:TEST_SETTINGS_FILE) { $SettingsFile = $env:TEST_SETTINGS_FILE }

# Values go into JSON strings and into comma/equals separated OTEL env values, so only allow
# characters that need no escaping in either place. Same rules as mac_install.sh.
$SafeId = '^[A-Za-z0-9._-]+$'
$SafeToken = '^[A-Za-z0-9._~+/-]+=*$'
$SafeDomain = '^[A-Za-z0-9.-]+$'
$SafeEndpoint = '^https?://([A-Za-z0-9.-]+):([0-9]+)$'

# Values that motherboard makers leave in place of a real serial number or UUID. Two PCs with
# the same placeholder would merge into one Device, so these are never used as a Device ID.
$PlaceholderSerials = @(
    'To be filled by O.E.M.', 'To Be Filled By O.E.M.', 'Default string', 'System Serial Number',
    'Chassis Serial Number', 'Not Specified', 'Not Applicable', 'None', 'N/A', 'Invalid',
    '123456789', '0123456789'
)
$PlaceholderUuids = @(
    '00000000-0000-0000-0000-000000000000',
    'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
    '03000200-0400-0500-0006-000700080009'
)

function Exit-WithError([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

function Exit-WithUsage([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
    [Console]::Error.WriteLine('Usage: .\windows_install.ps1 -Token TOKEN (-Domain DOMAIN | -Endpoint URL) [-DeviceId ID] | -Check | -Uninstall')
    exit 2
}

function Assert-Safe([string]$Name, [string]$Value, [string]$Pattern) {
    if ($Value -notmatch $Pattern) { Exit-WithError "$Name has unexpected characters: $Value" }
}

function Assert-Administrator {
    # The test override writes to a temp path, so admin rights are not needed there.
    if ($env:TEST_SETTINGS_FILE) { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Exit-WithError 'must be run as administrator (right-click PowerShell, "Run as administrator")'
    }
}

function Get-BiosSerial {
    if ($null -ne $env:TEST_SERIAL) { return $env:TEST_SERIAL }
    return [string](Get-CimInstance -ClassName Win32_BIOS).SerialNumber
}

function Get-SmbiosUuid {
    if ($null -ne $env:TEST_UUID) { return $env:TEST_UUID }
    return [string](Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID
}

function Get-PcName {
    if ($null -ne $env:TEST_HOSTNAME) { return $env:TEST_HOSTNAME }
    return $env:COMPUTERNAME
}

function Test-UsableSerial([string]$Serial) {
    $value = $Serial.Trim()
    if ($value -eq '') { return $false }
    if ($PlaceholderSerials -contains $value) { return $false }
    if ($value -match '^(0+|F+)$') { return $false }
    # A serial with spaces or symbols (some virtual machines) can't go into the settings.
    return ($value -match $SafeId)
}

function Test-UsableUuid([string]$Uuid) {
    $value = $Uuid.Trim()
    if ($value -eq '') { return $false }
    if ($PlaceholderUuids -contains $value.ToUpperInvariant()) { return $false }
    return ($value -match $SafeId)
}

# The Device ID must survive a rename and a Windows reinstall, so it comes from the hardware.
function Resolve-DeviceId([string]$Given) {
    if ($Given) {
        Assert-Safe '-DeviceId' $Given $SafeId
        return $Given
    }
    $serial = Get-BiosSerial
    if (Test-UsableSerial $serial) { return $serial.Trim() }
    $uuid = Get-SmbiosUuid
    if (Test-UsableUuid $uuid) { return $uuid.Trim().ToUpperInvariant() }
    Exit-WithError ("this PC has no real serial number ('$serial') or hardware UUID ('$uuid'). " +
        'Re-run with -DeviceId and the PC''s asset tag, for example -DeviceId ASSET-0042.')
}

function Write-SettingsFile([string]$InstallToken, [string]$InstallEndpoint, [string]$GivenDeviceId) {
    Assert-Administrator
    $id = Resolve-DeviceId $GivenDeviceId
    $pcName = Get-PcName
    if (-not $pcName) { Exit-WithError 'could not read the computer name' }
    Assert-Safe 'computer name' $pcName $SafeId

    $json = @(
        '{'
        '  "env": {'
        '    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",'
        '    "OTEL_METRICS_EXPORTER": "otlp",'
        '    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",'
        "    `"OTEL_EXPORTER_OTLP_ENDPOINT`": `"$InstallEndpoint`","
        "    `"OTEL_EXPORTER_OTLP_HEADERS`": `"Authorization=Bearer $InstallToken`","
        '    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",'
        '    "OTEL_LOGS_EXPORTER": "none",'
        "    `"OTEL_RESOURCE_ATTRIBUTES`": `"device.id=$id,host.name=$pcName`""
        '  }'
        '}'
        ''
    ) -join "`n"

    $dir = Split-Path -Parent $SettingsFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Temp file in the same directory, then a rename, so Claude Code never reads half a file.
    # UTF-8 without a byte order mark: Windows PowerShell 5.1 would add one by default.
    $tmp = Join-Path $dir ('.managed-settings.' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $SettingsFile -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    Write-Output "Wrote $SettingsFile (device.id=$id, host.name=$pcName, endpoint=$InstallEndpoint)"
}

function Show-SettingsFile {
    if (-not (Test-Path -LiteralPath $SettingsFile)) {
        Exit-WithError "not installed: $SettingsFile does not exist"
    }
    Write-Output "Settings file: $SettingsFile"
    $text = [System.IO.File]::ReadAllText($SettingsFile)
    Write-Output ($text -replace 'Bearer [^"]*', 'Bearer ****').TrimEnd()

    # Like mac_install.sh --check: an endpoint without a port means the scheme's default.
    $configured = (ConvertFrom-Json $text).env.OTEL_EXPORTER_OTLP_ENDPOINT
    if ($configured -notmatch '^(https?)://([A-Za-z0-9.-]+)(:([0-9]+))?(/.*)?$') {
        Exit-WithError "no usable OTEL_EXPORTER_OTLP_ENDPOINT in $SettingsFile"
    }
    $hostName = $Matches[2]
    if ($Matches[4]) { $port = [int]$Matches[4] }
    elseif ($Matches[1] -eq 'https') { $port = 443 }
    else { $port = 80 }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $reachable = $false
        try { $reachable = $client.ConnectAsync($hostName, $port).Wait(3000) } catch { $reachable = $false }
    } finally {
        $client.Dispose()
    }
    if ($reachable) {
        Write-Output "Endpoint ${hostName}:$port is reachable"
    } else {
        Write-Output "Endpoint ${hostName}:$port is NOT reachable"
        exit 1
    }
}

function Remove-SettingsFile {
    Assert-Administrator
    if (Test-Path -LiteralPath $SettingsFile) { Remove-Item -LiteralPath $SettingsFile -Force }
    Write-Output "Removed $SettingsFile"
}

if ($Check) { Show-SettingsFile; exit 0 }
if ($Uninstall) { Remove-SettingsFile; exit 0 }

if (-not $Token) { Exit-WithUsage '-Token is required' }
if ($Domain -and $Endpoint) { Exit-WithUsage 'give -Domain or -Endpoint, not both' }
if (-not $Domain -and -not $Endpoint) { Exit-WithUsage '-Domain or -Endpoint is required' }
Assert-Safe '-Token' $Token $SafeToken
if ($Domain) {
    Assert-Safe '-Domain' $Domain $SafeDomain
    $Endpoint = "https://otel.${Domain}:443"
}
Assert-Safe '-Endpoint' $Endpoint $SafeEndpoint
Write-SettingsFile $Token $Endpoint $DeviceId
exit 0
