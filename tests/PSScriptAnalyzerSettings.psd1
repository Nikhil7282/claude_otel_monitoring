# PSScriptAnalyzer settings for windows_install.ps1 and its tests (make lint).
@{
    Severity     = @('Error', 'Warning')
    # ShouldProcess (-WhatIf) is for published cmdlets; these are a script's own helpers.
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
    Rules        = @{
        # The script must also run in Windows PowerShell 5.1, which every Windows 10/11 PC has.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
