Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DeploymentLock.ps1')
. (Join-Path $PSScriptRoot 'WindowsServiceSecurity.ps1')

function Get-IisDeploymentControlDirectory {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'node-enterprise-deploy-kit\deployment-control\iis'
}

function Enter-IisDeploymentLock {
    param([string]$JournalDirectory, $AppLock)
    if ($AppLock -and ($AppLock.OwnerProcessId -ne $PID -or $AppLock.Stream -isnot [IO.FileStream] -or -not $AppLock.Stream.CanWrite)) { throw 'IIS application lease requires a live deployment stream owned by this process.' }
    $directory = Get-IisDeploymentControlDirectory
    Assert-DeploymentPathNotReparsePoint $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-ProtectedDeploymentLockDirectoryAcl $directory
    $path = Join-Path $directory 'configuration.lock'
    Assert-DeploymentPathNotReparsePoint $path
    try { $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another IIS deployment holds the global configuration lock. Retry after it finishes.' }
    try {
        $currentJournal = [IO.Path]::GetFullPath($JournalDirectory).TrimEnd('\', '/')
        $retainedJournals = @(Get-ChildItem -LiteralPath $directory -Directory -Filter 'installer.*' -Force -ErrorAction Stop | Where-Object { [IO.Path]::GetFullPath($_.FullName).TrimEnd('\', '/') -ine $currentJournal })
        if ($retainedJournals.Count -gt 0) {
            throw "Unresolved IIS installer recovery journal exists. Inspect and recover the protected state before changing IIS, then archive the journal: $($retainedJournals.FullName -join ', ')"
        }
        $leasePath = Join-Path $JournalDirectory 'iis-lock-lease.xml'
        $token = [Guid]::NewGuid().ToString('N')
        $lease = [pscustomobject]@{ Path = $path; OwnerProcessId = $PID; OwnerStartTimeUtcTicks = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks; Token = $token; AppName = $(if ($AppLock) { [string]$AppLock.AppName } else { '' }); AppLockPath = $(if ($AppLock) { [string]$AppLock.Path } else { '' }) }
        $lease | Export-Clixml -LiteralPath $leasePath
        if (-not (Get-Variable -Name NodeDeployKitIisDeploymentLocks -Scope Global -ErrorAction SilentlyContinue)) { $global:NodeDeployKitIisDeploymentLocks = @{} }
        $global:NodeDeployKitIisDeploymentLocks[$token] = $stream
        return [pscustomobject]@{ LeasePath = $leasePath; Token = $token }
    } catch { $stream.Dispose(); throw }
}

function Assert-IisDeploymentLockLease {
    param([string]$LeasePath, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($LeasePath) -or [string]::IsNullOrWhiteSpace($Token)) { throw 'An IIS deployment lock lease and token are required.' }
    Assert-DeploymentPathNotReparsePoint $LeasePath
    $lease = Import-Clixml -LiteralPath $LeasePath -ErrorAction Stop
    $expectedPath = [IO.Path]::GetFullPath((Join-Path (Get-IisDeploymentControlDirectory) 'configuration.lock'))
    if ($lease.Token -cne $Token -or [IO.Path]::GetFullPath([string]$lease.Path) -ine $expectedPath) { throw 'Invalid IIS deployment lock lease.' }
    try { $owner = [Diagnostics.Process]::GetProcessById([int]$lease.OwnerProcessId) }
    catch { throw 'IIS deployment lock owner is no longer alive.' }
    if ($owner.StartTime.ToUniversalTime().Ticks -ne [long]$lease.OwnerStartTimeUtcTicks) { throw 'IIS deployment lock owner process was replaced.' }
    Assert-DeploymentPathNotReparsePoint $expectedPath
    $sharingViolation = $false
    try { $probe = [IO.File]::Open($expectedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $probe.Dispose() }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        $sharingViolation = ($exception -is [IO.IOException] -and (($exception.HResult -band 0xffff) -in @(32, 33)))
        if (-not $sharingViolation) { throw 'Could not verify exclusive IIS deployment lock ownership.' }
    }
    if (-not $sharingViolation) { throw 'IIS deployment lock lease is no longer held.' }
}

function Exit-IisDeploymentLock {
    param([string]$Token)
    $registry = Get-Variable -Name NodeDeployKitIisDeploymentLocks -Scope Global -ErrorAction SilentlyContinue
    if ($registry -and $registry.Value.ContainsKey($Token)) {
        $registry.Value[$Token].Dispose()
        $registry.Value.Remove($Token)
    }
}

function Assert-IisApplicationDeploymentLockLease {
    param($Config, [string]$LeasePath, [string]$Token)
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    Assert-IisDeploymentLockLease -LeasePath $LeasePath -Token $Token
    $lease = Import-Clixml -LiteralPath $LeasePath -ErrorAction Stop
    $expected = Join-Path (Get-DeploymentLockDirectory $Config) "$($Config.AppName).lock"
    if (-not $lease.PSObject.Properties['AppName'] -or -not $lease.PSObject.Properties['AppLockPath'] -or
        [string]$lease.AppName -cne [string]$Config.AppName -or -not $lease.AppLockPath -or
        [IO.Path]::GetFullPath([string]$lease.AppLockPath) -ine [IO.Path]::GetFullPath($expected)) {
        throw 'IIS native handoff requires the protected application deployment lock lease for this AppName.'
    }
    Assert-DeploymentPathNotReparsePoint $expected
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw 'IIS application deployment lease file is missing.' }
    $probe = $null
    try { $probe = [IO.File]::Open($expected, 'Open', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        if (($exception.HResult -band 0xffff) -in @(32, 33)) { return }
        throw 'Could not verify the exclusive application deployment lease.'
    }
    finally { if ($probe) { $probe.Dispose() } }
    throw 'IIS application deployment lease is no longer held; refusing native mutation.'
}

function Start-IisInstallerTransaction {
    param($Config, [string]$LeasePath, [string]$Token, $ExistingDeploymentLock)
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    if ($LeasePath -or $Token) {
        Assert-IisApplicationDeploymentLockLease -Config $Config -LeasePath $LeasePath -Token $Token
        return [pscustomobject]@{ OwnsLock = $false; Directory = ''; Token = $Token; State = $null; WebConfigPath = ''; WebConfigExisted = $false; WebConfigSddl = $null }
    }
    $appLock = $null
    $ownsAppLock = -not $ExistingDeploymentLock
    if ($ExistingDeploymentLock) { Assert-ExistingDeploymentLock -Config $Config -Lock $ExistingDeploymentLock; $appLock = $ExistingDeploymentLock }
    else { $appLock = Enter-DeploymentLock -Config $Config }
    $directory = Join-Path (Get-IisDeploymentControlDirectory) ('installer.' + [Guid]::NewGuid().ToString('N'))
    try {
    Assert-DeploymentPathNotReparsePoint $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-ProtectedDeploymentLockDirectoryAcl $directory
    $transaction = [pscustomobject]@{ OwnsLock = $true; Directory = $directory; Token = ''; State = $null; WebConfigPath = (Join-Path $Config.IisSitePath 'web.config'); WebConfigExisted = $false; WebConfigSddl = $null; AppLock = $appLock; OwnsAppLock = $ownsAppLock; IisLockLeasePath = ''; IisLockToken = ''; NativeState = ($PSVersionTable.PSEdition -eq 'Core') }
    try {
        $lease = Enter-IisDeploymentLock -JournalDirectory $directory -AppLock $appLock
        $transaction.Token = $lease.Token
        $transaction.IisLockToken = $lease.Token; $transaction.IisLockLeasePath = $lease.LeasePath
        if ($transaction.NativeState) { Invoke-NativeIisDeploymentState -Action Save -Transaction $transaction -Config $Config }
        else { $transaction.State = Get-IisManagedDeploymentState $Config }
        Assert-DeploymentPathNotReparsePoint $transaction.WebConfigPath
        $transaction.WebConfigExisted = Test-Path -LiteralPath $transaction.WebConfigPath -PathType Leaf
        if ($transaction.WebConfigExisted) {
            Copy-Item -LiteralPath $transaction.WebConfigPath -Destination (Join-Path $directory 'web.config.before') -ErrorAction Stop
            $transaction.WebConfigSddl = (Get-Acl -LiteralPath $transaction.WebConfigPath -ErrorAction Stop).Sddl
        }
        $transaction | Export-Clixml -LiteralPath (Join-Path $directory 'installer-state.xml') -Depth 40
        return $transaction
    } catch { Exit-IisDeploymentLock $transaction.Token; Remove-IisInstallerJournal $directory; throw }
    } catch { if ($ownsAppLock) { Exit-DeploymentLock $appLock }; throw }
}

function Remove-IisInstallerJournal([string]$Directory) {
    $target = [IO.Path]::GetFullPath($Directory)
    $parent = [IO.Path]::GetFullPath((Get-IisDeploymentControlDirectory)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $target) -notlike 'installer.*') { throw 'Refusing IIS journal cleanup outside the protected deployment directory.' }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
}

function Complete-IisInstallerTransaction {
    param($Transaction, [switch]$Failed)
    if (-not $Transaction -or -not $Transaction.OwnsLock) { return }
    $recovered = $false
    try {
        if ($Failed) {
            Assert-DeploymentPathNotReparsePoint $Transaction.WebConfigPath
            if ($Transaction.WebConfigExisted) {
                Copy-Item -LiteralPath (Join-Path $Transaction.Directory 'web.config.before') -Destination $Transaction.WebConfigPath -Force -ErrorAction Stop
                Restore-WindowsFileSecurity -Path $Transaction.WebConfigPath -Sddl $Transaction.WebConfigSddl
            } elseif (Test-Path -LiteralPath $Transaction.WebConfigPath -PathType Leaf) { Remove-Item -LiteralPath $Transaction.WebConfigPath -Force -ErrorAction Stop }
            if ($Transaction.NativeState) { Invoke-NativeIisDeploymentState -Action Restore -Transaction $Transaction -Config $null }
            else { Restore-IisManagedDeploymentState $Transaction.State }
        }
        $recovered = $true
    } catch { throw "IIS installer recovery failed; protected journal retained at $($Transaction.Directory). $($_.Exception.Message)" }
    finally {
        Exit-IisDeploymentLock $Transaction.Token
        try { if ($recovered) { Remove-IisInstallerJournal $Transaction.Directory } }
        finally { if ($Transaction.OwnsAppLock) { Exit-DeploymentLock $Transaction.AppLock } }
    }
}

function Get-IisStateConfigValue($Config, [string]$Name, $Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) { return $Config.$Name }
    return $Default
}

function Get-IisStateConfigBool($Config, [string]$Name, [bool]$Default) {
    if (-not $Config.PSObject.Properties[$Name]) { return $Default }
    if ($Config.$Name -is [bool]) { return [bool]$Config.$Name }
    switch -Regex ([string]$Config.$Name) { '^(true|1|yes)$' { return $true }; '^(false|0|no)$' { return $false }; default { return $Default } }
}

function Get-IisConfigurationValue([string]$Filter, [string]$Name) {
    $property = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $Filter -Name $Name -ErrorAction Stop
    if ($null -eq $property) { throw "IIS configuration property is unavailable: $Filter / $Name" }
    if ($property.PSObject.Properties['Value']) { return $property.Value }
    return $property
}

function Get-IisManagedDeploymentState($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    Import-Module WebAdministration -ErrorAction Stop
    $siteName = [string](Get-IisStateConfigValue $Config 'IisSiteName' $Config.AppName)
    $poolName = [string](Get-IisStateConfigValue $Config 'IisAppPoolName' "$($Config.AppName)-AppPool")
    $site = if (Test-Path "IIS:\Sites\$siteName") { Get-Item "IIS:\Sites\$siteName" -ErrorAction Stop } else { $null }
    $pool = if (Test-Path "IIS:\AppPools\$poolName") { Get-Item "IIS:\AppPools\$poolName" -ErrorAction Stop } else { $null }
    $bindings = @()
    if ($site) {
        foreach ($binding in @($site.Bindings.Collection)) {
            $hash = if ($binding.certificateHash -is [byte[]]) { [BitConverter]::ToString($binding.certificateHash).Replace('-', '') } else { [string]$binding.certificateHash }
            $bindings += [pscustomobject]@{ Protocol = [string]$binding.protocol; Information = [string]$binding.bindingInformation; SslFlags = [int]$binding.sslFlags; Hash = $hash; Store = [string]$binding.certificateStoreName }
        }
    }
    $poolProperties = @{}
    if ($pool) {
        foreach ($name in @('managedRuntimeVersion', 'startMode', 'processModel.idleTimeout', 'recycling.periodicRestart.time')) {
            $value = Get-ItemProperty "IIS:\AppPools\$poolName" -Name $name -ErrorAction Stop
            $poolProperties[$name] = if ($value.PSObject.Properties['Value']) { $value.Value } else { $value }
        }
    }
    $proxyProperties = @{}; $variables = @{}
    $isStatic = ([string](Get-IisStateConfigValue $Config 'DeploymentMode' '')).Replace('_', '-').ToLowerInvariant() -eq 'static-iis'
    if (-not $isStatic) {
        if (Get-IisStateConfigBool $Config 'IisEnableArrProxy' $true) {
            foreach ($name in @('enabled', 'preserveHostHeader', 'reverseRewriteHostInResponseHeaders', 'timeout')) { $proxyProperties[$name] = Get-IisConfigurationValue 'system.webServer/proxy' $name }
        }
        if (Get-IisStateConfigBool $Config 'IisSetForwardedHeaders' $true) {
            foreach ($name in @('HTTP_X_FORWARDED_HOST', 'HTTP_X_FORWARDED_PROTO', 'HTTP_X_FORWARDED_PORT', 'HTTP_X_FORWARDED_FOR')) {
                $collection = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "system.webServer/rewrite/allowedServerVariables/add[@name='$name']" -ErrorAction Stop)
                $variables[$name] = ($collection.Count -gt 0)
            }
        }
    }
    $ssl = $null
    if (Get-IisStateConfigBool $Config 'TlsEnabled' $false) {
        $hostHeader = [string](Get-IisStateConfigValue $Config 'PublicHostName' '')
        $port = [int](Get-IisStateConfigValue $Config 'PublicPort' 443)
        $sslPath = if ($hostHeader) { "IIS:\SslBindings\0.0.0.0!$port!$hostHeader" } else { "IIS:\SslBindings\0.0.0.0!$port" }
        $entry = if (Test-Path $sslPath) { Get-Item $sslPath -ErrorAction Stop } else { $null }
        $ssl = [pscustomobject]@{ Path = $sslPath; Existed = ($null -ne $entry); Thumbprint = if ($entry) { [string]$entry.Thumbprint } else { '' }; Store = if ($entry -and $entry.PSObject.Properties['Store']) { [string]$entry.Store } else { 'My' }; Flags = if ($entry -and $entry.PSObject.Properties['SslFlags']) { [int]$entry.SslFlags } elseif ($hostHeader) { 1 } else { 0 } }
    }
    return [pscustomobject]@{
        SiteName = $siteName; SiteExisted = ($null -ne $site); PhysicalPath = if ($site) { [string]$site.PhysicalPath } else { '' }
        ApplicationPool = if ($site) { [string]$site.ApplicationPool } else { '' }; SiteState = if ($site) { [string]$site.State } else { '' }; Bindings = $bindings
        PoolName = $poolName; PoolExisted = ($null -ne $pool); PoolState = if ($pool) { [string]$pool.State } else { '' }; PoolProperties = $poolProperties
        ProxyProperties = $proxyProperties; Variables = $variables; Ssl = $ssl
    }
}

function Restore-IisManagedDeploymentState($State) {
    Import-Module WebAdministration -ErrorAction Stop
    $sitePath = "IIS:\Sites\$($State.SiteName)"
    if ($State.SiteExisted) {
        if (-not (Test-Path $sitePath)) { throw 'Previous IIS site disappeared; recovery journal is retained.' }
        Stop-Website -Name $State.SiteName -ErrorAction Stop | Out-Null
        Set-ItemProperty $sitePath -Name physicalPath -Value $State.PhysicalPath -ErrorAction Stop
        Set-ItemProperty $sitePath -Name applicationPool -Value $State.ApplicationPool -ErrorAction Stop
        foreach ($binding in @(Get-WebBinding -Name $State.SiteName -ErrorAction Stop)) {
            if (@($State.Bindings | Where-Object { $_.Protocol -eq [string]$binding.protocol -and $_.Information -ieq [string]$binding.bindingInformation }).Count -eq 0) {
                if ([string]$binding.bindingInformation -notmatch '^(?<ip>.*):(?<port>[0-9]+):(?<host>[^:]*)$') { throw 'Invalid IIS binding during rollback.' }
                Remove-WebBinding -Name $State.SiteName -Protocol ([string]$binding.protocol) -IPAddress $Matches.ip -Port ([int]$Matches.port) -HostHeader $Matches.host -ErrorAction Stop
            }
        }
        foreach ($binding in @($State.Bindings)) {
            $current = @(Get-WebBinding -Name $State.SiteName -Protocol $binding.Protocol -ErrorAction Stop | Where-Object { [string]$_.bindingInformation -ieq $binding.Information })
            if ($current.Count -eq 0) {
                if ($binding.Information -notmatch '^(?<ip>.*):(?<port>[0-9]+):(?<host>[^:]*)$') { throw 'Invalid saved IIS binding.' }
                $arguments = @{ Name = $State.SiteName; Protocol = $binding.Protocol; IPAddress = $Matches.ip; Port = [int]$Matches.port; HostHeader = $Matches.host; ErrorAction = 'Stop' }
                if ($binding.Protocol -eq 'https') { $arguments.SslFlags = $binding.SslFlags }
                New-WebBinding @arguments | Out-Null
                $current = @(Get-WebBinding -Name $State.SiteName -Protocol $binding.Protocol -ErrorAction Stop | Where-Object { [string]$_.bindingInformation -ieq $binding.Information })
            }
            if ($current.Count -ne 1) { throw 'Could not restore a saved IIS binding.' }
            if ($binding.Protocol -eq 'https') {
                Set-WebBinding -Name $State.SiteName -BindingInformation $binding.Information -PropertyName sslFlags -Value $binding.SslFlags -ErrorAction Stop
                if ($binding.Hash) { $current[0].AddSslCertificate($binding.Hash, $binding.Store) }
            }
        }
    } elseif (Test-Path $sitePath) { Remove-Website -Name $State.SiteName -ErrorAction Stop }
    $poolPath = "IIS:\AppPools\$($State.PoolName)"
    if ($State.PoolExisted) {
        if (-not (Test-Path $poolPath)) { throw 'Previous IIS application pool disappeared.' }
        foreach ($name in $State.PoolProperties.Keys) { Set-ItemProperty $poolPath -Name $name -Value $State.PoolProperties[$name] -ErrorAction Stop }
        if ($State.PoolState -eq 'Stopped') { Stop-WebAppPool -Name $State.PoolName -ErrorAction Stop | Out-Null }
        elseif ($State.PoolState -eq 'Started') { Start-WebAppPool -Name $State.PoolName -ErrorAction Stop | Out-Null }
    } elseif (Test-Path $poolPath) { Remove-WebAppPool -Name $State.PoolName -ErrorAction Stop }
    if ($State.Ssl) {
        $ssl = $State.Ssl
        if (-not $ssl.Existed -and (Test-Path $ssl.Path)) { Remove-Item $ssl.Path -Force -ErrorAction Stop }
        elseif ($ssl.Existed -and -not (Test-Path $ssl.Path)) {
            Get-Item "Cert:\LocalMachine\$($ssl.Store)\$($ssl.Thumbprint)" -ErrorAction Stop | New-Item $ssl.Path -SSLFlags $ssl.Flags -ErrorAction Stop | Out-Null
        }
    }
    foreach ($name in $State.ProxyProperties.Keys) { Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name $name -Value $State.ProxyProperties[$name] -ErrorAction Stop }
    foreach ($name in $State.Variables.Keys) {
        $existing = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "system.webServer/rewrite/allowedServerVariables/add[@name='$name']" -ErrorAction Stop)
        if ($State.Variables[$name] -and $existing.Count -eq 0) { Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{ name = $name } -ErrorAction Stop | Out-Null }
        elseif (-not $State.Variables[$name] -and $existing.Count -gt 0) { Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -AtElement @{ name = $name } -ErrorAction Stop }
    }
    if ($State.SiteExisted -and $State.SiteState -eq 'Started') { Start-Website -Name $State.SiteName -ErrorAction Stop | Out-Null }
}

function Invoke-NativeIisDeploymentState {
    param([ValidateSet('Save', 'Restore')][string]$Action, $Transaction, $Config)
    Assert-IisDeploymentLockLease $Transaction.IisLockLeasePath $Transaction.IisLockToken
    $configPath = Join-Path $Transaction.Directory 'iis-config.xml'
    if ($Action -eq 'Save') { $Config | Export-Clixml -LiteralPath $configPath -Depth 40 }
    $leasedConfig = if ($Config) { $Config } else { Import-Clixml -LiteralPath $configPath -ErrorAction Stop }
    Assert-IisApplicationDeploymentLockLease -Config $leasedConfig -LeasePath $Transaction.IisLockLeasePath -Token $Transaction.IisLockToken
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Invoke-IisDeploymentState.ps1'), '-Action', $Action,
        '-ConfigSnapshotPath', $configPath, '-StatePath', (Join-Path $Transaction.Directory 'iis-state.xml'), '-IisDeploymentLockLeasePath', $Transaction.IisLockLeasePath, '-IisDeploymentLockToken', $Transaction.IisLockToken)
    $native = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $savedModulePath = $env:PSModulePath
    try {
        Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue
        & $native @arguments
    } finally { $env:PSModulePath = $savedModulePath }
    if ($LASTEXITCODE -ne 0) { throw "Native IIS deployment state $Action failed; recovery journal is retained." }
}
