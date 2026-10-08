function Assert-WindowsDeploymentAppName {
    param([Parameter(Mandatory=$true)] [AllowEmptyString()] [string]$AppName)
    if ($AppName -cnotmatch '^[A-Za-z0-9_.-]+$' -or $AppName -in @('.', '..') -or $AppName.EndsWith('.')) {
        throw 'AppName must be an ASCII deployment identity without traversal or a trailing dot.'
    }
    # Win32 device names remain reserved with an extension. Use invariant case
    # matching so the deployment, lock and scheduled monitor agree in all locales.
    if ([regex]::IsMatch($AppName, '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
            ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))) {
        throw 'AppName must not use a reserved Windows device name, including a device name with an extension.'
    }
}

function ConvertFrom-WindowsPm2ProcessJson {
    param([Parameter(Mandatory=$true)] [AllowEmptyString()] [string]$Json)
    $text = $Json.Trim()
    if (-not $text.StartsWith('[') -or -not $text.EndsWith(']')) { throw 'PM2 process state must be a JSON array.' }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) { $parsed = ConvertFrom-Json -InputObject $text -NoEnumerate -ErrorAction Stop }
        else { $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    } catch { throw 'PM2 process state is invalid JSON.' }
    # ConvertFrom-Json enumerates arrays differently on PS5.1 and PS7. Preserve
    # a genuine empty list without treating a JSON null entry as an empty list.
    if ($text -match '^\[\s*\]$') { return }
    $entries = @($parsed)
    foreach ($entry in $entries) {
        if ($null -eq $entry) { throw 'PM2 process state contains a null entry.' }
        if ($entry -isnot [pscustomobject]) { throw 'PM2 process state entries must be JSON objects.' }
    }
    return $entries
}

function Assert-WindowsPm2DeploymentAppName {
    param([Parameter(Mandatory=$true)] [AllowEmptyString()] [string]$AppName)
    Assert-WindowsDeploymentAppName -AppName $AppName
    # PM2 accepts 'all' and JS Number-coercible strings as selectors, and its
    # CLI parses leading dashes as options. Never pass these as an app identity.
    $jsNumber = '^(?:Infinity|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE]-?[0-9]+)?|0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+)$'
    if ($AppName.Equals('all', [StringComparison]::OrdinalIgnoreCase) -or $AppName.StartsWith('-') -or
        [regex]::IsMatch($AppName, $jsNumber, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'PM2 AppName must be an app name, not the all selector, a CLI option, or a JavaScript numeric selector.'
    }
}

function Assert-WindowsDeploymentConfigIdentity {
    param([Parameter(Mandatory=$true)] $Config)
    Assert-WindowsDeploymentAppName -AppName ([string]$Config.AppName)
    $mode = ''; $manager = ''
    if ($Config -is [Collections.IDictionary]) { $mode = [string]$Config['DeploymentMode']; $manager = [string]$Config['ServiceManager'] }
    else {
        if ($Config.PSObject.Properties['DeploymentMode']) { $mode = [string]$Config.DeploymentMode }
        if ($Config.PSObject.Properties['ServiceManager']) { $manager = [string]$Config.ServiceManager }
    }
    $mode = $mode.Trim().ToLowerInvariant().Replace('_', '-')
    if ($mode -ne 'static-iis' -and $manager.Trim().ToLowerInvariant() -eq 'pm2') {
        Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    }
}

function Get-WindowsPm2ExactProcessIds {
    param(
        [Parameter(Mandatory=$true)] [AllowEmptyCollection()] [object[]]$Entries,
        [Parameter(Mandatory=$true)] [string]$AppName,
        [string]$SelectorWorkingDirectory = ''
    )
    Assert-WindowsPm2DeploymentAppName -AppName $AppName
    $selected = [Collections.Generic.List[long]]::new()
    $knownIds = [Collections.Generic.HashSet[long]]::new()
    foreach ($entry in $Entries) {
        if ($null -eq $entry -or -not $entry.PSObject.Properties['pm2_env'] -or $null -eq $entry.pm2_env -or
            -not $entry.PSObject.Properties['name'] -or $entry.name -isnot [string] -or
            -not $entry.pm2_env.PSObject.Properties['name'] -or $entry.pm2_env.name -isnot [string] -or
            [string]::IsNullOrEmpty($entry.name) -or $entry.name -cne $entry.pm2_env.name) {
            throw 'PM2 returned inconsistent process names; refusing ambiguous process selection.'
        }
        if (-not $entry.PSObject.Properties['pm_id']) { throw 'PM2 process state is missing its numeric process ID.' }
        $rawId = $entry.pm_id
        if ($rawId -isnot [byte] -and $rawId -isnot [sbyte] -and $rawId -isnot [int16] -and $rawId -isnot [uint16] -and
            $rawId -isnot [int32] -and $rawId -isnot [uint32] -and $rawId -isnot [int64] -and $rawId -isnot [uint64] -and
            $rawId -isnot [single] -and $rawId -isnot [double] -and $rawId -isnot [decimal]) {
            throw 'PM2 process ID must be a JSON nonnegative integer.'
        }
        try { $numericId = [decimal]$rawId } catch { throw 'PM2 process ID must be a finite nonnegative integer.' }
        if ($numericId -lt 0 -or $numericId -gt 9007199254740991 -or [decimal]::Truncate($numericId) -ne $numericId) {
            throw 'PM2 process ID must be a safely representable nonnegative integer.'
        }
        $processId = [long]$numericId
        if (-not $knownIds.Add($processId)) { throw 'PM2 returned duplicate process IDs; refusing ambiguous process selection.' }
        if ($entry.name.Equals($AppName, [StringComparison]::OrdinalIgnoreCase) -and $entry.name -cne $AppName) {
            throw 'A differently cased PM2 app already uses this Windows deployment identity; migrate its name explicitly.'
        }
        if ($entry.name -ceq $AppName) { $selected.Add($processId) }
    }
    if ($selected.Count -eq 0) { return }
    if ([string]::IsNullOrWhiteSpace($SelectorWorkingDirectory)) { $SelectorWorkingDirectory = (Get-Location).ProviderPath }
    if (-not [IO.Path]::IsPathRooted($SelectorWorkingDirectory)) { throw 'PM2 selector working directory must be an absolute filesystem path.' }
    $workingDirectory = [IO.Path]::GetFullPath($SelectorWorkingDirectory)
    foreach ($processId in $selected) {
        $selector = $processId.ToString([Globalization.CultureInfo]::InvariantCulture)
        $selectorPath = [IO.Path]::GetFullPath((Join-Path $workingDirectory $selector))
        # PM2 resolves numeric CLI arguments through names/exec paths and then
        # namespaces before treating them as IDs. Refuse every such collision.
        foreach ($entry in $Entries) {
            $environment = $entry.pm2_env
            if ($environment.name -ceq $selector -or
                ($environment.PSObject.Properties['namespace'] -and [string]$environment.namespace -ceq $selector) -or
                ($environment.PSObject.Properties['pm_exec_path'] -and
                 [string]::Equals([string]$environment.pm_exec_path, $selectorPath, [StringComparison]::OrdinalIgnoreCase))) {
                throw "PM2 process ID '$selector' collides with a name, namespace, or executable selector; resolve the collision explicitly."
            }
        }
    }
    return $selected.ToArray()
}
