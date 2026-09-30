@{
    # PSScriptAnalyzer settings for host/flash.ps1 and ci/test-flash.ps1.
    # Used by .github/workflows/test-flash.yml and for local runs:
    #   Invoke-ScriptAnalyzer -Path host/flash.ps1 -Settings PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # flash.ps1 is an interactive CLI; Write-Host is the intended output channel.
        'PSAvoidUsingWriteHost',
        # -UserName/-Password mirror flash.sh's -u/-p and end up as a hashed
        # userconf.txt on the SD card. A PSCredential would not change that.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        # Install-Imager / Uninstall-Imager / Invoke-Flash already prompt the
        # user themselves; -WhatIf support would add nothing here.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Script-level params are consumed inside main(); PSSA cannot see that.
        'PSReviewUnusedParameter',
        # Get-BootRoot retries drive-letter assignment; a failed attempt is
        # expected and the loop continues.
        'PSAvoidUsingEmptyCatchBlock',
        # ci/test-flash.ps1 loads flash.ps1's function definitions via
        # Invoke-Expression on purpose (main() must not run).
        'PSAvoidUsingInvokeExpression'
    )
}
