[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$fixtureRoot = Join-Path $repoRoot (".tmp\windows-production-safety-" + [Guid]::NewGuid().ToString("N"))
. (Join-Path $repoRoot 'scripts/windows/WindowsDeploymentIdentity.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if (-not $caught) { throw "Expected failure: $Expected" }
    if ($Expected -and $caught.Exception.Message -notlike "*$Expected*") {
        throw "Unexpected failure: $($caught.Exception.Message); expected: $Expected. At: $($caught.ScriptStackTrace)"
    }
}
function Get-SourceAst([string]$RelativePath) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $RelativePath), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell parse failed for $RelativePath : $($parseErrors[0].Message)" }
    return $ast
}
function Import-SourceFunctions([string]$RelativePath) {
    $ast = Get-SourceAst $RelativePath
    foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        Invoke-Expression $definition.Extent.Text
    }
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    & {
        Write-Host 'Windows app-name aliases fail before private paths, runtime calls, and generated file writes'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        . Import-SourceFunctions 'scripts/windows/IisDeploymentState.ps1'
        . Import-SourceFunctions 'scripts/windows/Deploy-LatestRelease.ps1'
        . Import-SourceFunctions 'scripts/windows/Import-AppPackage.ps1'
        . Import-SourceFunctions 'scripts/windows/Uninstall-NodeService.ps1'
        $aliasRoot = Join-Path $fixtureRoot 'app-name-alias-guard'
        $aliasFile = Join-Path $aliasRoot 'private-generated.json'
        $aliasInputFile = Join-Path $fixtureRoot 'alias-entry.config.json'
        $aliasEntryPrefixes = @()
        foreach ($entryContract in @(
            @{ Path = 'scripts/windows/Install-NSSMService.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' },
            @{ Path = 'scripts/windows/Install-IISStaticSite.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' },
            @{ Path = 'scripts/windows/Install-IISReverseProxy.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' },
            @{ Path = 'scripts/windows/Install-ReverseProxy.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' },
            @{ Path = 'scripts/windows/Deploy-LatestRelease.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' },
            @{ Path = 'scripts/windows/Import-AppPackage.ps1'; Guard = 'Initialize-AppPackageImportConfig' },
            @{ Path = 'scripts/windows/Uninstall-NodeService.ps1'; Guard = 'Assert-WindowsDeploymentConfigIdentity' }
        )) {
            $entryStatements = (Get-SourceAst $entryContract.Path).EndBlock.Statements
            $loadIndex = -1; $guardIndex = -1
            for ($entryIndex = 0; $entryIndex -lt $entryStatements.Count; $entryIndex++) {
                $statement = $entryStatements[$entryIndex]
                if ($loadIndex -lt 0 -and $statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Extent.Text -match '^\$(?:baseConfig|config) = Get-Content') { $loadIndex = $entryIndex; continue }
                if ($loadIndex -ge 0 -and $statement -is [Management.Automation.Language.PipelineAst] -and $statement.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and $statement.PipelineElements[0].GetCommandName() -eq $entryContract.Guard) { $guardIndex = $entryIndex; break }
            }
            Assert-True ($loadIndex -ge 0 -and $guardIndex -gt $loadIndex -and $guardIndex -le ($loadIndex + 2)) "App-name guard did not immediately follow configuration load in $($entryContract.Path)."
            if ($guardIndex -eq ($loadIndex + 2)) { Assert-True ($entryStatements[$loadIndex + 1].Extent.Text.Contains('WindowsDeploymentIdentity.ps1')) 'An app-specific operation preceded entrypoint identity validation.' }
            $aliasEntryPrefixes += ($entryStatements[$loadIndex].Extent.Text + "`n" + $entryStatements[$guardIndex].Extent.Text)
        }
        $script:aliasHostActions = [System.Collections.Generic.List[string]]::new()
        function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) $script:aliasHostActions.Add('cim'); throw 'Alias reached a runtime query.' }
        function Get-WindowsPm2RuntimeContext { param($Config) $script:aliasHostActions.Add('pm2'); throw 'Alias reached PM2 context discovery.' }
        function Assert-IisDeploymentLockLease { param($LeasePath, $Token) $script:aliasHostActions.Add('iis-lease'); throw 'Alias reached IIS lease probing.' }
        function Assert-WindowsServiceSecurityNoReparse { param($Path) $script:aliasHostActions.Add('filesystem'); throw 'Alias reached filesystem mutation prevalidation.' }
        foreach ($aliasName in @('Foo.', 'Foo..', 'CON', 'con.config', 'PRN.log', 'AUX', 'NUL.json', 'COM1', 'cOm9.release', 'LPT1', 'lPt9.backup')) {
            $aliasConfig = [pscustomobject]@{ AppName = $aliasName; ServiceManager = 'winsw'; ServiceDirectory = $aliasRoot }
            [IO.File]::WriteAllText($aliasInputFile, ($aliasConfig | ConvertTo-Json))
            $ConfigPath = $aliasInputFile
            foreach ($entryPrefix in $aliasEntryPrefixes) { Assert-Throws { Invoke-Expression $entryPrefix } 'AppName' }
            foreach ($action in @(
                { Get-HealthTaskDirectory $aliasConfig },
                { Get-ManagedHealthMonitorConfigPath $aliasConfig },
                { Get-ServiceXmlPath $aliasConfig },
                { Get-DefaultGeneratedConfigPath $aliasConfig },
                { Write-GeneratedConfig -Config $aliasConfig -Path $aliasFile },
                { Initialize-AppPackageImportConfig $aliasConfig },
                { Assert-ManagedDeploymentManagerTransition $aliasConfig },
                { Start-ManagedDeploymentTransaction -Config $aliasConfig -Lock $null -SkipHostState },
                { Start-IisInstallerTransaction -Config $aliasConfig -LeasePath 'untrusted lease' -Token 'untrusted token' },
                { Remove-ManagedNativeWindowsService $aliasConfig },
                { Uninstall-Pm2Process $aliasConfig }
            )) { Assert-Throws $action 'AppName' }
            Assert-True ($script:aliasHostActions.Count -eq 0 -and -not (Test-Path -LiteralPath $aliasRoot)) "Unsafe alias '$aliasName' reached host calls or created private files before rejection."
        }
        foreach ($validName in @('Foo', 'Foo.Bar', 'CON-App', 'COM10', 'App_1-Blue', 'all', '123')) {
            Assert-WindowsDeploymentAppName -AppName $validName
            $validConfig = [pscustomobject]@{ AppName = $validName; ServiceDirectory = $aliasRoot }
            Assert-True ((Split-Path -Leaf (Get-HealthTaskDirectory $validConfig)) -ceq $validName) 'A valid app name was changed while constructing its private task path.'
            Assert-True ((Get-ServiceXmlPath $validConfig) -eq (Join-Path $aliasRoot "$validName.xml")) 'A valid app name was changed while constructing its service XML path.'
        }
    }
    Write-Host "Static IIS backup failure and replacement rollback"
    . Import-SourceFunctions "scripts/windows/Install-IISStaticSite.ps1"
    $staticAst = Get-SourceAst "scripts/windows/Install-IISStaticSite.ps1"
    $script:staticTransaction = @($staticAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('"Transactionally deploy static_iis output and configure IIS"')
    }, $false))[0].Extent.Text
    function Get-StaticIisDeploymentSnapshot { return [pscustomobject]@{ SiteExisted = $true; SiteState = "Started" } }
    function Stop-StaticIisSiteForDeployment { }
    function Restore-StaticIisDeploymentSnapshot { $script:staticSnapshotRestored = $true }
    function Ensure-StaticAppPool { throw "mock app-pool failure after content replacement" }
    function Invoke-StaticFixture {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param([string]$sitePath, [string]$sourcePath, [string]$backupDirectory)
        $siteName = "FixtureSite"; $appPoolName = "FixturePool"; $protocol = "http"
        $publicPort = 80; $publicHostName = "fixture.example"; $tlsEnabled = $false
        $spaShellFile = "_shell.html"; $allowRewrite = $false
        Invoke-Expression $script:staticTransaction
    }
    $site = Join-Path $fixtureRoot "live-site"
    $source = Join-Path $fixtureRoot "static-source"
    New-Item -ItemType Directory -Path $site, $source -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $site "original.txt") -Value "original production bytes"
    Set-Content -LiteralPath (Join-Path $source "_shell.html") -Value "new release shell"
    $originalHash = (Get-FileHash -LiteralPath (Join-Path $site "original.txt")).Hash
    $blockedBackup = Join-Path $fixtureRoot "backup-path-is-file"
    Set-Content -LiteralPath $blockedBackup -Value "not a directory"
    $script:staticSnapshotRestored = $false
    Assert-Throws { Invoke-StaticFixture -sitePath $site -sourcePath $source -backupDirectory $blockedBackup } ""
    Assert-True (Test-Path -LiteralPath (Join-Path $site "original.txt")) "Backup failure deleted the original static site."
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $site "original.txt")).Hash -eq $originalHash) "Backup failure changed original static site bytes."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $site "_shell.html"))) "Backup failure started content replacement."
    Assert-True $script:staticSnapshotRestored "Backup failure did not restore the IIS state snapshot."
    $backups = Join-Path $fixtureRoot "static-backups"
    Assert-Throws { Invoke-StaticFixture -sitePath $site -sourcePath $source -backupDirectory $backups } "mock app-pool failure"
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $site "original.txt")).Hash -eq $originalHash) "Failed replacement did not restore original bytes."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $site "_shell.html"))) "Failed replacement retained new release files."
    Assert-Throws { Restore-StaticSiteContent -SitePath $site -BackupPath (Join-Path $fixtureRoot "missing-backup") -SitePathExisted $true } "backup directory is missing"
    Assert-True (Test-Path -LiteralPath (Join-Path $site "original.txt")) "Missing backup caused destructive restore."

    Write-Host "IIS binding isolation, SNI/certificate recovery, and partial takeover failure"
    . Import-SourceFunctions "scripts/windows/Deploy-LatestRelease.ps1"
    $script:iisSites = [System.Collections.Generic.List[object]]::new()
    function New-MockBinding([string]$Information, [string]$Protocol = "https", [int]$Flags = 1, [string]$Hash = "ABCD") {
        $binding = [pscustomobject]@{ bindingInformation = $Information; protocol = $Protocol; sslFlags = $Flags; certificateHash = $Hash; certificateStoreName = "My" }
        $binding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value { param($Hash, $Store) $this.certificateHash = $Hash; $this.certificateStoreName = $Store }
        return $binding
    }
    function Add-MockSite([string]$Name, [object[]]$Bindings) {
        $collection = [System.Collections.Generic.List[object]]::new()
        foreach ($binding in $Bindings) { $collection.Add($binding) }
        $script:iisSites.Add([pscustomobject]@{ Name = $Name; Bindings = [pscustomobject]@{ Collection = $collection } })
    }
    function Import-Module { }
    function Get-ChildItem { [CmdletBinding()] param([string]$Path) return $script:iisSites.ToArray() }
    function Get-WebBinding { [CmdletBinding()] param([string]$Name, [string]$Protocol) $record = @($script:iisSites | Where-Object { $_.Name -eq $Name }); if ($record.Count) { return @($record[0].Bindings.Collection | Where-Object { -not $Protocol -or $_.protocol -eq $Protocol }) } }
    function Remove-WebBinding {
        [CmdletBinding()]
        param([string]$Name, [string]$Protocol, [string]$IPAddress, [int]$Port, [string]$HostHeader)
        $information = "${IPAddress}:${Port}:$HostHeader"
        $record = @($script:iisSites | Where-Object { $_.Name -eq $Name })[0]
        foreach ($binding in @($record.Bindings.Collection.ToArray())) {
            if ($binding.protocol -eq $Protocol -and $binding.bindingInformation -ieq $information) { [void]$record.Bindings.Collection.Remove($binding) }
        }
        if ($Name -eq $script:bindingFailureSite) { throw "mock failure after removing a binding" }
    }
    function New-WebBinding {
        [CmdletBinding()]
        param([string]$Name, [string]$Protocol, [string]$IPAddress, [int]$Port, [string]$HostHeader, [int]$SslFlags = 0)
        $record = @($script:iisSites | Where-Object { $_.Name -eq $Name })[0]
        $record.Bindings.Collection.Add((New-MockBinding "${IPAddress}:${Port}:$HostHeader" $Protocol $SslFlags ""))
    }
    function Set-WebBinding {
        [CmdletBinding()]
        param([string]$Name, [string]$BindingInformation, [string]$PropertyName, $Value)
        $record = @($script:iisSites | Where-Object { $_.Name -eq $Name })[0]
        @($record.Bindings.Collection | Where-Object { $_.bindingInformation -ieq $BindingInformation })[0].$PropertyName = $Value
    }
    $script:bindingFailureSite = ""
    Add-MockSite "PreviousSite" @((New-MockBinding "*:443:app.example" "https" 3 "01234567"))
    Add-MockSite "OtherHost" @((New-MockBinding "*:443:other.example"))
    Add-MockSite "OtherIp" @((New-MockBinding "192.0.2.10:443:app.example"))
    Add-MockSite "OtherProtocol" @((New-MockBinding "*:443:app.example" "http" 0 ""))
    Add-MockSite "OtherPort" @((New-MockBinding "*:8443:app.example"))
    $bindingConfig = [pscustomobject]@{ AppName = "TargetSite"; IisSiteName = "TargetSite"; PublicHostName = "app.example"; PublicPort = 443; TlsEnabled = $true }
    $conflicts = @(Get-ExistingPublicPortBindings $bindingConfig)
    Assert-True ($conflicts.Count -eq 1 -and $conflicts[0].SiteName -eq "PreviousSite") "Takeover matched an unrelated IIS host, IP, port, or protocol."
    $removed = [System.Collections.Generic.List[object]]::new()
    Remove-ConflictingPublicPortBindings -Config $bindingConfig -RemovedBindings $removed
    Assert-True (@(Get-WebBinding -Name "PreviousSite" -Protocol "https").Count -eq 0) "Exact conflicting IIS binding was not removed."
    Assert-True (@(Get-WebBinding -Name "OtherHost" -Protocol "https").Count -eq 1) "Takeover removed an unrelated host header."
    Restore-RemovedPublicPortBindings -RemovedBindings $removed
    $restored = @(Get-WebBinding -Name "PreviousSite" -Protocol "https")[0]
    Assert-True ($restored.sslFlags -eq 3 -and $restored.certificateHash -eq "01234567" -and $restored.certificateStoreName -eq "My") "Binding rollback lost SNI flags or certificate identity."
    Add-MockSite "FailingPreviousSite" @((New-MockBinding "*:443:app.example" "https" 1 "76543210"))
    $script:bindingFailureSite = "FailingPreviousSite"
    $partialRemoved = [System.Collections.Generic.List[object]]::new()
    Assert-Throws { Remove-ConflictingPublicPortBindings -Config $bindingConfig -RemovedBindings $partialRemoved } "mock failure after removing"
    Assert-True ($partialRemoved.Count -eq 2) "Partial takeover did not retain all rollback records."
    $script:bindingFailureSite = ""
    Restore-RemovedPublicPortBindings -RemovedBindings $partialRemoved
    Assert-True (@(Get-WebBinding -Name "PreviousSite" -Protocol "https").Count -eq 1) "Partial takeover failed to restore the first binding."
    Assert-True (@(Get-WebBinding -Name "FailingPreviousSite" -Protocol "https").Count -eq 1) "Partial takeover failed to restore a partially removed binding."
    $ipv6 = ConvertFrom-IisPublicBindingInformation "[::1]:443:app.example"
    Assert-True ($ipv6.IPAddress -eq "[::1]" -and $ipv6.Port -eq 443 -and $ipv6.HostHeader -eq "app.example") "IPv6 binding parsing lost the address."
    Remove-Item Function:\Get-ChildItem
    & {
        Write-Host 'Scoped IIS site, application-pool, ARR, and forwarded-variable rollback'
        . Import-SourceFunctions 'scripts/windows/IisDeploymentState.ps1'
        Add-MockSite 'IisStateFixture' @((New-MockBinding '*:443:state.example' 'https' 3 '11223344'))
        $script:stateSite = @($script:iisSites | Where-Object { $_.Name -eq 'IisStateFixture' })[0]
        $script:stateSite | Add-Member NoteProperty PhysicalPath 'previous-site-path'
        $script:stateSite | Add-Member NoteProperty ApplicationPool 'previous-pool'
        $script:stateSite | Add-Member NoteProperty State 'Started'
        $script:statePool = [pscustomobject]@{ State = 'Stopped' }
        $script:poolSettings = @{ managedRuntimeVersion = 'v4.0'; startMode = 'OnDemand'; 'processModel.idleTimeout' = [TimeSpan]::FromMinutes(20); 'recycling.periodicRestart.time' = [TimeSpan]::FromHours(29) }
        $script:proxySettings = @{ enabled = $false; preserveHostHeader = $false; reverseRewriteHostInResponseHeaders = $true; timeout = [TimeSpan]::FromSeconds(100); unrelatedProperty = 'unmanaged-value' }
        $script:allowedVariables = @{ HTTP_X_FORWARDED_HOST = $true; HTTP_X_FORWARDED_PROTO = $false; HTTP_X_FORWARDED_PORT = $false; HTTP_X_FORWARDED_FOR = $true; UNRELATED_VARIABLE = $true }
        function Test-Path { param([string]$Path) if ($Path -like 'IIS:\Sites\*') { return ($null -ne $script:stateSite) }; if ($Path -like 'IIS:\AppPools\*') { return ($null -ne $script:statePool) }; throw 'Unexpected fixture IIS path.' }
        function Get-Item { [CmdletBinding()] param([string]$Path) if ($Path -like 'IIS:\Sites\*') { return $script:stateSite }; if ($Path -like 'IIS:\AppPools\*') { return $script:statePool }; throw 'Unexpected fixture IIS item.' }
        function Get-ItemProperty { [CmdletBinding()] param($Path, $Name) return [pscustomobject]@{ Value = $script:poolSettings[$Name] } }
        function Set-ItemProperty { [CmdletBinding()] param($Path, $Name, $Value) if ($Path -like 'IIS:\Sites\*') { $script:stateSite.$Name = $Value } else { $script:poolSettings[$Name] = $Value } }
        function Get-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name) return [pscustomobject]@{ Value = $script:proxySettings[$Name] } }
        function Set-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name, $Value) $script:proxySettings[$Name] = $Value }
        function Get-WebConfiguration { [CmdletBinding()] param($PSPath, [string]$Filter) if ($Filter -notmatch "@name='([^']+)'") { throw 'Unexpected fixture rewrite filter.' }; if ($script:allowedVariables[$Matches[1]]) { return [pscustomobject]@{ name = $Matches[1] } } }
        function Add-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name, $Value) $script:allowedVariables[$Value.name] = $true }
        function Remove-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name, $AtElement) $script:allowedVariables[$AtElement.name] = $false }
        function Stop-Website { [CmdletBinding()] param($Name) $script:stateSite.State = 'Stopped' }
        function Start-Website { [CmdletBinding()] param($Name) $script:stateSite.State = 'Started' }
        function Stop-WebAppPool { [CmdletBinding()] param($Name) $script:statePool.State = 'Stopped' }
        function Start-WebAppPool { [CmdletBinding()] param($Name) $script:statePool.State = 'Started' }
        $iisStateConfig = [pscustomobject]@{ AppName = 'IisStateFixture'; IisSiteName = 'IisStateFixture'; IisAppPoolName = 'IisStateFixture-AppPool'; TlsEnabled = $false }
        $savedIisState = Get-IisManagedDeploymentState $iisStateConfig
        $script:stateSite.PhysicalPath = 'new-site-path'; $script:stateSite.ApplicationPool = 'new-pool'; $script:stateSite.State = 'Stopped'
        $script:poolSettings['managedRuntimeVersion'] = ''; $script:poolSettings['startMode'] = 'AlwaysRunning'; $script:poolSettings['processModel.idleTimeout'] = [TimeSpan]::Zero
        $script:proxySettings.enabled = $true; $script:proxySettings.preserveHostHeader = $true; $script:proxySettings.reverseRewriteHostInResponseHeaders = $false; $script:proxySettings.timeout = [TimeSpan]::FromSeconds(300)
        $script:allowedVariables.HTTP_X_FORWARDED_PROTO = $true; $script:allowedVariables.HTTP_X_FORWARDED_PORT = $true
        New-WebBinding -Name 'IisStateFixture' -Protocol 'http' -IPAddress '*' -Port 80 -HostHeader 'new.example'
        @(Get-WebBinding 'IisStateFixture' 'https')[0].sslFlags = 1
        @(Get-WebBinding 'IisStateFixture' 'https')[0].certificateHash = '55667788'
        Restore-IisManagedDeploymentState $savedIisState
        Assert-True ($script:stateSite.PhysicalPath -eq 'previous-site-path' -and $script:stateSite.ApplicationPool -eq 'previous-pool' -and $script:stateSite.State -eq 'Started') 'IIS rollback lost site path, application-pool association, or running state.'
        Assert-True ($script:poolSettings.managedRuntimeVersion -eq 'v4.0' -and $script:poolSettings.startMode -eq 'OnDemand' -and $script:poolSettings['processModel.idleTimeout'].TotalMinutes -eq 20 -and $script:statePool.State -eq 'Stopped') 'IIS rollback lost managed application-pool settings/state.'
        Assert-True (@(Get-WebBinding 'IisStateFixture' '').Count -eq 1 -and @(Get-WebBinding 'IisStateFixture' 'https')[0].sslFlags -eq 3 -and @(Get-WebBinding 'IisStateFixture' 'https')[0].certificateHash -eq '11223344') 'IIS rollback retained new bindings or lost original SNI/certificate.'
        Assert-True (-not $script:proxySettings.enabled -and -not $script:proxySettings.preserveHostHeader -and $script:proxySettings.reverseRewriteHostInResponseHeaders -and $script:proxySettings.timeout.TotalSeconds -eq 100) 'IIS rollback lost one of the managed ARR properties.'
        Assert-True (-not $script:allowedVariables.HTTP_X_FORWARDED_PROTO -and -not $script:allowedVariables.HTTP_X_FORWARDED_PORT -and $script:allowedVariables.HTTP_X_FORWARDED_HOST -and $script:allowedVariables.HTTP_X_FORWARDED_FOR -and $script:allowedVariables.UNRELATED_VARIABLE -and $script:proxySettings.unrelatedProperty -eq 'unmanaged-value') 'IIS rollback changed unrelated global configuration or lost prior allowed variables.'
    }

    Write-Host "Required ARR/header failures and native PowerShell dry-run forwarding"
    . Import-SourceFunctions "scripts/windows/Install-IISReverseProxy.ps1"
    Add-MockSite 'SniSecurityFlagsFixture' @((New-MockBinding '*:443:flags.example' 'https' 8 'AABBCCDD'))
    Ensure-WebBinding -SiteName 'SniSecurityFlagsFixture' -Protocol 'https' -Port 443 -HostHeader 'flags.example'
    Assert-True (@(Get-WebBinding 'SniSecurityFlagsFixture' 'https')[0].sslFlags -eq 9) 'Enabling SNI discarded other existing TLS binding security flags.'
    Ensure-WebBinding -SiteName 'SniSecurityFlagsFixture' -Protocol 'https' -Port 443 -HostHeader 'flags.example'
    Assert-True (@(Get-WebBinding 'SniSecurityFlagsFixture' 'https')[0].sslFlags -eq 9) 'Repeated IIS configuration lost existing TLS security flags.'
    function Set-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name, $Value) throw "mock denied required IIS property" }
    function Get-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name) return $null }
    function Add-WebConfigurationProperty { [CmdletBinding()] param($PSPath, $Filter, $Name, $Value) throw "mock denied required rewrite variable" }
    function Get-WebGlobalModule { [CmdletBinding()] param($Name) return $null }
    Assert-Throws { Set-IisProxyProperty "enabled" "True" } "required IIS ARR proxy property"
    Assert-Throws { Ensure-UrlRewriteServerVariable "HTTP_X_FORWARDED_PROTO" } "required URL Rewrite server variable"
    Assert-Throws { Ensure-ArrProxySettings 300 } "ARR module was not detected"
    $nativeArguments = @(Get-IisNativePowerShellArguments -ScriptPath "C:\fixture path\installer.ps1" -ConfigPath "C:\fixture path\config.json" -WhatIf)
    Assert-True ($nativeArguments -contains "-WhatIf") "Core IIS relaunch discarded WhatIf."
    Assert-True ($nativeArguments -contains "C:\fixture path\config.json") "Core relaunch did not preserve config paths with spaces."
    $latestArguments = @(Get-LatestReleaseNativePowerShellArguments -ScriptPath "C:\fixture path\latest.ps1" -BoundParameters @{ ConfigPath = "C:\fixture path\config.json"; TakeOverPublicPortBinding = [switch]$true } -WhatIf)
    Assert-True ($latestArguments -contains "-WhatIf" -and $latestArguments -contains "-TakeOverPublicPortBinding:True") "Latest-release native relaunch lost dry-run or takeover flags."
    Assert-True (-not (Get-ConfigBool ([pscustomobject]@{ TlsEnabled = "false" }) "TlsEnabled" $true)) "IIS installer interpreted false text as enabled TLS."
    & {
        $script:emptyConfigProtected = $false
        function Assert-WindowsServiceSecurityNoReparse { param($Path) }
        function Set-WindowsProtectedFileSecurity { param($Path) Assert-True ((Get-Item -LiteralPath $Path).Length -eq 0) 'Generated config contained secrets before its private ACL was applied.'; $script:emptyConfigProtected = $true }
        $generatedFixture = Join-Path $fixtureRoot 'private-generated.json'
        $privateConfig = [pscustomobject]@{ AppName = 'PrivateConfigFixture'; Environment = [pscustomobject]@{ FIXTURE_TOKEN = 'fixture-secret' } }
        Write-GeneratedConfig $privateConfig $generatedFixture
        Assert-True ($script:emptyConfigProtected -and ([IO.File]::ReadAllText($generatedFixture)).Contains('fixture-secret')) 'Generated config did not protect the empty file before writing secrets.'
        Assert-Throws { Write-GeneratedConfig $privateConfig $generatedFixture } ''
        function Set-WindowsProtectedFileSecurity { param($Path) throw 'mock config ACL failure' }
        $failedConfigFixture = Join-Path $fixtureRoot 'failed-generated.json'
        Assert-Throws { Write-GeneratedConfig $privateConfig $failedConfigFixture } 'mock config ACL failure'
        Assert-True (-not (Test-Path -LiteralPath $failedConfigFixture)) 'Private-config ACL failure left a generated file behind.'
    }

    Write-Host "NSSM least-privilege account selection and in-place update"
    . Import-SourceFunctions "scripts/windows/Install-NSSMService.ps1"
    $script:nativeCalls = [System.Collections.Generic.List[object]]::new()
    $script:nssmServiceExists = $false
    $script:nssmServiceRunning = $false
    function Invoke-CheckedNativeCommand {
        param([string]$FilePath, [object[]]$Arguments, [string]$Label)
        $script:nativeCalls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $Arguments; Label = $Label })
        if ($Arguments[0] -eq "install") { $script:nssmServiceExists = $true }
        if ($Arguments[0] -eq "start") { $script:nssmServiceRunning = $true }
    }
    function Get-Service {
        [CmdletBinding()]
        param([string]$Name)
        if (-not $script:nssmServiceExists) { return $null }
        $service = [pscustomobject]@{ Status = $(if ($script:nssmServiceRunning) { "Running" } else { "Stopped" }) }
        $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($State, $Timeout) }
        return $service
    }
    function Stop-Service { [CmdletBinding()] param([string]$Name, [switch]$Force) $script:nssmServiceRunning = $false }
    $script:nssmHealthFails = $false
    $script:nssmInstallerStates = [System.Collections.Generic.List[object]]::new()
    $script:nssmInstallerCompletions = [System.Collections.Generic.List[object]]::new()
    function Test-PostDeployHealth { param($Config) if ($script:nssmHealthFails) { throw 'fixture NSSM final HTTP failure' } }
    function Start-ManagedServiceInstallerTransaction {
        param($Config, $ExistingDeploymentLock, $ExistingManagedDeploymentTransaction)
        $state = [pscustomobject]@{ Fixture = $true; Lock = $ExistingDeploymentLock; Transaction = $ExistingManagedDeploymentTransaction }
        $script:nssmInstallerStates.Add($state)
        return $state
    }
    function Complete-ManagedServiceInstallerTransaction { param($Config, $State, $Failure) $script:nssmInstallerCompletions.Add([pscustomobject]@{ State = $State; Failure = $Failure }) }
    $script:securityAccounts = [System.Collections.Generic.List[string]]::new()
    function Set-WindowsServiceFilesystemSecurity { param($Config, [string]$Account) $script:securityAccounts.Add($Account) }
    function Set-NssmRegistrySecurity { param($Config, [string]$Account) $script:securityAccounts.Add('registry:' + $Account) }
    $script:privateNssmEnvironment = $null
    function Set-NssmServiceEnvironment { param($Config, $EnvironmentEntries) $script:privateNssmEnvironment = $EnvironmentEntries }
    $script:nssmBinaryOperations = [System.Collections.Generic.List[object]]::new()
    function Copy-ManagedNssmBinary { param($Config, $SourcePath, $RuntimePath, $Account) $script:nssmBinaryOperations.Add([pscustomobject]@{ Kind = 'copy'; Path = $RuntimePath; Account = $Account }) }
    function Set-NssmRuntimeServicePath { param($Config, $RuntimePath) $script:nssmBinaryOperations.Add([pscustomobject]@{ Kind = 'migrate'; Path = $RuntimePath }) }
    $nssmConfig = [pscustomobject]@{
        AppName = "FixtureApp"; DisplayName = "FixtureApp"; Description = "Fixture"
        AppDirectory = $source; ServiceDirectory = $fixtureRoot; LogDirectory = $site
        NodeExe = "C:\Program Files\nodejs\node.exe"; StartCommand = "server.js"; NodeArguments = ""
        Port = 3000; Environment = [pscustomobject]@{ FIXTURE_TOKEN = 'fixture-private-environment' }
    }
    $newSettings = Get-NssmServiceAccountSettings $nssmConfig $null
    Assert-True ($newSettings.Account -eq "NT AUTHORITY\NetworkService") "New NSSM service defaults to a privileged account."
    $ordinaryConfig = [pscustomobject]@{ ServiceAccount = "DOMAIN\AppUser" }
    Assert-Throws { Get-NssmServiceAccountSettings $ordinaryConfig $null } "requires ServiceAccountPassword"
    $trustedNssmPath = Join-Path (Join-Path $fixtureRoot 'trusted tools') 'nssm.exe'
    $otherNssmPath = Join-Path (Join-Path $fixtureRoot 'other tools') 'nssm.exe'
    $existingDefinition = [pscustomobject]@{ Name = "FixtureApp"; StartName = "DOMAIN\AppUser"; PathName = ('"' + $trustedNssmPath + '"') }
    $existingSettings = Get-NssmServiceAccountSettings $ordinaryConfig $existingDefinition
    Assert-True $existingSettings.PreserveExisting "NSSM update did not preserve an unchanged dedicated account credential."
    $omittedSettings = Get-NssmServiceAccountSettings $nssmConfig $existingDefinition
    Assert-True ($omittedSettings.Account -eq "DOMAIN\AppUser" -and $omittedSettings.PreserveExisting) "Omitting ServiceAccount reset the existing service identity."
    Assert-NssmServicePathCompatible $existingDefinition $trustedNssmPath
    Assert-Throws { Assert-NssmServicePathCompatible $existingDefinition $otherNssmPath } "different executable"
    $nssmAst = Get-SourceAst "scripts/windows/Install-NSSMService.ps1"
    $script:nssmTransaction = @($nssmAst.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Extent.Text.Contains('"Install NSSM service"')
    })[0].Extent.Text
    function Invoke-NssmFixture {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param($config, $accountSettings, $ExistingDeploymentLock, $ExistingManagedDeploymentTransaction)
        $sourceNssm = $trustedNssmPath
        $nssm = Join-Path $config.ServiceDirectory "$($config.AppName).nssm.exe"
        $escapedName = $config.AppName
        function Get-CimInstance {
            [CmdletBinding()] param($ClassName, $Filter)
            if (-not $script:nssmServiceExists) { return $null }
            return [pscustomobject]@{ Name = $config.AppName; StartName = $accountSettings.Account; PathName = ('"' + $sourceNssm + '"') }
        }
        Invoke-Expression $script:nssmTransaction
    }
    Invoke-NssmFixture -config $nssmConfig -accountSettings $newSettings
    Assert-True (@($script:nativeCalls | Where-Object { $_.Label -eq "Set NSSM service account" -and $_.Arguments[3] -eq "NT AUTHORITY\NetworkService" }).Count -eq 1) "NSSM installation did not apply the least-privilege identity."
    Assert-True ($script:securityAccounts.Count -eq 2 -and $script:securityAccounts[0] -eq $newSettings.Account -and $script:securityAccounts[1] -eq ('registry:' + $newSettings.Account)) "NSSM did not apply protected code/cache/log and registry-secret permissions for its actual identity."
    Assert-True ($script:privateNssmEnvironment -contains 'FIXTURE_TOKEN=fixture-private-environment' -and @($script:nativeCalls | Where-Object { @($_.Arguments) -contains 'FIXTURE_TOKEN=fixture-private-environment' }).Count -eq 0) 'NSSM environment secrets appeared in a child-process command line instead of the private registry API.'
    $script:nativeCalls.Clear()
    $script:nssmServiceRunning = $false
    Invoke-NssmFixture -config $nssmConfig -accountSettings $existingSettings
    Assert-True (@($script:nativeCalls | Where-Object { $_.Arguments[0] -in @("remove", "install") }).Count -eq 0) "NSSM update recreated the service and lost its identity."
    Assert-True (@($script:nativeCalls | Where-Object { $_.Label -eq "NSSM Application" }).Count -eq 1) "NSSM update did not update the existing service application."
    Assert-True (@($script:nativeCalls | Where-Object { $_.Label -eq "Set NSSM service account" }).Count -eq 0) "NSSM update reset an existing credential."
    Assert-True (@($script:nssmBinaryOperations | Where-Object { $_.Kind -eq 'copy' -and $_.Path -eq (Join-Path $fixtureRoot 'FixtureApp.nssm.exe') }).Count -eq 2 -and @($script:nssmBinaryOperations | Where-Object { $_.Kind -eq 'migrate' }).Count -eq 1) 'NSSM did not copy its executable into protected ServiceDirectory and migrate an existing registration in place.'
    Assert-True ($script:nssmInstallerStates.Count -eq 2 -and $script:nssmInstallerCompletions.Count -eq 2 -and @($script:nssmInstallerCompletions | Where-Object { $_.Failure }).Count -eq 0) 'NSSM successful mutation did not complete its managed installer scope.'
    $startsBeforeWhatIf = $script:nssmInstallerStates.Count
    $nativeBeforeWhatIf = $script:nativeCalls.Count
    Invoke-NssmFixture -config $nssmConfig -accountSettings $existingSettings -WhatIf
    Assert-True ($script:nssmInstallerStates.Count -eq $startsBeforeWhatIf -and $script:nssmInstallerCompletions.Count -eq $startsBeforeWhatIf -and $script:nativeCalls.Count -eq $nativeBeforeWhatIf) 'NSSM WhatIf acquired a lock/journal or changed the runtime.'
    $borrowedLockMarker = [pscustomobject]@{ Fixture = 'parent lock' }
    $borrowedTransactionMarker = [pscustomobject]@{ Fixture = 'parent recovery journal' }
    $script:nssmHealthFails = $true
    Assert-Throws { Invoke-NssmFixture -config $nssmConfig -accountSettings $existingSettings -ExistingDeploymentLock $borrowedLockMarker -ExistingManagedDeploymentTransaction $borrowedTransactionMarker } 'fixture NSSM final HTTP failure'
    $nssmFailureCompletion = $script:nssmInstallerCompletions[$script:nssmInstallerCompletions.Count - 1]
    Assert-True ($nssmFailureCompletion.Failure.Exception.Message -eq 'fixture NSSM final HTTP failure' -and $nssmFailureCompletion.State.Lock -eq $borrowedLockMarker -and $nssmFailureCompletion.State.Transaction -eq $borrowedTransactionMarker) 'NSSM final-health failure did not pass the exact borrowed ownership and caught error to managed recovery.'
    $script:nssmHealthFails = $false
    & {
        . Import-SourceFunctions 'scripts/windows/Install-NSSMService.ps1'
        function Set-WindowsProtectedPathSecurity { param($Path, $Account) $script:nssmBinaryOperations.Add([pscustomobject]@{ Kind = 'acl'; Path = $Path; Account = $Account }) }
        $binaryFixtureRoot = Join-Path $fixtureRoot 'nssm-binary'
        $binaryBackups = Join-Path $binaryFixtureRoot 'backups'
        New-Item -ItemType Directory -Path $binaryFixtureRoot, $binaryBackups -Force | Out-Null
        $binarySource = Join-Path $binaryFixtureRoot 'source.exe'; $binaryRuntime = Join-Path $binaryFixtureRoot 'ManagedApp.nssm.exe'
        Set-Content -LiteralPath $binarySource -Value 'new fake wrapper bytes'
        Set-Content -LiteralPath $binaryRuntime -Value 'previous fake wrapper bytes'
        $binaryConfig = [pscustomobject]@{ AppName = 'ManagedApp'; ServiceDirectory = $binaryFixtureRoot; BackupDirectory = $binaryBackups }
        $chocolateyRoot = Join-Path $binaryFixtureRoot 'chocolatey'
        $shimPath = Join-Path $chocolateyRoot 'bin/nssm.exe'
        $realPath = Join-Path $chocolateyRoot 'lib/nssm/tools/nssm.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $shimPath), (Split-Path -Parent $realPath) -Force | Out-Null
        Set-Content -LiteralPath $shimPath -Value 'non-relocatable shim'
        Set-Content -LiteralPath $realPath -Value 'actual NSSM executable fixture'
        Assert-True ((Resolve-NssmSourceExecutable $shimPath $chocolateyRoot) -eq [IO.Path]::GetFullPath($realPath)) 'NSSM copied the non-relocatable Chocolatey shim.'
        Assert-True ((Resolve-NssmSourceExecutable $binarySource $chocolateyRoot) -eq [IO.Path]::GetFullPath($binarySource)) 'Explicit standalone NSSM source was changed.'
        Remove-Item -LiteralPath $realPath -Force
        Assert-Throws { Resolve-NssmSourceExecutable $shimPath $chocolateyRoot } 'actual nssm.exe'
        Copy-ManagedNssmBinary $binaryConfig $binarySource $binaryRuntime 'NT AUTHORITY\NetworkService'
        Assert-True ((Get-FileHash -LiteralPath $binarySource).Hash -eq (Get-FileHash -LiteralPath $binaryRuntime).Hash) 'NSSM protected runtime binary did not match its source.'
        $binaryBackup = @(Get-ChildItem -LiteralPath $binaryBackups -File)[0]
        Assert-True ((Get-Content -LiteralPath $binaryBackup.FullName -Raw).Trim() -eq 'previous fake wrapper bytes') 'NSSM runtime binary update did not retain the previous executable bytes.'
        $managedDefinition = [pscustomobject]@{ Name = 'ManagedApp'; StartName = 'NT AUTHORITY\NetworkService'; PathName = ('"' + $binaryRuntime + '"') }
        Assert-NssmServicePathCompatible $managedDefinition $binarySource $binaryRuntime
    }
    if ($env:OS -eq 'Windows_NT') {
        & {
            function Get-WindowsServiceSecuritySid { param($Account) return [Security.Principal.SecurityIdentifier]::new('S-1-5-20') }
            $registryAcl = New-NssmRegistrySecurity 'NT AUTHORITY\NetworkService'
            $rules = @($registryAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            Assert-True ($registryAcl.AreAccessRulesProtected -and $rules.Count -eq 3) 'NSSM registry secrets inherited broad registry permissions.'
            Assert-True (@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-20' -and $_.RegistryRights -eq [Security.AccessControl.RegistryRights]::ReadKey }).Count -eq 1) 'NSSM runtime did not receive exactly read access to its private parameters.'
            Assert-True (@($rules | Where-Object { $_.IdentityReference.Value -in @('S-1-5-18', 'S-1-5-32-544') -and $_.RegistryRights -eq [Security.AccessControl.RegistryRights]::FullControl }).Count -eq 2) 'NSSM registry secrets lacked SYSTEM/Administrators full control.'
        }
    }
    & {
        $script:credentialChanges = [System.Collections.Generic.List[object]]::new()
        function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) return [pscustomobject]@{ Name = 'FixtureApp' } }
        function Grant-WindowsServiceLogonRight { param($Account) }
        function Invoke-CimMethod { [CmdletBinding()] param($InputObject, $MethodName, $Arguments) $script:credentialChanges.Add($Arguments); return [pscustomobject]@{ ReturnValue = 0 } }
        $passwordSettings = Get-NssmServiceAccountSettings ([pscustomobject]@{ ServiceAccount = 'DOMAIN\AppUser'; ServiceAccountPassword = 'fixture-private-password' }) $null
        Set-NssmServiceAccount -Config $nssmConfig -Nssm 'fixture-nssm' -Settings $passwordSettings
        Assert-True ($script:credentialChanges.Count -eq 1 -and $script:credentialChanges[0].StartName -eq 'DOMAIN\AppUser') 'NSSM did not configure custom credentials using the SCM API.'
        Assert-True (@($script:nativeCalls | Where-Object { @($_.Arguments) -contains 'fixture-private-password' }).Count -eq 0) 'NSSM exposed its service-account password in a child process command line.'
    }
    & {
        Write-Host 'Managed host recovery, credential prevalidation, SCM recovery metadata, and PM2 definitions'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        . Import-SourceFunctions 'scripts/windows/IisDeploymentState.ps1'
        . Import-SourceFunctions 'scripts/windows/ManagedServiceConfiguration.ps1'
        function Assert-WindowsPm2ExecutionAllowed { param($Pm2HomePath, $ExpectedOwnerSid) }
        Initialize-ManagedServiceConfigurationApi
        $pm2HomeProbe = Join-Path $fixtureRoot 'pm2-home-probe.ps1'
        Set-Content -LiteralPath $pm2HomeProbe -Value '[Environment]::GetEnvironmentVariable("PM2_HOME", "Process"); $global:LASTEXITCODE = 0'
        $pm2HomeFailure = Join-Path $fixtureRoot 'pm2-home-failure.ps1'
        Set-Content -LiteralPath $pm2HomeFailure -Value '$global:LASTEXITCODE = 3'
        $previousProbeHome = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('PM2_HOME', 'fixture-previous-home', 'Process')
            $probedHome = @(Invoke-ManagedPm2Command $pm2HomeProbe @('jlist') 'fixture-configured-home')
            Assert-True ($probedHome[0] -eq 'fixture-configured-home' -and $env:PM2_HOME -eq 'fixture-previous-home') 'PM2 command used the wrong daemon home or leaked its environment override.'
            Assert-Throws { Invoke-ManagedPm2Command $pm2HomeFailure @('jlist') 'fixture-configured-home' } 'failed with exit code 3'
            Assert-True ($env:PM2_HOME -eq 'fixture-previous-home') 'Failed PM2 command leaked its configured daemon home.'
        } finally { [Environment]::SetEnvironmentVariable('PM2_HOME', $previousProbeHome, 'Process'); $global:LASTEXITCODE = 0 }
        $hostRoot = Join-Path $fixtureRoot 'host-transaction'
        $serviceRoot = Join-Path $hostRoot 'service'
        $appRoot = Join-Path $hostRoot 'app'
        $script:hostLockRoot = Join-Path $serviceRoot '.deployment-locks'
        New-Item -ItemType Directory -Path $serviceRoot, $appRoot, $script:hostLockRoot -Force | Out-Null
        function Assert-ExistingDeploymentLock { param($Config, $Lock) }
        function Assert-NoPendingDeploymentRecovery { param($Config, $LockDirectory) }
        function Assert-DeploymentPathNotReparsePoint { param([string]$Path) }
        function Get-DeploymentLockDirectory { param($Config) return $script:hostLockRoot }
        function Get-IisDeploymentControlDirectory { return (Join-Path $hostRoot 'iis-control') }
        function Set-ProtectedDeploymentLockDirectoryAcl { param($Path) }
        if ($env:OS -eq 'Windows_NT') {
            $leaseJournal = Join-Path $hostRoot 'lease-journal'
            New-Item -ItemType Directory -Path $leaseJournal -Force | Out-Null
            $lease = Enter-IisDeploymentLock $leaseJournal
            try {
                Assert-IisDeploymentLockLease $lease.LeasePath $lease.Token
                Assert-Throws { Assert-IisDeploymentLockLease $lease.LeasePath 'incorrect-token' } 'Invalid IIS deployment lock lease'
                $leaseDefinition = Import-Clixml -LiteralPath $lease.LeasePath
                $leaseDefinition.OwnerStartTimeUtcTicks++
                $leaseDefinition | Export-Clixml -LiteralPath $lease.LeasePath
                Assert-Throws { Assert-IisDeploymentLockLease $lease.LeasePath $lease.Token } 'owner process was replaced'
                $leaseDefinition.OwnerStartTimeUtcTicks--
                $leaseDefinition | Export-Clixml -LiteralPath $lease.LeasePath
            } finally { Exit-IisDeploymentLock $lease.Token }
            Assert-Throws { Assert-IisDeploymentLockLease $lease.LeasePath $lease.Token } 'lease is no longer held'
        }
        $script:hostActions = [System.Collections.Generic.List[string]]::new()
        $script:rollbackHealthCalls = [System.Collections.Generic.List[object]]::new()
        $script:rollbackHealthFails = $false
        function Test-PostDeployHealth {
            param($Config)
            $script:hostActions.Add('rollback-health:' + $Config.HealthUrl)
            $script:rollbackHealthCalls.Add($Config)
            if ($script:rollbackHealthFails) { throw 'fixture previous HTTP health failed' }
        }
        $script:cimQueryCount = 0
        $script:recoverySnapshot = [pscustomobject]@{ ResetPeriod = 900; RebootMessage = 'fixture reboot'; Command = 'fixture recovery'; Actions = @([pscustomobject]@{ Type = 1; Delay = 30000 }); NonCrashFailures = $false; DelayedAutoStart = $true; Description = 'previous description' }
        $script:recoveryRestored = $null
        $script:fixtureTaskXml = '<Task>previous fixture task</Task>'
        $script:registeredTaskCredentials = [System.Collections.Generic.List[object]]::new()
        $script:hostDefinition = [pscustomobject]@{ Name = 'HostRecoveryFixture'; PathName = ('"' + (Join-Path $serviceRoot 'HostRecoveryFixture.exe') + '"'); StartMode = 'Auto'; StartName = 'DOMAIN\PreviousApp'; DisplayName = 'Previous app'; State = 'Running' }
        function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) $script:cimQueryCount++; return $script:hostDefinition }
        function Invoke-CimMethod {
            [CmdletBinding()] param($InputObject, $MethodName, $Arguments)
            foreach ($key in $Arguments.Keys) { if ($key -ne 'StartPassword') { $InputObject.$key = $Arguments[$key] } }
            if ($Arguments.ContainsKey('StartMode')) { $script:hostActions.Add('mode:' + $Arguments.StartMode) }
            if ($Arguments.ContainsKey('StartPassword')) { $script:hostActions.Add('previous-credential-restored') }
            return [pscustomobject]@{ ReturnValue = 0 }
        }
        function Get-Service {
            [CmdletBinding()] param([string]$Name)
            if (-not $script:hostDefinition) { return $null }
            $record = [pscustomobject]@{ Status = $(if ($script:hostDefinition.State -eq 'Running') { 'Running' } else { 'Stopped' }) }
            $record | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
            return $record
        }
        function Stop-Service { [CmdletBinding()] param($Name, [switch]$Force) $script:hostActions.Add('stop'); $script:hostDefinition.State = 'Stopped' }
        function Start-Service { [CmdletBinding()] param($Name) $script:hostActions.Add('start'); $script:hostDefinition.State = 'Running' }
        function Get-ManagedServiceRecoveryConfiguration { param($Name) return $script:recoverySnapshot }
        function Restore-ManagedServiceRecoveryConfiguration { param($Name, $Configuration) $script:recoveryRestored = $Configuration; $script:hostActions.Add('recovery-restored') }
        $script:fixtureTaskExists = $true
        $script:fixtureTaskQueryFails = $false
        $script:fixtureTaskRemovalFails = $false
        $script:fixtureTaskSurvivesRemoval = $false
        function Get-ScheduledTask {
            [CmdletBinding()] param($TaskName)
            if ($script:fixtureTaskQueryFails) { throw 'fixture task query permission denied' }
            if ($script:fixtureTaskExists) { return [pscustomobject]@{ TaskName = $TaskName } }
            return $null
        }
        function Export-ScheduledTask { [CmdletBinding()] param($TaskName) return $script:fixtureTaskXml }
        function Disable-ScheduledTask { [CmdletBinding()] param($TaskName) $script:hostActions.Add('task-disabled') }
        function Register-ScheduledTask { [CmdletBinding()] param($TaskName, $Xml, [switch]$Force, $User, $Password) $script:fixtureTaskExists = $true; $script:hostActions.Add('task-restored'); $script:registeredTaskCredentials.Add([pscustomobject]@{ User = $User; Password = $Password }) }
        function Unregister-ScheduledTask {
            [CmdletBinding(SupportsShouldProcess=$true)] param($TaskName)
            $script:hostActions.Add('task-removed')
            if ($script:fixtureTaskRemovalFails) { throw 'fixture health task removal denied' }
            if (-not $script:fixtureTaskSurvivesRemoval) { $script:fixtureTaskExists = $false }
        }
        function Test-Path {
            [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$PathType = 'Any')
            $targetPath = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($targetPath -like 'HKLM:*') { return $false }
            return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        $hostConfig = [pscustomobject]@{ AppName = 'HostRecoveryFixture'; AppDirectory = $appRoot; ServiceDirectory = $serviceRoot; ServiceManager = 'winsw'; ReverseProxy = 'none'; ServiceAccount = 'NT AUTHORITY\NetworkService'; HealthUrl = 'http://127.0.0.1:7000/new-health'; HealthCheckTimeoutSeconds = 8 }
        $script:managerMarkerPath = Join-Path $hostRoot 'manager-marker.json'
        function Get-ManagedHealthMonitorConfigPath { param($Config) return $script:managerMarkerPath }
        Write-Host 'Automatic runtime/manager migration rejects before quiescing any process'
        $oldDefinition = $script:hostDefinition
        foreach ($migration in @(
            @{ Previous = '{"ServiceManager":"winsw"}'; Desired = 'pm2'; Expected = "from 'winsw' to 'pm2'" },
            @{ Previous = '{"ServiceManager":"pm2"}'; Desired = 'winsw'; Expected = "from 'pm2' to 'winsw'" },
            @{ Previous = '{"RetentionOnly":true}'; Desired = 'winsw'; Expected = "from 'static' to 'winsw'" },
            @{ Previous = '{"ServiceManager":"winsw"}'; Desired = 'nssm'; Expected = "from 'winsw' to 'nssm'" },
            @{ Previous = '{"RetentionOnly":"false","ServiceManager":"winsw"}'; Desired = 'winsw'; Expected = 'must be a JSON boolean' }
        )) {
            Set-Content -LiteralPath $script:managerMarkerPath -Value $migration.Previous
            $hostConfig.ServiceManager = $migration.Desired
            Assert-Throws { Assert-ManagedDeploymentManagerTransition $hostConfig } $migration.Expected
        }
        Remove-Item -LiteralPath $script:managerMarkerPath -Force
        foreach ($manager in @('pm2', 'static')) {
            $hostConfig.ServiceManager = $manager
            Assert-Throws { Assert-ManagedDeploymentManagerTransition $hostConfig } 'A native service already uses AppName'
        }
        $hostConfig.ServiceManager = 'winsw'
        $originalWrapperPath = $script:hostDefinition.PathName
        $script:hostDefinition.PathName = '"C:\unrelated\other.exe"'
        Assert-Throws { Assert-ManagedDeploymentManagerTransition $hostConfig } 'different executable'
        $script:hostDefinition.PathName = $originalWrapperPath
        Assert-ManagedDeploymentManagerTransition $hostConfig
        Assert-True ($script:hostActions.Count -eq 0 -and $script:hostDefinition -eq $oldDefinition) 'Migration rejection changed or stopped the previous runtime.'
        $previousMonitorFixture = Join-Path $hostRoot 'previous-monitor.config.json'
        Set-Content -LiteralPath $previousMonitorFixture -Value '{"HealthUrl":"http://127.0.0.1:6000/old-health","HealthCheckTimeoutSeconds":4,"PostDeployHealthAttempts":2,"PostDeployHealthDelaySeconds":0,"Environment":{"SECRET":"fixture-secret"}}'
        $oldHealthPolicy = Get-ManagedRollbackHealthConfig $hostConfig $previousMonitorFixture
        Assert-True ($oldHealthPolicy.HealthUrl -eq 'http://127.0.0.1:6000/old-health' -and $oldHealthPolicy.HealthCheckTimeoutSeconds -eq 4 -and $oldHealthPolicy.PostDeployHealthAttempts -eq 2 -and -not $oldHealthPolicy.PSObject.Properties['Environment']) 'Rollback policy did not select the previous monitor endpoint/timeouts or included unrelated secrets.'
        Assert-True ((Get-ManagedRollbackHealthConfig $hostConfig).HealthUrl -eq $hostConfig.HealthUrl) 'Missing old monitor did not fall back to the configured health endpoint.'
        $hostConfig | Add-Member NoteProperty PreviousHealthUrl 'http://127.0.0.1:9000/operator-previous-health'
        Assert-True ((Get-ManagedRollbackHealthConfig $hostConfig $previousMonitorFixture).HealthUrl -eq $hostConfig.PreviousHealthUrl) 'Explicit PreviousHealthUrl did not override the inferred rollback endpoint.'
        $hostConfig.PSObject.Properties.Remove('PreviousHealthUrl')
        $fixtureLock = [pscustomobject]@{ Path = Join-Path $script:hostLockRoot 'HostRecoveryFixture.lock' }
        Assert-Throws { Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening } 'requires PreviousServiceAccountPassword before deployment'
        Assert-True ($script:hostActions.Count -eq 0) 'Credential validation stopped or changed the existing service.'
        $hostConfig | Add-Member NoteProperty PreviousServiceAccountPassword 'fixture-old-password'
        $xmlPath = Join-Path $serviceRoot 'HostRecoveryFixture.xml'
        Set-Content -LiteralPath $xmlPath -Value 'previous service configuration'
        $hostTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        $hostTransaction.PreviousHealthConfig = $oldHealthPolicy
        Suspend-ManagedDeploymentServiceState $hostConfig $hostTransaction
        Assert-True ($script:hostActions[0] -eq 'task-disabled' -and $script:hostActions[1] -eq 'mode:Disabled' -and $script:hostActions[2] -eq 'stop') 'Service/app mutation happened before suspending the monitor and disabling queued SCM recovery.'
        Set-Content -LiteralPath $xmlPath -Value 'broken new configuration'
        $script:hostDefinition.StartName = 'NT AUTHORITY\NetworkService'
        $script:hostDefinition.DisplayName = 'new display name'
        Restore-ManagedDeploymentTransaction $hostConfig $hostTransaction
        Assert-True ((Get-Content -LiteralPath $xmlPath -Raw).Trim() -eq 'previous service configuration') 'Host rollback did not restore previous control bytes.'
        Assert-True ($script:hostDefinition.StartName -eq 'DOMAIN\PreviousApp' -and $script:hostDefinition.StartMode -eq 'Disabled') 'Host rollback did not restore the previous identity while keeping the service disabled.'
        Assert-True ($script:recoveryRestored.ResetPeriod -eq 900 -and $script:recoveryRestored.Actions[0].Delay -eq 30000 -and $script:recoveryRestored.DelayedAutoStart -and -not $script:recoveryRestored.NonCrashFailures -and $script:recoveryRestored.Description -eq 'previous description') 'Rollback lost SCM recovery actions, failure flag, delayed startup, or description.'
        Assert-True (-not ($script:hostActions -contains 'start')) 'Host rollback started service before app directory restoration.'
        Resume-ManagedDeploymentServiceState $hostConfig $hostTransaction
        Assert-True ($script:hostDefinition.State -eq 'Running' -and $script:hostDefinition.StartMode -eq 'Automatic') 'Previous running service was not resumed with its original startup mode.'
        Assert-True ($script:rollbackHealthCalls.Count -eq 1 -and $script:rollbackHealthCalls[0].HealthUrl -eq $oldHealthPolicy.HealthUrl -and $script:hostActions[$script:hostActions.Count - 1] -eq ('rollback-health:' + $oldHealthPolicy.HealthUrl)) 'HTTP rollback verification did not use the previous endpoint after the service resumed.'
        Complete-ManagedDeploymentTransaction $hostConfig $hostTransaction
        Assert-True (-not (Test-Path -LiteralPath $hostTransaction.Directory)) 'Successful recovery retained its journal.'
        $failedHealthTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $failedHealthTransaction
        Restore-ManagedDeploymentTransaction $hostConfig $failedHealthTransaction
        Assert-Throws { Complete-ManagedDeploymentTransaction $hostConfig $failedHealthTransaction } 'Previous HTTP health has not been verified'
        $script:rollbackHealthFails = $true
        Assert-Throws { Resume-ManagedDeploymentServiceState $hostConfig $failedHealthTransaction } 'fixture previous HTTP health failed'
        Assert-True ((Test-Path -LiteralPath $failedHealthTransaction.Directory) -and -not $failedHealthTransaction.RollbackHealthVerified) 'Failed previous HTTP verification discarded the recovery journal or marked rollback successful.'
        Assert-Throws { Complete-ManagedDeploymentTransaction $hostConfig $failedHealthTransaction } 'Previous HTTP health has not been verified'
        $script:rollbackHealthFails = $false
        Resume-ManagedDeploymentServiceState $hostConfig $failedHealthTransaction
        Complete-ManagedDeploymentTransaction $hostConfig $failedHealthTransaction
        $script:fixtureTaskXml = '<Task><Principals><Principal><UserId>DOMAIN\PreviousTaskOwner</UserId><LogonType>Password</LogonType></Principal></Principals></Task>'
        $actionsBeforeTaskValidation = $script:hostActions.Count
        Assert-Throws { Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening } 'requires PreviousHealthCheckTaskPassword'
        Assert-True ($script:hostActions.Count -eq $actionsBeforeTaskValidation) 'Health-task credential prevalidation changed the host.'
        $hostConfig | Add-Member NoteProperty PreviousHealthCheckTaskPassword 'fixture-task-password'
        $taskTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $taskTransaction
        Restore-ManagedDeploymentTransaction $hostConfig $taskTransaction
        $restoredTaskCredential = $script:registeredTaskCredentials[$script:registeredTaskCredentials.Count - 1]
        Assert-True ($restoredTaskCredential.User -eq 'DOMAIN\PreviousTaskOwner' -and $restoredTaskCredential.Password -eq 'fixture-task-password') 'Password-logon task rollback omitted its previous principal credential.'
        Resume-ManagedDeploymentServiceState $hostConfig $taskTransaction
        Complete-ManagedDeploymentTransaction $hostConfig $taskTransaction
        $script:fixtureTaskXml = '<Task>previous fixture task</Task>'
        $script:hostDefinition.State = 'Stopped'; $script:hostDefinition.StartMode = 'Manual'
        $startsBeforeNativeStopped = @($script:hostActions | Where-Object { $_ -eq 'start' }).Count
        $healthCallsBeforeNativeStopped = $script:rollbackHealthCalls.Count
        $nativeStopped = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $nativeStopped
        Restore-ManagedDeploymentTransaction $hostConfig $nativeStopped
        Resume-ManagedDeploymentServiceState $hostConfig $nativeStopped
        Assert-True ($script:hostDefinition.State -eq 'Stopped' -and $script:hostDefinition.StartMode -eq 'Manual' -and @($script:hostActions | Where-Object { $_ -eq 'start' }).Count -eq $startsBeforeNativeStopped) 'Rollback started a previously stopped native service or changed its manual startup mode.'
        Assert-True ($script:rollbackHealthCalls.Count -eq $healthCallsBeforeNativeStopped) 'Rollback attempted HTTP verification for a previously stopped native service.'
        Complete-ManagedDeploymentTransaction $hostConfig $nativeStopped
        Write-Host 'New health-task rollback fails closed and verifies removal before resuming'
        $script:fixtureTaskExists = $false
        $newTaskTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $newTaskTransaction
        $script:fixtureTaskExists = $true
        $script:fixtureTaskRemovalFails = $true
        Assert-Throws { Restore-ManagedDeploymentTransaction $hostConfig $newTaskTransaction } 'fixture health task removal denied'
        Assert-True (-not $newTaskTransaction.Restored -and (Test-Path -LiteralPath $newTaskTransaction.Directory) -and $script:hostDefinition.State -eq 'Stopped') 'Failed introduced-task removal resumed the service or discarded recovery evidence.'
        $script:fixtureTaskRemovalFails = $false
        $script:fixtureTaskSurvivesRemoval = $true
        Assert-Throws { Restore-ManagedDeploymentTransaction $hostConfig $newTaskTransaction } 'New health task survived rollback removal'
        Assert-True (-not $newTaskTransaction.Restored -and (Test-Path -LiteralPath $newTaskTransaction.Directory)) 'A surviving introduced task was accepted as restored.'
        $script:fixtureTaskSurvivesRemoval = $false
        Restore-ManagedDeploymentTransaction $hostConfig $newTaskTransaction
        Resume-ManagedDeploymentServiceState $hostConfig $newTaskTransaction
        Assert-True (-not $script:fixtureTaskExists -and $newTaskTransaction.Restored) 'Rollback did not remove and verify the introduced task.'
        Complete-ManagedDeploymentTransaction $hostConfig $newTaskTransaction
        $script:fixtureTaskExists = $true
        $script:fixtureTaskQueryFails = $true
        $actionsBeforeTaskQuery = $script:hostActions.Count
        Assert-Throws { Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening } 'fixture task query permission denied'
        Assert-True ($script:hostActions.Count -eq $actionsBeforeTaskQuery) 'Failed task existence query mutated service state.'
        $script:fixtureTaskQueryFails = $false
        $script:pm2ForeignEntries = @(
            [pscustomobject]@{ name = 'ForeignPath'; pm_id = 90; pm2_env = [pscustomobject]@{ name = 'ForeignPath'; pm_exec_path = (Join-Path (Get-Location).ProviderPath 'HostRecoveryFixture'); status = 'online' } },
            [pscustomobject]@{ name = 'ForeignNamespace'; pm_id = 91; pm2_env = [pscustomobject]@{ name = 'ForeignNamespace'; namespace = 'HostRecoveryFixture'; status = 'online' } }
        )
        $foreignPm2State = ConvertTo-Json -InputObject $script:pm2ForeignEntries -Depth 10 -Compress
        $script:pm2Entries = @([pscustomobject]@{ name = 'HostRecoveryFixture'; pm_id = 7; pm2_env = [pscustomobject]@{ name = 'HostRecoveryFixture'; pm_exec_path = (Join-Path $appRoot 'previous.js'); pm_cwd = $appRoot; exec_interpreter = 'node'; args = @('--old'); node_args = @('--max-old-space-size=256'); env = [pscustomobject]@{ FIXTURE_SETTING = 'previous-value' }; max_memory_restart = '128M'; status = 'online' } }) + $script:pm2ForeignEntries
        $script:pm2Starts = 0
        $script:pm2RestoredDefinition = $null
        function Get-Command { [CmdletBinding()] param([string]$Name) if ($Name -eq 'pm2') { return [pscustomobject]@{ Name = 'fixture-pm2'; Source = 'fixture-pm2' } }; return Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
        function Get-WindowsPm2RuntimeContext { param($Config) return [pscustomobject]@{ Account = 'fixture-owner'; Home = (Join-Path $hostRoot 'pm2-home'); CommandName = 'fixture-pm2' } }
        function Invoke-ManagedPm2Command {
            param([string]$CommandName, [object[]]$Arguments)
            switch ($Arguments[0]) {
                'jlist' { return (ConvertTo-Json -InputObject @($script:pm2Entries) -Depth 30) }
                'delete' {
                    Assert-True ([string]$Arguments[1] -cmatch '^[0-9]+$') 'Managed transaction used an ambiguous PM2 name selector.'
                    $script:pm2Entries = @($script:pm2Entries | Where-Object { [string]$_.pm_id -cne [string]$Arguments[1] })
                    $script:hostActions.Add('pm2-delete')
                }
                'start' {
                    $json = ([IO.File]::ReadAllText([string]$Arguments[1])) -replace '^module\.exports = ', '' -replace ';$', ''
                    $definition = ($json | ConvertFrom-Json).apps[0]; $script:pm2RestoredDefinition = $definition
                    if ($definition.autostart) { $script:pm2Starts++ }
                    $script:pm2Entries += [pscustomobject]@{ name = $definition.name; pm_id = 70; pm2_env = [pscustomobject]@{ name = $definition.name; pm_exec_path = $definition.script; pm_cwd = $definition.cwd; exec_interpreter = $definition.interpreter; args = $definition.args; node_args = $definition.node_args; env = $definition.env; max_memory_restart = $definition.max_memory_restart; status = $(if ($definition.autostart) { 'online' } else { 'stopped' }) } }
                }
                'save' { $script:hostActions.Add('pm2-save') }
                default { throw 'Unexpected mocked PM2 transaction action.' }
            }
        }
        $hostConfig.ServiceManager = 'pm2'
        $script:hostDefinition = $null
        $pm2Transaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $pm2Transaction
        Assert-True (@(Get-ManagedPm2Entries 'fixture-pm2' $hostConfig.AppName).Count -eq 0 -and (ConvertTo-Json -InputObject $script:pm2Entries -Depth 10 -Compress) -ceq $foreignPm2State) 'PM2 suspension retained managed watchers or changed another app selected by its path/namespace.'
        $script:pm2Entries += [pscustomobject]@{ name = 'HostRecoveryFixture'; pm_id = 8; pm2_env = [pscustomobject]@{ name = 'HostRecoveryFixture'; status = 'online' } }
        Restore-ManagedDeploymentTransaction $hostConfig $pm2Transaction
        Assert-True ($script:pm2Starts -eq 0 -and (ConvertTo-Json -InputObject $script:pm2Entries -Depth 10 -Compress) -ceq $foreignPm2State) 'PM2 rollback started a process before app recovery or removed an unrelated app.'
        Resume-ManagedDeploymentServiceState $hostConfig $pm2Transaction
        Assert-True ($script:pm2RestoredDefinition.script -eq (Join-Path $appRoot 'previous.js') -and $script:pm2RestoredDefinition.env.FIXTURE_SETTING -eq 'previous-value' -and $script:pm2RestoredDefinition.args[0] -eq '--old' -and $script:pm2RestoredDefinition.node_args[0] -eq '--max-old-space-size=256' -and $script:pm2RestoredDefinition.max_memory_restart -eq '128M') 'PM2 rollback changed previous script, cwd, interpreter, arguments, environment, or memory policy.'
        Complete-ManagedDeploymentTransaction $hostConfig $pm2Transaction
        @($script:pm2Entries | Where-Object { $_.name -ceq $hostConfig.AppName })[0].pm2_env.status = 'stopped'
        $startsBeforeStoppedRollback = $script:pm2Starts
        $healthCallsBeforePm2Stopped = $script:rollbackHealthCalls.Count
        $stoppedTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $stoppedTransaction
        Restore-ManagedDeploymentTransaction $hostConfig $stoppedTransaction
        Resume-ManagedDeploymentServiceState $hostConfig $stoppedTransaction
        Assert-True (@($script:pm2Entries | Where-Object { $_.name -ceq $hostConfig.AppName })[0].pm2_env.status -eq 'stopped' -and $script:pm2Starts -eq $startsBeforeStoppedRollback) 'Previously stopped PM2 definition launched during rollback.'
        Assert-True ($script:rollbackHealthCalls.Count -eq $healthCallsBeforePm2Stopped) 'Rollback attempted HTTP verification for a previously stopped PM2 definition.'
        Complete-ManagedDeploymentTransaction $hostConfig $stoppedTransaction
        $beforePm2CaseRefusal = $script:hostActions.Count
        $script:pm2Entries += [pscustomobject]@{ name = 'hostrecoveryfixture'; pm_id = 71; pm2_env = [pscustomobject]@{ name = 'hostrecoveryfixture'; status = 'online' } }
        Assert-Throws { Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening } 'differently cased'
        Assert-True ($script:hostActions.Count -eq $beforePm2CaseRefusal -and $script:pm2Entries.Count -eq 4) 'Case-alias transaction refusal changed the runtime.'
        $script:pm2Entries = @($script:pm2Entries | Where-Object { $_.name -cne 'hostrecoveryfixture' })
        $script:pm2Entries += [pscustomobject]@{ name = 'HostRecoveryFixture'; pm_id = 72; pm2_env = [pscustomobject]@{ name = 'HostRecoveryFixture'; status = 'online' } }
        Assert-Throws { Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening } 'requires one managed process'
        Assert-True ($script:hostActions.Count -eq $beforePm2CaseRefusal) 'Unsupported multi-process snapshot refusal mutated PM2.'
        $hostConfig.ServiceManager = 'winsw'
        $hostConfig | Add-Member NoteProperty DeploymentMode 'static_iis'
        function Enter-IisDeploymentLock { param($JournalDirectory) return [pscustomobject]@{ LeasePath = 'fixture'; Token = 'fixture' } }
        function Invoke-NativeIisDeploymentState { param($Action, $Transaction, $Config) }
        function Exit-IisDeploymentLock { param($Token) }
        $queriesBeforeStatic = $script:cimQueryCount
        $actionsBeforeStatic = $script:hostActions.Count
        $healthCallsBeforeStatic = $script:rollbackHealthCalls.Count
        $staticTransaction = Start-ManagedDeploymentTransaction -Config $hostConfig -Lock $fixtureLock -SkipAclHardening
        Suspend-ManagedDeploymentServiceState $hostConfig $staticTransaction
        Assert-True ($script:cimQueryCount -eq ($queriesBeforeStatic + 1) -and @($script:hostActions | Select-Object -Skip $actionsBeforeStatic | Where-Object { $_ -in @('stop', 'start') -or $_ -like 'mode:*' }).Count -eq 0) 'Static IIS deployment suspended an unrelated SCM service or skipped the read-only migration guard.'
        Restore-ManagedDeploymentTransaction $hostConfig $staticTransaction
        Resume-ManagedDeploymentServiceState $hostConfig $staticTransaction
        Assert-True ($script:rollbackHealthCalls.Count -eq $healthCallsBeforeStatic) 'Static IIS rollback attempted Node HTTP verification.'
        Complete-ManagedDeploymentTransaction $hostConfig $staticTransaction
    }
    & {
        Write-Host 'Direct service installers own recovery, while deployment children preserve parent journals and leases'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        $installerRoot = Join-Path $fixtureRoot 'installer-ownership'
        New-Item -ItemType Directory -Path $installerRoot -Force | Out-Null
        $installerConfig = [pscustomobject]@{ AppName = 'DirectInstallerFixture'; ServiceManager = 'winsw' }
        $script:installerActions = [System.Collections.Generic.List[string]]::new()
        $script:installerSuspendFails = $false
        $script:installerResumeFails = $false
        function Assert-ManagedDeploymentManagerTransition { param($Config) $script:installerActions.Add('guard') }
        function Enter-DeploymentLock {
            param($Config)
            $script:installerActions.Add('lock')
            $path = Join-Path $installerRoot 'fixture.lock'
            return [pscustomobject]@{ Path = $path; Stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        }
        function Exit-DeploymentLock { param($Lock) $script:installerActions.Add('unlock'); $Lock.Stream.Dispose() }
        function Assert-ExistingDeploymentLock { param($Config, $Lock) if (-not $Lock.Stream.CanRead) { throw 'Fixture lock is not live.' } }
        function Start-ManagedDeploymentTransaction {
            param($Config, $Lock)
            $script:installerActions.Add('snapshot')
            $directory = Join-Path $installerRoot ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory | Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'recovery.fixture'), 'previous host state')
            return [pscustomobject]@{ Manager = 'winsw'; Directory = $directory; Suspended = $false; Restored = $false }
        }
        function Assert-ManagedDeploymentTransaction { param($Config, $Transaction) if (-not (Test-Path -LiteralPath $Transaction.Directory)) { throw 'Fixture recovery journal missing.' } }
        function Suspend-ManagedDeploymentServiceState { param($Config, $Transaction) $script:installerActions.Add('suspend'); if ($script:installerSuspendFails) { throw 'fixture suspension failed' }; $Transaction.Suspended = $true }
        function Restore-ManagedDeploymentTransaction { param($Config, $Transaction) $script:installerActions.Add('restore'); $Transaction.Restored = $true }
        function Resume-ManagedDeploymentServiceState { param($Config, $Transaction) $script:installerActions.Add('resume'); if ($script:installerResumeFails) { throw 'fixture rollback health failed' } }
        function Release-ManagedIisDeploymentLock { param($Transaction) $script:installerActions.Add('release-iis') }
        function Complete-ManagedDeploymentTransaction { param($Config, $Transaction) $script:installerActions.Add('commit'); Remove-Item -LiteralPath (Join-Path $Transaction.Directory 'recovery.fixture'); Remove-Item -LiteralPath $Transaction.Directory }

        $ownedInstaller = Start-ManagedServiceInstallerTransaction -Config $installerConfig
        Assert-True ($ownedInstaller.OwnsLock -and $ownedInstaller.OwnsTransaction -and ($script:installerActions -join ',') -eq 'guard,lock,snapshot,suspend') 'Standalone mutation did not acquire a guarded snapshot and quiesce before returning control.'
        Assert-Throws { [IO.File]::Open($ownedInstaller.Lock.Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None).Dispose() } ''
        Complete-ManagedServiceInstallerTransaction -Config $installerConfig -State $ownedInstaller -Failure ([Exception]::new('fixture downstream failure'))
        Assert-True (($script:installerActions -join ',') -eq 'guard,lock,snapshot,suspend,restore,resume,commit,release-iis,unlock' -and -not $ownedInstaller.Lock.Stream.CanRead -and -not (Test-Path -LiteralPath $ownedInstaller.Transaction.Directory)) 'Standalone caught failure did not restore and resume before committing and releasing its lock.'

        $script:installerActions.Clear()
        $parentLock = Enter-DeploymentLock $installerConfig
        $parentTransaction = Start-ManagedDeploymentTransaction $installerConfig $parentLock
        $childInstaller = Start-ManagedServiceInstallerTransaction -Config $installerConfig -ExistingDeploymentLock $parentLock -ExistingManagedDeploymentTransaction $parentTransaction
        $actionsBeforeChildComplete = $script:installerActions.Count
        Complete-ManagedServiceInstallerTransaction -Config $installerConfig -State $childInstaller -Failure ([Exception]::new('fixture child failure'))
        Assert-True (-not $childInstaller.OwnsLock -and -not $childInstaller.OwnsTransaction -and $script:installerActions.Count -eq $actionsBeforeChildComplete -and $parentLock.Stream.CanRead -and (Test-Path -LiteralPath $parentTransaction.Directory) -and -not $parentTransaction.Restored) 'A child restored/resumed/committed its parent before package rollback, or released the parent lease.'
        Restore-ManagedDeploymentTransaction $installerConfig $parentTransaction
        Resume-ManagedDeploymentServiceState $installerConfig $parentTransaction
        Complete-ManagedDeploymentTransaction $installerConfig $parentTransaction
        Exit-DeploymentLock $parentLock

        $script:installerActions.Clear(); $script:installerSuspendFails = $true
        Assert-Throws { Start-ManagedServiceInstallerTransaction -Config $installerConfig } 'fixture suspension failed'
        Assert-True (($script:installerActions -join ',') -eq 'guard,lock,snapshot,suspend,restore,resume,commit,release-iis,unlock') 'Partial initial suspension failure leaked the standalone lock or skipped recovery.'
        $script:installerSuspendFails = $false
        $script:installerActions.Clear()
        $unhealthyRollback = Start-ManagedServiceInstallerTransaction -Config $installerConfig
        $script:installerResumeFails = $true
        Assert-Throws { Complete-ManagedServiceInstallerTransaction -Config $installerConfig -State $unhealthyRollback -Failure ([Exception]::new('fixture install failed')) } 'Recovery journal retained'
        Assert-True ((Test-Path -LiteralPath (Join-Path $unhealthyRollback.Transaction.Directory 'recovery.fixture')) -and -not $unhealthyRollback.Lock.Stream.CanRead -and -not ($script:installerActions -contains 'commit')) 'Unhealthy rollback discarded recovery evidence or leaked its lock.'
        $script:installerResumeFails = $false
        Complete-ManagedDeploymentTransaction $installerConfig $unhealthyRollback.Transaction
        $script:installerActions.Clear()
        Assert-Throws { Start-ManagedServiceInstallerTransaction -Config $installerConfig -ExistingManagedDeploymentTransaction ([pscustomobject]@{ Manager = 'winsw' }) } 'requires its live deployment lock'
        Assert-True ($script:installerActions.Count -eq 0) 'Malformed borrowed transaction reached a guard, lock, or host mutation.'
    }
    & {
        Write-Host 'Uninstall serializes removal, drains monitoring, and checks runtime/task deletion before file cleanup'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        . Import-SourceFunctions 'scripts/windows/DeploymentLock.ps1'
        . Import-SourceFunctions 'scripts/windows/Uninstall-NodeService.ps1'
        $uninstallRoot = Join-Path $fixtureRoot 'uninstall-coordination'
        $uninstallConfig = [pscustomobject]@{
            AppName = 'UninstallFixture'; ServiceManager = 'winsw'
            ServiceDirectory = (Join-Path $uninstallRoot 'control')
            DeploymentLockDirectory = (Join-Path $uninstallRoot 'locks')
        }
        New-Item -ItemType Directory -Path $uninstallConfig.ServiceDirectory -Force | Out-Null
        $healthCleanupTarget = Get-HealthTaskDirectory $uninstallConfig
        $healthCleanupRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'node-enterprise-deploy-kit\healthchecks'))
        Assert-True ($healthCleanupTarget.StartsWith(($healthCleanupRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) 'Managed task recursive-delete path was not a canonical strict child of its private healthchecks root.'
        foreach ($unsafeName in @('.', '..', '../other', 'app/other', 'UninstallFixture.', 'NUL.task')) { Assert-Throws { Get-HealthTaskDirectory ([pscustomobject]@{ AppName = $unsafeName }) } 'AppName' }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Assert-True ((Get-UninstallScExecutablePath) -eq (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'sc.exe')) 'Native uninstall SCM command was not pinned to the Windows system executable.'
        }
        function Get-UninstallScExecutablePath { return (Join-Path $uninstallRoot 'trusted-system-sc.exe') }
        $script:uninstallActions = [System.Collections.Generic.List[string]]::new()
        function Reset-UninstallFixture {
            $script:uninstallActions.Clear()
            $script:uninstallServiceExists = $true
            $script:uninstallDeleteFails = $false
            $script:uninstallAbsenceQueryFails = $false
            $script:uninstallTaskRemovalFails = $false
            $script:uninstallTaskSurvives = $false
            $script:uninstallTaskExists = $true
            $script:uninstallNative = [pscustomobject]@{
                Name = $uninstallConfig.AppName; StartMode = 'Auto'
                PathName = ('"' + (Join-Path $uninstallConfig.ServiceDirectory "$($uninstallConfig.AppName).exe") + '"')
            }
            $script:uninstallController = [pscustomobject]@{ Status = 'Running' }
            $script:uninstallController | Add-Member ScriptMethod WaitForStatus {
                param($Status, $Timeout)
                Assert-True ([string]$this.Status -eq [string]$Status) 'Uninstall did not stop runtime before waiting for stopped state.'
            }
            $script:uninstallTask = [pscustomobject]@{ State = 'Running'; Settings = [pscustomobject]@{ Enabled = $true } }
        }
        function Set-ProtectedDeploymentLockDirectoryAcl { param($Path) }
        function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) if ($script:uninstallServiceExists) { return $script:uninstallNative } }
        function Invoke-CimMethod {
            [CmdletBinding()] param($InputObject, $MethodName, $Arguments)
            $script:uninstallActions.Add("mode:$($Arguments.StartMode)")
            $InputObject.StartMode = [string]$Arguments.StartMode
            return [pscustomobject]@{ ReturnValue = 0 }
        }
        function Get-Service {
            [CmdletBinding()] param($Name)
            if ($script:uninstallServiceExists) { return $script:uninstallController }
            if ($script:uninstallAbsenceQueryFails) { throw 'fixture SCM absence query denied' }
        }
        function Stop-Service {
            [CmdletBinding()] param($Name, [switch]$Force)
            Assert-Throws { Enter-DeploymentLock -Config $uninstallConfig -SkipAclHardening } 'Another deployment is already active'
            Assert-True (-not $script:uninstallTask.Settings.Enabled -and $script:uninstallTask.State -ne 'Running') 'Runtime removal started before the monitor was disabled and drained.'
            $script:uninstallActions.Add('stop-runtime'); $script:uninstallController.Status = 'Stopped'
        }
        function Invoke-NativeCommand {
            param($FilePath, $Arguments, $Label, [switch]$IgnoreExitCode)
            Assert-True ($FilePath -eq (Get-UninstallScExecutablePath) -and ($Arguments -join ',') -eq "delete,$($uninstallConfig.AppName)" -and -not $IgnoreExitCode) 'Uninstall ran an untrusted wrapper/PATH executable or ignored SCM deletion errors.'
            $script:uninstallActions.Add('delete-runtime')
            if ($script:uninstallDeleteFails) { throw 'fixture SCM deletion denied' }
            $script:uninstallServiceExists = $false
        }
        function Get-ScheduledTask { [CmdletBinding()] param($TaskName) if ($script:uninstallTaskExists) { return $script:uninstallTask } }
        function Disable-ScheduledTask { [CmdletBinding()] param($TaskName) $script:uninstallActions.Add('disable-monitor'); $script:uninstallTask.Settings.Enabled = $false }
        function Stop-ScheduledTask { [CmdletBinding()] param($TaskName) $script:uninstallActions.Add('drain-monitor'); $script:uninstallTask.State = 'Disabled' }
        function Enable-ScheduledTask { [CmdletBinding()] param($TaskName) $script:uninstallActions.Add('enable-monitor'); $script:uninstallTask.Settings.Enabled = $true; $script:uninstallTask.State = 'Ready' }
        function Unregister-ScheduledTask {
            [CmdletBinding(SupportsShouldProcess=$true)] param($TaskName)
            $script:uninstallActions.Add('delete-monitor')
            if ($script:uninstallTaskRemovalFails) { throw 'fixture task removal denied' }
            if (-not $script:uninstallTaskSurvives) { $script:uninstallTaskExists = $false }
        }
        function Remove-ManagedHealthTaskDirectory {
            param($Config)
            Assert-True (-not $script:uninstallTaskExists) 'Private task files were removed while the task registration still existed.'
            $script:uninstallActions.Add('delete-private-files')
        }
        $uninstallAst = Get-SourceAst 'scripts/windows/Uninstall-NodeService.ps1'
        $script:uninstallMutation = @($uninstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Quiesce managed monitor and uninstall runtime under the app deployment lock')
        })[0].Extent.Text
        function Invoke-UninstallFixture {
            [CmdletBinding(SupportsShouldProcess=$true)] param([switch]$RemoveHealthCheckTask)
            $config = $uninstallConfig; $serviceManager = $uninstallConfig.ServiceManager; $resolvedNssmPath = 'untrusted caller path.exe'
            Invoke-Expression $script:uninstallMutation
        }
        function Assert-UninstallLeaseReleased {
            $proof = Enter-DeploymentLock -Config $uninstallConfig -SkipAclHardening
            Exit-DeploymentLock $proof
        }

        Reset-UninstallFixture
        Invoke-UninstallFixture
        Assert-True (($script:uninstallActions -join ',') -eq 'disable-monitor,drain-monitor,mode:Disabled,stop-runtime,delete-runtime' -and -not $script:uninstallServiceExists -and -not $script:uninstallTask.Settings.Enabled) 'Successful uninstall did not quiesce the monitor before checked SCM removal, or re-enabled a monitor for the removed runtime.'
        Assert-UninstallLeaseReleased

        Reset-UninstallFixture; $script:uninstallDeleteFails = $true
        Assert-Throws { Invoke-UninstallFixture } 'fixture SCM deletion denied'
        Assert-True ($script:uninstallServiceExists -and $script:uninstallNative.StartMode -eq 'Automatic' -and $script:uninstallTask.Settings.Enabled -and ($script:uninstallActions -join ',') -eq 'disable-monitor,drain-monitor,mode:Disabled,stop-runtime,delete-runtime,mode:Automatic,enable-monitor') 'Caught deletion failure did not restore the previous startup policy and enabled monitor, or deleted private files.'
        Assert-UninstallLeaseReleased

        Reset-UninstallFixture; $script:uninstallAbsenceQueryFails = $true
        Assert-Throws { Invoke-UninstallFixture -RemoveHealthCheckTask } 'fixture SCM absence query denied'
        Assert-True (-not $script:uninstallServiceExists -and $script:uninstallTaskExists -and -not $script:uninstallTask.Settings.Enabled -and -not ($script:uninstallActions -contains 'delete-private-files')) 'SCM absence-query failure was treated as verified removal or re-enabled the monitor for a deleted runtime.'
        Assert-UninstallLeaseReleased

        Reset-UninstallFixture; $script:uninstallNative.PathName = 'C:\\unrelated\\service.exe'
        Assert-Throws { Invoke-UninstallFixture } 'belongs to a different executable'
        Assert-True ($script:uninstallActions.Count -eq 0 -and $script:uninstallServiceExists -and $script:uninstallTask.Settings.Enabled) 'Uninstall changed an unrelated service or its task before ownership validation.'
        Assert-UninstallLeaseReleased

        Reset-UninstallFixture
        $pendingUninstall = Join-Path $uninstallConfig.DeploymentLockDirectory "$($uninstallConfig.AppName).123.managed-transaction.pending"
        New-Item -ItemType Directory -Path $pendingUninstall | Out-Null
        Assert-Throws { Invoke-UninstallFixture } 'Unresolved deployment recovery state'
        Assert-True ($script:uninstallActions.Count -eq 0 -and $script:uninstallTask.Settings.Enabled) 'Uninstall mutated runtime/task state despite unresolved recovery evidence.'
        Remove-Item -LiteralPath $pendingUninstall
        Assert-UninstallLeaseReleased

        Reset-UninstallFixture
        Invoke-UninstallFixture -WhatIf
        Assert-True ($script:uninstallActions.Count -eq 0 -and $script:uninstallServiceExists -and $script:uninstallTask.Settings.Enabled) 'WhatIf uninstall changed service or monitor state.'
        foreach ($failure in @('denied', 'survives')) {
            Reset-UninstallFixture
            $script:uninstallTaskRemovalFails = ($failure -eq 'denied'); $script:uninstallTaskSurvives = ($failure -eq 'survives')
            $expected = if ($failure -eq 'denied') { 'fixture task removal denied' } else { 'Health task survived uninstall removal' }
            Assert-Throws { Invoke-UninstallFixture -RemoveHealthCheckTask } $expected
            Assert-True (-not $script:uninstallServiceExists -and $script:uninstallTaskExists -and -not $script:uninstallTask.Settings.Enabled -and -not ($script:uninstallActions -contains 'delete-private-files')) 'Failed task removal deleted recovery files or re-enabled monitoring after runtime removal.'
            Assert-UninstallLeaseReleased
        }
        Reset-UninstallFixture
        Invoke-UninstallFixture -RemoveHealthCheckTask
        Assert-True (-not $script:uninstallServiceExists -and -not $script:uninstallTaskExists -and ($script:uninstallActions -join ',') -eq 'disable-monitor,drain-monitor,mode:Disabled,stop-runtime,delete-runtime,delete-monitor,delete-private-files') 'Complete uninstall did not verify task absence before private-file cleanup.'
        Assert-UninstallLeaseReleased
    }
    & {
        Write-Host 'PM2 uninstall forces an empty persisted dump so the last deleted process cannot resurrect'
        . Import-SourceFunctions 'scripts/windows/DeploymentLock.ps1'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        . Import-SourceFunctions 'scripts/windows/Uninstall-NodeService.ps1'
        $pm2UninstallRoot = Join-Path $fixtureRoot 'pm2-uninstall-dump'
        $pm2UninstallConfig = [pscustomobject]@{ AppName = 'LastPm2Fixture'; ServiceManager = 'pm2'; ServiceDirectory = $pm2UninstallRoot; DeploymentLockDirectory = (Join-Path $pm2UninstallRoot 'locks') }
        $pm2UninstallHome = Join-Path $pm2UninstallRoot 'home'
        New-Item -ItemType Directory -Path $pm2UninstallHome -Force | Out-Null
        $pm2UninstallDump = Join-Path $pm2UninstallHome 'dump.pm2'
        $pm2UninstallEcosystem = Join-Path $pm2UninstallRoot "$($pm2UninstallConfig.AppName).pm2.config.cjs"
        [IO.File]::WriteAllText($pm2UninstallEcosystem, 'previous PM2 ecosystem')
        $script:pm2UninstallLive = @()
        $script:pm2UninstallCommands = [System.Collections.Generic.List[string]]::new()
        $script:pm2UninstallContextCalls = 0
        function Get-WindowsPm2RuntimeContext { param($Config) $script:pm2UninstallContextCalls++; return [pscustomobject]@{ Home = $pm2UninstallHome; CommandName = 'Invoke-UninstallPm2FakeCli' } }
        function Assert-WindowsPm2ExecutionAllowed { param($Pm2HomePath, $ExpectedOwnerSid) Assert-True ($Pm2HomePath -eq $pm2UninstallHome) 'PM2 uninstall queried a different daemon home.' }
        function Assert-WindowsServiceSecurityNoReparse { param($Path) }
        function Set-ProtectedDeploymentLockDirectoryAcl { param($Path) }
        $script:pm2UninstallMonitorQueries = 0
        function Get-ManagedScheduledTaskIfPresent { param($TaskName) $script:pm2UninstallMonitorQueries++; throw 'Unexpected monitor query before ambiguous PM2 identity refusal.' }
        function New-Pm2SelectorFixtureEntry {
            param([string]$Name, $ProcessId, [string]$ExecPath = '', [string]$Namespace = '')
            return [pscustomobject]@{ name = $Name; pm_id = $ProcessId; pm2_env = [pscustomobject]@{ name = $Name; pm_exec_path = $ExecPath; namespace = $Namespace; status = 'online' } }
        }
        function Invoke-UninstallPm2FakeCli {
            param([string]$Command, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Tail)
            Assert-True ($env:PM2_HOME -eq $pm2UninstallHome) 'PM2 uninstall command escaped its pinned daemon home.'
            $global:LASTEXITCODE = 0
            $commandRecord = if ($Tail) { (@($Command) + @($Tail)) -join ',' } else { $Command }
            $script:pm2UninstallCommands.Add($commandRecord)
            switch ($Command) {
                'delete' {
                    # Model PM2's real precedence even for numeric arguments:
                    # exact name/exec path, then namespace, then process ID.
                    $selectorPath = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Tail[0]))
                    $targets = @($script:pm2UninstallLive | Where-Object { $_.name -ceq $Tail[0] -or $_.pm2_env.pm_exec_path -ceq $selectorPath })
                    if ($targets.Count -eq 0) { $targets = @($script:pm2UninstallLive | Where-Object { $_.pm2_env.namespace -ceq $Tail[0] }) }
                    if ($targets.Count -eq 0) { $targets = @($script:pm2UninstallLive | Where-Object { [string]$_.pm_id -ceq $Tail[0] }) }
                    $targetIds = @($targets | ForEach-Object { $_.pm_id })
                    $script:pm2UninstallLive = @($script:pm2UninstallLive | Where-Object { $targetIds -notcontains $_.pm_id })
                }
                'save' {
                    # PM2 preserves an existing dump when its live list is empty
                    # unless save receives --force. Model that successful no-op.
                    if ($script:pm2UninstallLive.Count -gt 0 -or $Tail -contains '--force') {
                        [IO.File]::WriteAllText($pm2UninstallDump, (ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress))
                    }
                }
                'jlist' { ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress }
                default { throw "Unexpected fake PM2 command: $Command" }
            }
        }
        function Invoke-Pm2UninstallFixture {
            [CmdletBinding(SupportsShouldProcess=$true)] param()
            Uninstall-Pm2Process $pm2UninstallConfig
        }
        $pm2UninstallAst = Get-SourceAst 'scripts/windows/Uninstall-NodeService.ps1'
        $script:pm2UninstallMutation = @($pm2UninstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Quiesce managed monitor and uninstall runtime under the app deployment lock')
        })[0].Extent.Text
        function Invoke-Pm2UninstallOuterFixture {
            [CmdletBinding(SupportsShouldProcess=$true)] param()
            $config = $pm2UninstallConfig; $serviceManager = 'pm2'; $RemoveHealthCheckTask = $false
            $pm2Preflight = Get-WindowsPm2RuntimeContext $config
            Invoke-Expression $script:pm2UninstallMutation
        }
        $previousPm2UninstallHome = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
        try {
            $env:PM2_HOME = $pm2UninstallHome
            [IO.File]::WriteAllText($pm2UninstallDump, '[{"name":"LastPm2Fixture"}]')
            Invoke-UninstallPm2FakeCli 'save'
            Assert-True ([IO.File]::ReadAllText($pm2UninstallDump).Contains('LastPm2Fixture')) 'The fake CLI did not reproduce PM2 empty-list unforced save retaining a stale dump.'
            $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7), (New-Pm2SelectorFixtureEntry 'OtherOwnerApp' 9))
            [IO.File]::WriteAllText($pm2UninstallDump, (ConvertTo-Json -InputObject $script:pm2UninstallLive -Compress))
            $previousOwnerDump = [IO.File]::ReadAllText($pm2UninstallDump)
            $script:pm2UninstallCommands.Clear()
            foreach ($selector in @('all', '-managed', '0', '01', '1.5', '.1', '1e3', '0x10', '0o10', '0b10', 'Infinity')) {
                $pm2UninstallConfig.AppName = $selector
                Assert-Throws { Invoke-Pm2UninstallFixture } 'AppName'
                Assert-Throws { Get-ManagedPm2Entries 'Invoke-UninstallPm2FakeCli' $selector $pm2UninstallHome } 'AppName'
                Assert-Throws { Get-ManagedPm2Snapshot $pm2UninstallConfig } 'AppName'
                Assert-Throws { Assert-ManagedDeploymentManagerTransition ([pscustomobject]@{ AppName = $selector; ServiceManager = 'pm2' }) } 'AppName'
                Assert-True ($script:pm2UninstallCommands.Count -eq 0 -and $script:pm2UninstallContextCalls -eq 0 -and $script:pm2UninstallLive.Count -eq 2 -and [IO.File]::ReadAllText($pm2UninstallDump) -eq $previousOwnerDump -and (Test-Path -LiteralPath $pm2UninstallEcosystem)) "PM2 selector '$selector' reached context/CLI or changed another app, its persisted dump, or generated files."
            }
            $pm2UninstallConfig.AppName = 'LastPm2Fixture'
            foreach ($collision in @(
                (New-Pm2SelectorFixtureEntry 'lastpm2fixture' 9),
                (New-Pm2SelectorFixtureEntry '7' 9),
                (New-Pm2SelectorFixtureEntry 'OtherOwnerApp' 9 '' '7'),
                (New-Pm2SelectorFixtureEntry 'OtherOwnerApp' 9 (Join-Path (Get-Location).ProviderPath '7'))
            )) {
                $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7), $collision)
                $beforeAmbiguity = ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress
                $script:pm2UninstallCommands.Clear()
                Assert-Throws { Invoke-Pm2UninstallFixture } $(if ($collision.name -ceq 'lastpm2fixture') { 'differently cased' } else { 'collides' })
                Assert-True (($script:pm2UninstallCommands -join ';') -eq 'jlist' -and (ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress) -ceq $beforeAmbiguity -and (Test-Path -LiteralPath $pm2UninstallEcosystem) -and [IO.File]::ReadAllText($pm2UninstallDump) -eq $previousOwnerDump) 'An ambiguous PM2 selector mutated runtime, dump, or ecosystem files.'
                $script:pm2UninstallCommands.Clear()
                Assert-Throws { Invoke-Pm2UninstallOuterFixture } $(if ($collision.name -ceq 'lastpm2fixture') { 'differently cased' } else { 'collides' })
                Assert-True ($script:pm2UninstallMonitorQueries -eq 0 -and ($script:pm2UninstallCommands -join ';') -eq 'jlist' -and (ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress) -ceq $beforeAmbiguity) 'Public uninstall touched the shared Windows monitor or runtime before PM2 identity validation under its app lock.'
                $releasedUninstallLease = Enter-DeploymentLock -Config $pm2UninstallConfig -SkipAclHardening
                Exit-DeploymentLock $releasedUninstallLease
            }
            foreach ($invalidId in @($null, '7', -1, 1.5, $true, [double]::NaN, 9007199254740992)) {
                $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' $invalidId))
                $script:pm2UninstallCommands.Clear()
                Assert-Throws { Invoke-Pm2UninstallFixture } 'PM2 process ID'
                Assert-True (($script:pm2UninstallCommands -join ';') -eq 'jlist' -and (Test-Path -LiteralPath $pm2UninstallEcosystem)) 'Malformed PM2 process ID reached deletion or control-file removal.'
            }
            $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7))
            $script:pm2UninstallLive[0].PSObject.Properties.Remove('pm_id')
            Assert-Throws { Invoke-Pm2UninstallFixture } 'missing its numeric process ID'
            $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7))
            $script:pm2UninstallLive[0].pm2_env.name = 'ForeignName'
            Assert-Throws { Invoke-Pm2UninstallFixture } 'inconsistent process names'
            $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7), (New-Pm2SelectorFixtureEntry 'OtherOwnerApp' 7))
            Assert-Throws { Invoke-Pm2UninstallFixture } 'duplicate process IDs'
            Assert-True (@(Get-WindowsPm2ExactProcessIds -Entries @() -AppName 'LastPm2Fixture').Count -eq 0) 'A truly absent PM2 entry was not reported as absent.'
            $script:pm2UninstallLive = @(
                (New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 7),
                (New-Pm2SelectorFixtureEntry 'LastPm2Fixture' 8),
                (New-Pm2SelectorFixtureEntry 'ForeignPath' 9 (Join-Path (Get-Location).ProviderPath 'LastPm2Fixture')),
                (New-Pm2SelectorFixtureEntry 'ForeignNamespace' 10 '' 'LastPm2Fixture')
            )
            $foreignUninstallState = ConvertTo-Json -InputObject @($script:pm2UninstallLive | Select-Object -Skip 2) -Depth 8 -Compress
            $script:pm2UninstallCommands.Clear()
            Invoke-Pm2UninstallFixture
            Assert-True (($script:pm2UninstallCommands -join ';') -eq 'jlist;delete,7;delete,8;save,--force;jlist' -and (ConvertTo-Json -InputObject $script:pm2UninstallLive -Depth 8 -Compress) -ceq $foreignUninstallState -and [IO.File]::ReadAllText($pm2UninstallDump) -ceq $foreignUninstallState) 'Cluster uninstall deleted or changed an unrelated same-path/namespace app, or failed to persist the remaining apps.'
            [IO.File]::WriteAllText($pm2UninstallEcosystem, 'previous PM2 ecosystem')
            $script:pm2UninstallLive = @((New-Pm2SelectorFixtureEntry $pm2UninstallConfig.AppName 7))
            $script:pm2UninstallCommands.Clear()
            $env:PM2_HOME = 'previous daemon environment'
            Invoke-Pm2UninstallFixture
            Assert-True ($script:pm2UninstallLive.Count -eq 0 -and [IO.File]::ReadAllText($pm2UninstallDump) -eq '[]' -and ($script:pm2UninstallCommands -join ';') -eq 'jlist;delete,7;save,--force;jlist') "Last-process uninstall left a stale persisted dump or failed to verify the empty live process list. Dump: $([IO.File]::ReadAllText($pm2UninstallDump)); commands: $($script:pm2UninstallCommands -join ';')"
            Assert-True (-not (Test-Path -LiteralPath $pm2UninstallEcosystem) -and $env:PM2_HOME -eq 'previous daemon environment') 'PM2 uninstall did not remove its generated ecosystem after verification or restore the caller environment.'
        } finally { [Environment]::SetEnvironmentVariable('PM2_HOME', $previousPm2UninstallHome, 'Process') }
    }
    & {
        Write-Host 'Standalone package import holds an app lease and retains persistent state on failed recovery'
        . Import-SourceFunctions 'scripts/windows/DeploymentTransaction.ps1'
        . Import-SourceFunctions 'scripts/windows/DeploymentLock.ps1'
        . Import-SourceFunctions 'scripts/windows/AppPackageLifecycle.ps1'
        . Import-SourceFunctions 'scripts/windows/Import-AppPackage.ps1'
        $importRoot = Join-Path $fixtureRoot 'import-lock'
        $importConfig = [pscustomobject]@{
            AppName = 'PackageImportFixture'; ServiceManager = 'none'; DeploymentMode = ''; AppFramework = 'node'
            AppDirectory = (Join-Path $importRoot 'app'); DeploymentLockDirectory = (Join-Path $importRoot 'locks')
        }
        $importSource = Join-Path $importRoot 'source'
        $importBackups = Join-Path $importRoot 'backups'
        New-Item -ItemType Directory -Path $importSource, $importConfig.AppDirectory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $importSource 'server.js'), 'new package bytes')
        [IO.File]::WriteAllText((Join-Path $importConfig.AppDirectory 'server.js'), 'old package bytes')
        $script:importManifestFails = $false
        $script:importDirectoryRecoveryFails = $false
        $script:importRuntimeExists = $false
        $script:importRuntimeWasRunning = $false
        $script:importServiceActions = [System.Collections.Generic.List[string]]::new()
        $script:observedImportMarkers = [System.Collections.Generic.List[object]]::new()
        function Set-ProtectedDeploymentLockDirectoryAcl { param($Path) }
        function Get-AppPackageServiceState { param($Config) return [pscustomobject]@{ Kind = 'windows-service'; Name = $Config.AppName; CommandName = ''; Exists = $script:importRuntimeExists; WasRunning = $script:importRuntimeWasRunning } }
        function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) return $null }
        function Stop-AppPackageService { param($State) $script:importServiceActions.Add('stop') }
        function Start-AppPackageServiceAfterFailure { param($State) $script:importServiceActions.Add('restart') }
        function Write-DeploymentManifest {
            param($Config, $AppDirectory, $PackageName, $PackageSha256, $PackageProvenance)
            $marker = @(Get-PendingDeploymentRecoveryPaths -AppName $Config.AppName -LockDirectory $Config.DeploymentLockDirectory)
            Assert-True ($marker.Count -eq 1) 'Package content replacement began without a persistent prepared marker.'
            $prepared = Get-Content -LiteralPath $marker[0] -Raw | ConvertFrom-Json
            Assert-True ($prepared.phase -eq 'prepared' -and $prepared.previousAppExisted -and (Test-Path -LiteralPath $prepared.backupPath)) 'Prepared marker did not describe the exact existing app backup before replacement manifest write.'
            $script:observedImportMarkers.Add($prepared)
            Assert-Throws { Enter-DeploymentLock -Config $Config -SkipAclHardening } 'Another deployment is already active'
            if ($script:importManifestFails) { throw 'fixture imported manifest failure' }
        }
        function Move-Item {
            [CmdletBinding()] param($LiteralPath, $Path, $Destination, [switch]$Force)
            $from = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($script:importDirectoryRecoveryFails -and $from -like '*app.*.bak') { throw 'fixture backup restore failed' }
            Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
        }
        $importAst = Get-SourceAst 'scripts/windows/Import-AppPackage.ps1'
        $script:importMutation = @($importAst.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($PSCmdlet.ShouldProcess($appDirectory, "Import application package') }, $false))[0].Extent.Text
        function Invoke-ImportLeaseFixture {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param($ExistingDeploymentLock, $ExistingManagedDeploymentTransaction, [string]$TransactionStatePath = '')
            $config = $importConfig; $appDirectory = $importConfig.AppDirectory; $backupDirectory = $importBackups
            $sourceRoot = $importSource; $sourcePackagePath = 'fixture.zip'; $packageName = 'fixture.zip'; $verifiedPackageSha256 = 'fixture digest'; $packageProvenance = $null
            Invoke-Expression $script:importMutation
        }
        foreach ($wasRunning in @($true, $false)) {
            $script:importRuntimeExists = $true; $script:importRuntimeWasRunning = $wasRunning
            Assert-Throws { Invoke-ImportLeaseFixture } 'A managed runtime already exists'
            Assert-True ([IO.File]::ReadAllText((Join-Path $importConfig.AppDirectory 'server.js')) -eq 'old package bytes' -and $script:importServiceActions.Count -eq 0 -and $script:observedImportMarkers.Count -eq 0) 'Standalone existing runtime rejection stopped/restarted the service or changed the application.'
        }
        $script:importRuntimeExists = $false; $script:importRuntimeWasRunning = $false
        $importConfig.DeploymentMode = 'static_iis'
        foreach ($sitePath in @($importConfig.AppDirectory, (Join-Path $importConfig.AppDirectory 'nested-site'), $importRoot)) {
            $importConfig | Add-Member NoteProperty IisSitePath $sitePath -Force
            Assert-Throws { Invoke-ImportLeaseFixture } 'Static package AppDirectory must be separate'
            Assert-True ([IO.File]::ReadAllText((Join-Path $importConfig.AppDirectory 'server.js')) -eq 'old package bytes' -and $script:importServiceActions.Count -eq 0) 'Static overlap rejection modified live content or the runtime.'
        }
        $importConfig.DeploymentMode = ''; $importConfig.PSObject.Properties.Remove('IisSitePath')
        Invoke-ImportLeaseFixture
        Assert-True ([IO.File]::ReadAllText((Join-Path $importConfig.AppDirectory 'server.js')) -eq 'new package bytes' -and @(Get-PendingDeploymentRecoveryPaths $importConfig.AppName $importConfig.DeploymentLockDirectory).Count -eq 0) 'Successful standalone import did not install bytes and commit its marker.'
        $parentImportLock = Enter-DeploymentLock -Config $importConfig -SkipAclHardening
        try {
            Invoke-ImportLeaseFixture -ExistingDeploymentLock $parentImportLock
            $borrowedMarker = @(Get-PendingDeploymentRecoveryPaths $importConfig.AppName $importConfig.DeploymentLockDirectory)
            Assert-True ($borrowedMarker.Count -eq 1 -and $parentImportLock.Stream.CanWrite) 'Borrowed importer committed its parent marker or disposed the parent lease.'
            Remove-Item -LiteralPath $borrowedMarker[0] -Force
        } finally { Exit-DeploymentLock $parentImportLock }
        $script:importManifestFails = $true
        Assert-Throws { Invoke-ImportLeaseFixture } 'fixture imported manifest failure'
        Assert-True ((Test-Path -LiteralPath $importConfig.AppDirectory -PathType Container) -and @(Get-PendingDeploymentRecoveryPaths $importConfig.AppName $importConfig.DeploymentLockDirectory).Count -eq 0) 'Confirmed standalone directory recovery kept a stale marker or lost the old app.'
        $script:importDirectoryRecoveryFails = $true
        Assert-Throws { Invoke-ImportLeaseFixture } 'fixture backup restore failed'
        $failedImportMarkers = @(Get-PendingDeploymentRecoveryPaths $importConfig.AppName $importConfig.DeploymentLockDirectory)
        Assert-True ($failedImportMarkers.Count -eq 1) 'Failed standalone directory recovery discarded the persistent package marker.'
        Assert-Throws { Enter-DeploymentLock -Config $importConfig -SkipAclHardening } 'Unresolved deployment recovery state'
        $retained = Get-Content -LiteralPath $failedImportMarkers[0] -Raw | ConvertFrom-Json
        Assert-True (Test-Path -LiteralPath $retained.backupPath -PathType Container) 'Failed import lost the previous app backup.'
        $script:importDirectoryRecoveryFails = $false
        Restore-AppPackageDirectoryFromBackup -AppDirectory $importConfig.AppDirectory -BackupPath $retained.backupPath -PreviousAppExisted $true
        Remove-Item -LiteralPath $failedImportMarkers[0] -Force
        $importConfig.PSObject.Properties.Remove('DeploymentMode'); $importConfig.PSObject.Properties.Remove('ServiceManager')
        Initialize-AppPackageImportConfig -Config $importConfig
        Assert-True ($importConfig.DeploymentMode -eq 'node_service' -and $importConfig.ServiceManager -eq 'winsw') 'Minimal file-only config did not receive property-safe rollback defaults.'
        Assert-Throws { Invoke-ImportLeaseFixture } 'fixture imported manifest failure'
        $minimalPrepared = $script:observedImportMarkers[$script:observedImportMarkers.Count - 1]
        Assert-AppPackageDeploymentTransactionState -Config $importConfig -TransactionState $minimalPrepared
        Assert-True ((Test-Path -LiteralPath $importConfig.AppDirectory -PathType Container) -and @(Get-PendingDeploymentRecoveryPaths $importConfig.AppName $importConfig.DeploymentLockDirectory).Count -eq 0) 'Minimal config import failure did not restore previous app and commit successful recovery.'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        & {
            Write-Host 'Direct IIS holds app before global IIS lock and authenticates native child borrowing'
            . (Join-Path $repoRoot 'scripts/windows/IisDeploymentState.ps1')
            $iisLockRoot = Join-Path $fixtureRoot 'iis-app-coordination'
            $iisConfig = [pscustomobject]@{ AppName = 'IisLockFixture'; DeploymentLockDirectory = (Join-Path $iisLockRoot 'locks'); IisSitePath = (Join-Path $iisLockRoot 'site'); ServiceManager = 'none' }
            New-Item -ItemType Directory -Path $iisConfig.IisSitePath -Force | Out-Null
            $iisWebConfig = Join-Path $iisConfig.IisSitePath 'web.config'
            [IO.File]::WriteAllText($iisWebConfig, 'previous private web config')
            $script:iisCoordinationActions = [System.Collections.Generic.List[string]]::new()
            $script:iisSnapshotFails = $false
            function Get-IisDeploymentControlDirectory { return (Join-Path $iisLockRoot 'control') }
            function Test-IisBothLeasesHeld {
                Assert-Throws { Enter-DeploymentLock -Config $iisConfig -SkipAclHardening } 'Another deployment is already active'
                $globalPath = Join-Path (Get-IisDeploymentControlDirectory) 'configuration.lock'
                Assert-Throws { [IO.File]::Open($globalPath, 'Open', 'ReadWrite', 'None').Dispose() } ''
            }
            function Get-IisManagedDeploymentState { param($Config) Test-IisBothLeasesHeld; $script:iisCoordinationActions.Add('save'); if ($script:iisSnapshotFails) { throw 'fixture IIS snapshot denied' }; return [pscustomobject]@{ Fixture = 'previous IIS state' } }
            function Restore-IisManagedDeploymentState { param($State) Test-IisBothLeasesHeld; $script:iisCoordinationActions.Add('restore') }
            function Invoke-NativeIisDeploymentState {
                param($Action, $Transaction, $Config)
                Assert-IisApplicationDeploymentLockLease -Config $iisConfig -LeasePath $Transaction.IisLockLeasePath -Token $Transaction.IisLockToken
                Test-IisBothLeasesHeld
                $script:iisCoordinationActions.Add($Action.ToLowerInvariant())
                if ($script:iisSnapshotFails) { throw 'fixture IIS snapshot denied' }
            }
            $iisOwned = Start-IisInstallerTransaction -Config $iisConfig
            Assert-True ($iisOwned.OwnsAppLock -and $iisOwned.OwnsLock -and $iisOwned.AppLock.Stream.CanWrite) 'Direct IIS did not own both app and global leases.'
            Assert-IisApplicationDeploymentLockLease $iisConfig $iisOwned.IisLockLeasePath $iisOwned.IisLockToken
            $iisChild = Start-IisInstallerTransaction -Config $iisConfig -LeasePath $iisOwned.IisLockLeasePath -Token $iisOwned.IisLockToken
            Complete-IisInstallerTransaction -Transaction $iisChild -Failed
            Assert-True (-not $iisChild.OwnsLock -and $iisOwned.AppLock.Stream.CanWrite -and (Test-Path -LiteralPath $iisOwned.Directory) -and $script:iisCoordinationActions.Count -eq 1) 'Native child completed or restored its parent before returning control.'
            $leaseRecord = Import-Clixml -LiteralPath $iisOwned.IisLockLeasePath
            $leaseRecord.AppName = 'DifferentApp'; $leaseRecord | Export-Clixml -LiteralPath $iisOwned.IisLockLeasePath
            Assert-Throws { Start-IisInstallerTransaction -Config $iisConfig -LeasePath $iisOwned.IisLockLeasePath -Token $iisOwned.IisLockToken } 'requires the protected application deployment lock lease'
            $leaseRecord.AppName = $iisConfig.AppName; $leaseRecord.OwnerStartTimeUtcTicks++; $leaseRecord | Export-Clixml -LiteralPath $iisOwned.IisLockLeasePath
            Assert-Throws { Start-IisInstallerTransaction -Config $iisConfig -LeasePath $iisOwned.IisLockLeasePath -Token $iisOwned.IisLockToken } 'owner process was replaced'
            $leaseRecord.OwnerStartTimeUtcTicks--; $leaseRecord | Export-Clixml -LiteralPath $iisOwned.IisLockLeasePath
            [IO.File]::WriteAllText($iisWebConfig, 'broken replacement web config')
            Complete-IisInstallerTransaction -Transaction $iisOwned -Failed
            Assert-True ([IO.File]::ReadAllText($iisWebConfig) -eq 'previous private web config' -and -not $iisOwned.AppLock.Stream.CanWrite -and -not (Test-Path -LiteralPath $iisOwned.Directory) -and ($script:iisCoordinationActions -join ',') -eq 'save,restore') 'Caught native child failure did not restore web/IIS state under both locks before releasing the source mutex.'
            $parentAppLock = Enter-DeploymentLock -Config $iisConfig
            try {
                $iisWithBorrowedApp = Start-IisInstallerTransaction -Config $iisConfig -ExistingDeploymentLock $parentAppLock
                Assert-True (-not $iisWithBorrowedApp.OwnsAppLock -and $iisWithBorrowedApp.OwnsLock) 'IIS failed to borrow an existing deployment mutex while owning its global transaction.'
                Complete-IisInstallerTransaction -Transaction $iisWithBorrowedApp
                Assert-True $parentAppLock.Stream.CanWrite 'Direct IIS disposed a borrowed app stream.'
            } finally { Exit-DeploymentLock $parentAppLock }
            $expiredApp = Start-IisInstallerTransaction -Config $iisConfig
            $expiredApp.AppLock.Stream.Dispose()
            Assert-Throws { Start-IisInstallerTransaction -Config $iisConfig -LeasePath $expiredApp.IisLockLeasePath -Token $expiredApp.IisLockToken } 'application deployment lease is no longer held'
            Complete-IisInstallerTransaction -Transaction $expiredApp
            $script:iisSnapshotFails = $true
            Assert-Throws { Start-IisInstallerTransaction -Config $iisConfig } 'fixture IIS snapshot denied'
            $script:iisSnapshotFails = $false
            $afterSnapshotFailure = Enter-DeploymentLock -Config $iisConfig
            Exit-DeploymentLock $afterSnapshotFailure
            Assert-True (@(Get-ChildItem -LiteralPath (Get-IisDeploymentControlDirectory) -Directory -Filter 'installer.*').Count -eq 0) 'Read-only IIS snapshot failure leaked its private journal.'
            $abandonedIis = Join-Path (Get-IisDeploymentControlDirectory) ('installer.' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $abandonedIis | Out-Null
            $actionsBeforePendingIis = $script:iisCoordinationActions.Count
            Assert-Throws { Start-IisInstallerTransaction -Config $iisConfig } 'Unresolved IIS installer recovery journal'
            Assert-True ((Test-Path -LiteralPath $abandonedIis) -and $script:iisCoordinationActions.Count -eq $actionsBeforePendingIis) 'An incomplete prior IIS journal was ignored/removed or host snapshot/mutation proceeded.'
            $afterIisPendingFailure = Enter-DeploymentLock -Config $iisConfig
            Exit-DeploymentLock $afterIisPendingFailure
            Remove-Item -LiteralPath $abandonedIis
        }
        & {
            Write-Host 'No-package identity rollback restores actual app/cache/log/control ACLs before SCM resume'
            . (Join-Path $repoRoot 'scripts/windows/DeploymentTransaction.ps1')
            $aclRoot = Join-Path $fixtureRoot 'actual-acl-recovery'
            $aclConfig = [pscustomobject]@{
                AppName = ('AclRecovery' + [Guid]::NewGuid().ToString('N'))
                AppDirectory = (Join-Path $aclRoot 'app'); ServiceDirectory = (Join-Path $aclRoot 'service')
                DeploymentLockDirectory = (Join-Path $aclRoot 'locks')
                LogDirectory = (Join-Path $aclRoot 'logs'); AppFramework = 'nextjs'; ServiceManager = 'winsw'
                ReverseProxy = 'none'; ServiceAccount = 'NetworkService'; PreviousServiceAccountPassword = 'fixture-previous-password'
                HealthUrl = 'http://127.0.0.1:12345/health'; SkipPackageImport = $true
            }
            $oldAccount = 'FIXTURE\PreviousNonAdmin'
            $oldSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
            $auditorSid = 'S-1-5-21-1111111111-2222222222-3333333333-1002'
            function Get-WindowsServiceSecuritySid {
                param([string]$Account)
                if ($Account -eq 'FIXTURE\PreviousNonAdmin') { return [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001') }
                switch ($Account) {
                    'NetworkService' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-20') }
                    'NT AUTHORITY\NetworkService' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-20') }
                    default { return ([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]) }
                }
            }
            # This host's token is not elevated. Keep a test-observer ACE and
            # owner solely on the temporary fixture; the old/new runtime SIDs
            # remain distinct, and every ACL mutation/restoration is real.
            $fixtureObserver = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $fixtureObserverSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $actualAclFactory = (Get-Command New-WindowsProtectedPathAcl).ScriptBlock
            function New-WindowsProtectedPathAcl {
                param([bool]$Directory, [string]$Account = '', [Security.AccessControl.FileSystemRights]$RuntimeRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute, [string]$OwnerAccount = '')
                $acl = & $actualAclFactory -Directory $Directory -Account $Account -RuntimeRights $RuntimeRights -OwnerAccount $fixtureObserver
                $inherit = if ($Directory) { [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit } else { [Security.AccessControl.InheritanceFlags]::None }
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($fixtureObserverSid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
                return $acl
            }
            function Set-ProtectedDeploymentLockDirectoryAcl {
                param($Path)
                Set-WindowsProtectedPathSecurity -Path $Path -Account $fixtureObserver -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $fixtureObserver
            }
            $cache = Join-Path $aclConfig.AppDirectory '.next/cache'
            New-Item -ItemType Directory -Path $cache, $aclConfig.ServiceDirectory, $aclConfig.LogDirectory -Force | Out-Null
            $code = Join-Path $aclConfig.AppDirectory 'server.js'
            $cacheFile = Join-Path $cache 'previous.cache'
            $logFile = Join-Path $aclConfig.LogDirectory 'previous.log'
            $wrapper = Join-Path $aclConfig.ServiceDirectory ($aclConfig.AppName + '.exe')
            $serviceXml = Join-Path $aclConfig.ServiceDirectory ($aclConfig.AppName + '.xml')
            foreach ($path in @($code, $cacheFile, $logFile, $wrapper, $serviceXml)) { [IO.File]::WriteAllText($path, 'fixture previous content') }
            Set-WindowsServiceFilesystemSecurity -Config $aclConfig -Account $oldAccount
            $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
            $customAcl = Get-Acl -LiteralPath $code
            $customAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($auditorSid), [Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.AccessControlType]::Allow))
            Restore-WindowsPathSecurity -Path $code -Sddl $customAcl.GetSecurityDescriptorSddlForm($sections)
            $definition = [pscustomobject]@{ Name = $aclConfig.AppName; PathName = ('"' + $wrapper + '"'); StartMode = 'Auto'; StartName = $oldAccount; DisplayName = 'Previous fixture'; State = 'Running' }
            $starts = [System.Collections.Generic.List[string]]::new()
            function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) return $definition }
            function Invoke-CimMethod {
                [CmdletBinding()] param($InputObject, $MethodName, $Arguments)
                foreach ($key in $Arguments.Keys) { if ($key -ne 'StartPassword') { $InputObject.$key = $Arguments[$key] } }
                return [pscustomobject]@{ ReturnValue = 0 }
            }
            function Get-Service {
                [CmdletBinding()] param($Name)
                $record = [pscustomobject]@{ Status = $(if ($definition.State -eq 'Running') { 'Running' } else { 'Stopped' }) }
                $record | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
                return $record
            }
            function Stop-Service { [CmdletBinding()] param($Name, [switch]$Force) $definition.State = 'Stopped' }
            function Start-Service {
                [CmdletBinding()] param($Name)
                foreach ($entry in @($securitySnapshot.Entries)) {
                    if (Test-Path -LiteralPath $entry.Path) { Assert-True ((Get-Acl -LiteralPath $entry.Path).GetSecurityDescriptorSddlForm($sections) -eq $entry.Sddl) ('SCM resume happened before exact prior ACL restoration: ' + $entry.Path) }
                }
                $starts.Add($Name); $definition.State = 'Running'
            }
            function Get-ManagedServiceRecoveryConfiguration { param($Name) return [pscustomobject]@{ Fixture = 'previous recovery' } }
            function Restore-ManagedServiceRecoveryConfiguration { param($Name, $Configuration) }
            function Get-ScheduledTask { [CmdletBinding()] param($TaskName) return $null }
            function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess=$true)] param($TaskName) }
            function Test-PostDeployHealth { param($Config) Assert-True ($definition.State -eq 'Running') 'Rollback HTTP validation occurred before runtime resume.' }
            $actualLock = Enter-DeploymentLock -Config $aclConfig
            try {
                $aclTransaction = Start-ManagedDeploymentTransaction -Config $aclConfig -Lock $actualLock
                $securitySnapshot = Import-Clixml -LiteralPath $aclTransaction.FilesystemSecuritySnapshot
                Assert-True (@($securitySnapshot.Entries.Path | Select-Object -Unique).Count -eq @($securitySnapshot.Entries).Count) 'Overlapping service/backup/cache roots produced duplicate ACL records.'
                Assert-True (@($securitySnapshot.Entries | Where-Object { Test-WindowsServiceSecurityPathWithin -Path $_.Path -Root (Get-DeploymentLockDirectory $aclConfig) }).Count -eq 0) 'ACL snapshot traversed the held lock or its new protected recovery journal.'
                Suspend-ManagedDeploymentServiceState -Config $aclConfig -Transaction $aclTransaction
                Set-WindowsServiceFilesystemSecurity -Config $aclConfig -Account NetworkService
                $replacementSids = @((Get-Acl -LiteralPath $code).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
                Assert-True ($replacementSids -notcontains $oldSid -and $replacementSids -contains 'S-1-5-20') 'Fixture did not actually remove old nonadmin runtime access during identity change.'
                $definition.StartName = 'NT AUTHORITY\NetworkService'
                [IO.File]::WriteAllText($serviceXml, 'broken replacement control bytes')
                $introducedCode = Join-Path $aclConfig.AppDirectory 'introduced-runtime.data'
                $introducedLog = Join-Path $aclConfig.LogDirectory 'introduced.log'
                $introducedBackup = Join-Path (Join-Path $aclConfig.ServiceDirectory 'backups') 'new-private-secret.bak'
                foreach ($path in @($introducedCode, $introducedLog)) { [IO.File]::WriteAllText($path, 'fixture'); Set-WindowsProtectedPathSecurity -Path $path -Account NetworkService }
                [IO.File]::WriteAllText($introducedBackup, 'fixture-only secret'); Set-WindowsProtectedFileSecurity -Path $introducedBackup
                Restore-ManagedDeploymentTransaction -Config $aclConfig -Transaction $aclTransaction
                Assert-True ($definition.StartName -eq $oldAccount -and $definition.State -eq 'Stopped' -and $starts.Count -eq 0) 'ACL recovery resumed the old SCM identity before validating prior access.'
                foreach ($entry in @($securitySnapshot.Entries)) {
                    Assert-True ((Get-Acl -LiteralPath $entry.Path).GetSecurityDescriptorSddlForm($sections) -eq $entry.Sddl) ('No-package rollback lost original DACL/owner/group/protection: ' + $entry.Path)
                }
                foreach ($path in @($introducedCode, $introducedLog)) {
                    $sids = @((Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
                    Assert-True ($sids -contains $oldSid -and $sids -notcontains 'S-1-5-20') 'New app/log object retained only replacement-account access after rollback.'
                }
                $privateSids = @((Get-Acl -LiteralPath $introducedBackup).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
                Assert-True ($privateSids -notcontains $oldSid -and $privateSids -notcontains 'S-1-5-20') 'Rollback exposed a newly introduced private backup to runtime identities.'
                Resume-ManagedDeploymentServiceState -Config $aclConfig -Transaction $aclTransaction
                Assert-True ($starts.Count -eq 1 -and $definition.State -eq 'Running') 'Restored nonadmin SCM identity was not resumed after ACL recovery.'
                Complete-ManagedDeploymentTransaction -Config $aclConfig -Transaction $aclTransaction
                $outside = Join-Path $aclRoot 'outside'
                $junction = Join-Path $aclConfig.AppDirectory 'unsafe-junction'
                New-Item -ItemType Directory -Path $outside -Force | Out-Null
                $junctionCreated = $false
                try { New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop | Out-Null; $junctionCreated = $true }
                catch {
                    $junctionError = $_.Exception
                    while ($junctionError.InnerException) { $junctionError = $junctionError.InnerException }
                    if ($junctionError -isnot [UnauthorizedAccessException] -and -not ($junctionError -is [ComponentModel.Win32Exception] -and $junctionError.NativeErrorCode -eq 5)) { throw }
                    Write-Host 'Native junction creation denied; existing source fixtures cover reparse metadata.'
                }
                if ($junctionCreated) {
                    try { Assert-Throws { Get-ManagedDeploymentSecurityTreeItems -Roots @($aclConfig.AppDirectory) } 'Refusing managed ACL traversal through a reparse point' }
                    finally { Remove-Item -LiteralPath $junction -Force }
                }
            } finally { Exit-DeploymentLock -Lock $actualLock }
        }
    }
    Write-Host "Windows production safety behavioral checks passed."
} catch {
    Write-Host "Production safety fixture failed: $($_.Exception.Message). $($_.ScriptStackTrace)"
    throw
} finally {
    $fixtureIisRegistry = Get-Variable -Name NodeDeployKitIisDeploymentLocks -Scope Global -ErrorAction SilentlyContinue
    if ($fixtureIisRegistry) {
        foreach ($key in @($fixtureIisRegistry.Value.Keys)) {
            if ($fixtureIisRegistry.Value[$key].Name.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase)) { $fixtureIisRegistry.Value[$key].Dispose(); $fixtureIisRegistry.Value.Remove($key) }
        }
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    $workspacePrefix = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing fixture cleanup outside the repository: $resolvedFixture"
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
