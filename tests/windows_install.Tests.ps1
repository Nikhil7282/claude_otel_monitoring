# Tests for windows_install.ps1 (Windows Device setup script). Run with Pester 5 in the
# PowerShell Docker image (make windows-install-test).
# TEST_SETTINGS_FILE, TEST_SERIAL, TEST_UUID and TEST_HOSTNAME point the script at a temp
# dir and fake the PC's identity, so no admin rights are needed and nothing real is touched.

BeforeAll {
    $script:Install = Join-Path $PSScriptRoot '..' 'windows_install.ps1'
    $script:MacInstall = Join-Path $PSScriptRoot '..' 'mac_install.sh'
    $script:Token = 's3cr3t-T0ken_abc.123'
    $script:Serial = 'CND1234XYZ'
    $script:Uuid = '4C4C4544-0042-3510-8051-B4C04F4E4A32'
    $script:HostName = 'DEV-PC-01'

    # Each test gets a settings path inside a directory that does not exist yet.
    function New-Case {
        $script:CaseDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()) 'ClaudeCode'
        $script:Settings = Join-Path $script:CaseDir 'managed-settings.json'
    }

    # Runs the script in a child pwsh, like an admin would, with the fake identity. Sets
    # $Out (stdout + stderr as one string) and $Status (exit code).
    function Invoke-Install {
        param([string[]]$Arguments, [hashtable]$Identity = @{})
        $values = @{
            TEST_SETTINGS_FILE = $script:Settings
            TEST_SERIAL        = $script:Serial
            TEST_UUID          = $script:Uuid
            TEST_HOSTNAME      = $script:HostName
        }
        foreach ($key in $Identity.Keys) { $values[$key] = $Identity[$key] }
        foreach ($key in $values.Keys) { Set-Item "env:$key" $values[$key] }
        try {
            $script:Out = (& pwsh -NoProfile -File $script:Install @Arguments 2>&1 | Out-String)
            $script:Status = $LASTEXITCODE
        } finally {
            foreach ($key in $values.Keys) { Remove-Item "env:$key" -ErrorAction SilentlyContinue }
        }
    }

    function Get-ExpectedEnv([string]$Endpoint, [string]$DeviceId = $script:Serial) {
        [ordered]@{
            CLAUDE_CODE_ENABLE_TELEMETRY                      = '1'
            OTEL_METRICS_EXPORTER                             = 'otlp'
            OTEL_EXPORTER_OTLP_PROTOCOL                       = 'grpc'
            OTEL_EXPORTER_OTLP_ENDPOINT                       = $Endpoint
            OTEL_EXPORTER_OTLP_HEADERS                        = "Authorization=Bearer $($script:Token)"
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE = 'cumulative'
            OTEL_LOGS_EXPORTER                                = 'none'
            OTEL_RESOURCE_ATTRIBUTES                          = "device.id=$DeviceId,host.name=$($script:HostName)"
        }
    }

    # The env block as sorted "key=value" lines, so two files compare regardless of order.
    function Get-EnvBlock([string]$Path) {
        $json = Get-Content -Raw $Path | ConvertFrom-Json
        $json.env.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
    }

    function Get-ExpectedBlock([System.Collections.IDictionary]$Expected) {
        $Expected.Keys | Sort-Object | ForEach-Object { "$_=$($Expected[$_])" }
    }
}

