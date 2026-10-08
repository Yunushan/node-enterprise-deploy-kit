function Get-ObviousSecretFindings {
    param([Parameter(Mandatory=$true)] [AllowEmptyString()] [string]$Text, [Parameter(Mandatory=$true)] [string]$RelativePath)
    $path = $RelativePath.Replace('\', '/')
    # These exact public test values exercise privacy, rollback and secret ACLs.
    # A different value or the same value in another file is still a finding.
    $fixtureValues = @{
        'scripts/dev/Test-WindowsDiagnosticPrivacy.ps1' = @('diag-secret-query-value', 'diag-private-environment-value')
        'scripts/dev/Test-WindowsProductionSafety.ps1' = @('fixture-secret', 'fixture-private-environment', 'fixture-private-password', 'fixture-previous-password')
        'scripts/dev/Test-WindowsRuntimeStatus.ps1' = @('must-not-be-returned')
        'scripts/dev/Test-WindowsServiceSecurity.ps1' = @('fixture-only-value')
        'scripts/dev/test-native-systemd-deployment.sh' = @('bad-replacement')
        'scripts/dev/test-unix-hardening.sh' = @('killed-deployment')
        'scripts/dev/test-unix-orchestrator-transactions.sh' = @('killed-deployment', 'changed-owner')
    }
    $allowed = if ($fixtureValues.ContainsKey($path)) { @($fixtureValues[$path]) } else { @() }
    $literalRanges = $null
    if ([IO.Path]::GetExtension($path) -in @('.ps1', '.psm1', '.psd1')) {
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count -eq 0) {
            $literalRanges = @($ast.FindAll({
                param($node)
                ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -ne [Management.Automation.Language.StringConstantType]::BareWord) -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
                ($node -is [Management.Automation.Language.ConstantExpressionAst] -and $node -isnot [Management.Automation.Language.StringConstantExpressionAst])
            },$true))
        }
    }
    $assignment = '(?i)(?:password|secret|token|apikey|api_key)[''"]?\s*[:=]\s*(?<quote>[''"]?)(?<value>[A-Za-z0-9_\-]{12,})'
    foreach ($match in [regex]::Matches($Text,$assignment)) {
        $value = $match.Groups['value']
        if ($null -ne $literalRanges) {
            $literal = @($literalRanges | Where-Object { $value.Index -ge $_.Extent.StartOffset -and ($value.Index + $value.Length) -le $_.Extent.EndOffset })
            # Bare PowerShell commands and expressions are not credential values.
            if ($literal.Count -eq 0) { continue }
            # In an Add-Type code literal, an unquoted identifier followed by a
            # call is a compiled expression. Ordinary log/config strings and
            # quoted credential assignments do not receive this exception.
            $compiledLiteral = @($literal | Where-Object {
                $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $_.StringConstantType -in @([Management.Automation.Language.StringConstantType]::SingleQuotedHereString,[Management.Automation.Language.StringConstantType]::DoubleQuotedHereString) -and
                $_.Parent -is [Management.Automation.Language.CommandAst] -and $_.Parent.GetCommandName() -eq 'Add-Type'
            })
            if ($compiledLiteral.Count -gt 0 -and -not $match.Groups['quote'].Value -and $Text.Substring($value.Index+$value.Length) -match '^\s*\(') { continue }
        }
        $afterValue = $Text.Substring($value.Index+$value.Length)
        if ($allowed -ccontains $value.Value -and ($afterValue.Length -eq 0 -or $afterValue -match '^[\s''";&,)\]}]')) { continue }
        [pscustomobject]@{ Rule='credential-literal'; RelativePath=$path; Line=1+([regex]::Matches($Text.Substring(0,$match.Index),'\n')).Count }
    }
    foreach ($match in [regex]::Matches($Text,'-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----')) {
        [pscustomobject]@{ Rule='private-key'; RelativePath=$path; Line=1+([regex]::Matches($Text.Substring(0,$match.Index),'\n')).Count }
    }
}