Describe 'Install with a domain' {
    BeforeAll {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
    }
    It 'succeeds' { $Status | Should -Be 0 }
    It 'writes the expected env block' {
        Get-EnvBlock $Settings | Should -Be (Get-ExpectedBlock (Get-ExpectedEnv 'https://otel.example.com:443'))
    }
    It 'writes a file with only an env key' {
        (Get-Content -Raw $Settings | ConvertFrom-Json).PSObject.Properties.Name | Should -Be @('env')
    }
    It 'writes UTF-8 without a byte order mark' {
        $bytes = [System.IO.File]::ReadAllBytes($Settings)
        $bytes[0] | Should -Be ([byte][char]'{')
    }
    It 'turns on no content logging' {
        $names = (Get-Content -Raw $Settings | ConvertFrom-Json).env.PSObject.Properties.Name
        $names | Where-Object { $_ -like 'OTEL_LOG_*' } | Should -BeNullOrEmpty
    }
    It 'leaves no temp files behind' {
        @(Get-ChildItem -Force $CaseDir).Count | Should -Be 1
    }
    It 'reports what it wrote without the token' {
        $Out | Should -Match 'device.id=CND1234XYZ'
        $Out | Should -Not -Match ([regex]::Escape($Token))
    }
    It 'writes the same env block as the Mac script for the same inputs' {
        $macSettings = Join-Path $CaseDir 'mac.json'
        $env:TEST_SETTINGS_FILE = $macSettings
        $env:TEST_SERIAL = $Serial
        $env:TEST_HOSTNAME = $HostName
        try {
            & bash $MacInstall --token $Token --domain example.com | Out-Null
        } finally {
            Remove-Item env:TEST_SETTINGS_FILE, env:TEST_SERIAL, env:TEST_HOSTNAME
        }
        Get-EnvBlock $Settings | Should -Be (Get-EnvBlock $macSettings)
    }
}

Describe 'Install with an endpoint' {
    It 'writes that endpoint' {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Endpoint', 'http://localhost:4317'
        $Status | Should -Be 0
        Get-EnvBlock $Settings | Should -Be (Get-ExpectedBlock (Get-ExpectedEnv 'http://localhost:4317'))
    }
}

Describe 'Re-running' {
    It 'produces an identical file' {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
        $first = [System.IO.File]::ReadAllBytes($Settings)
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
        $Status | Should -Be 0
        [System.IO.File]::ReadAllBytes($Settings) | Should -Be $first
    }
    It 'replaces an older endpoint and token completely' {
        New-Case
        Invoke-Install -Arguments '-Token', 'old-token', '-Endpoint', 'http://localhost:4317'
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
        Get-EnvBlock $Settings | Should -Be (Get-ExpectedBlock (Get-ExpectedEnv 'https://otel.example.com:443'))
    }
}

Describe 'Bad options' {
    It 'fails without -Token: <Name>' -ForEach @(
        @{ Name = 'no token'; Arguments = @('-Domain', 'example.com') }
        @{ Name = 'neither domain nor endpoint'; Arguments = @('-Token', 's3cr3t') }
        @{ Name = 'both domain and endpoint'; Arguments = @('-Token', 's3cr3t', '-Domain', 'example.com', '-Endpoint', 'http://localhost:4317') }
        @{ Name = 'unknown option'; Arguments = @('-Token', 's3cr3t', '-Domain', 'example.com', '-Bogus', 'x') }
    ) {
        New-Case
        Invoke-Install -Arguments $Arguments
        $Status | Should -Not -Be 0
        Test-Path $CaseDir | Should -BeFalse
    }
    It 'explains a missing token' {
        New-Case
        Invoke-Install -Arguments '-Domain', 'example.com'
        $Out | Should -Match '-Token is required'
    }
}

Describe 'Unsafe values are rejected and nothing is written' {
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a token with a quote'; Arguments = @('-Token', 'abc"def', '-Domain', 'example.com'); Identity = @{} }
        @{ Name = 'a token with a comma'; Arguments = @('-Token', 'abc,def', '-Domain', 'example.com'); Identity = @{} }
        @{ Name = 'a domain with a slash'; Arguments = @('-Token', 's3cr3t', '-Domain', 'example.com/x'); Identity = @{} }
        @{ Name = 'an endpoint without a port'; Arguments = @('-Token', 's3cr3t', '-Endpoint', 'https://otel.example.com'); Identity = @{} }
        @{ Name = 'a Device ID with a comma'; Arguments = @('-Token', 's3cr3t', '-Domain', 'example.com', '-DeviceId', 'a,b'); Identity = @{} }
        @{ Name = 'a hostname with an equals sign'; Arguments = @('-Token', 's3cr3t', '-Domain', 'example.com'); Identity = @{ TEST_HOSTNAME = 'pc=1' } }
    ) {
        New-Case
        Invoke-Install -Arguments $Arguments -Identity $Identity
        $Status | Should -Not -Be 0
        $Out | Should -Match 'unexpected characters'
        Test-Path $CaseDir | Should -BeFalse
    }
}

Describe 'Device ID' {
    It 'uses a real BIOS serial' {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
        (Get-Content -Raw $Settings | ConvertFrom-Json).env.OTEL_RESOURCE_ATTRIBUTES | Should -Be "device.id=$Serial,host.name=$HostName"
    }
    It 'falls back to the SMBIOS UUID when the serial is "<Serial>"' -ForEach @(
        @{ Serial = ' ' }
        @{ Serial = 'To be filled by O.E.M.' }
        @{ Serial = 'Default string' }
        @{ Serial = 'System Serial Number' }
        @{ Serial = 'Not Specified' }
        @{ Serial = '0' }
        @{ Serial = '00000000' }
        @{ Serial = 'FFFFFFFF' }
        @{ Serial = 'VMware-56 4d 12 34' }
    ) {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com' -Identity @{ TEST_SERIAL = $Serial }
        $Status | Should -Be 0
        (Get-Content -Raw $Settings | ConvertFrom-Json).env.OTEL_RESOURCE_ATTRIBUTES | Should -Be "device.id=$Uuid,host.name=$HostName"
    }
    It 'fails and asks for -DeviceId when the UUID is also "<Uuid>"' -ForEach @(
        @{ Uuid = '00000000-0000-0000-0000-000000000000' }
        @{ Uuid = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF' }
        @{ Uuid = '03000200-0400-0500-0006-000700080009' }
        @{ Uuid = ' ' }
    ) {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com' -Identity @{ TEST_SERIAL = 'Default string'; TEST_UUID = $Uuid }
        $Status | Should -Not -Be 0
        $Out | Should -Match '-DeviceId'
        Test-Path $CaseDir | Should -BeFalse
    }
    It 'prefers -DeviceId over the serial and the UUID' {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com', '-DeviceId', 'ASSET-0042'
        $Status | Should -Be 0
        Get-EnvBlock $Settings | Should -Be (Get-ExpectedBlock (Get-ExpectedEnv 'https://otel.example.com:443' 'ASSET-0042'))
    }
}

Describe '-Check' {
    It 'fails when nothing is installed' {
        New-Case
        Invoke-Install -Arguments '-Check'
        $Status | Should -Not -Be 0
        $Out | Should -Match 'not installed'
    }
    It 'masks the token and reports a reachable endpoint' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            New-Case
            Invoke-Install -Arguments '-Token', $Token, '-Endpoint', "http://127.0.0.1:$port"
            Invoke-Install -Arguments '-Check'
            $Status | Should -Be 0
            $Out | Should -Match 'Bearer \*\*\*\*'
            $Out | Should -Not -Match ([regex]::Escape($Token))
            $Out | Should -Match "127.0.0.1:$port is reachable"
        } finally {
            $listener.Stop()
        }
    }
    It 'reports an unreachable endpoint and fails' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Endpoint', "http://127.0.0.1:$port"
        Invoke-Install -Arguments '-Check'
        $Status | Should -Not -Be 0
        $Out | Should -Match 'NOT reachable'
    }
}

Describe '-Check with an endpoint written without a port' {
    It 'uses the default port for <Scheme>, like the Mac script' -ForEach @(
        @{ Scheme = 'https'; Port = 443 }
        @{ Scheme = 'http'; Port = 80 }
    ) {
        New-Case
        New-Item -ItemType Directory -Force $CaseDir | Out-Null
        Set-Content -LiteralPath $Settings -Value ('{"env": {"OTEL_EXPORTER_OTLP_ENDPOINT": "' + $Scheme + '://127.0.0.1"}}')
        Invoke-Install -Arguments '-Check'
        $Out | Should -Match "127.0.0.1:$Port is"
    }
}

Describe '-Uninstall' {
    It 'removes the settings file' {
        New-Case
        Invoke-Install -Arguments '-Token', $Token, '-Domain', 'example.com'
        Invoke-Install -Arguments '-Uninstall'
        $Status | Should -Be 0
        Test-Path $Settings | Should -BeFalse
    }
}

Describe 'Default settings location' {
    It 'is the current Windows managed-settings path, not the legacy ProgramData one' {
        $source = Get-Content -Raw $Install
        $source | Should -Match ([regex]::Escape('C:\Program Files\ClaudeCode\managed-settings.json'))
        $source | Should -Not -Match 'ProgramData'
    }
}
