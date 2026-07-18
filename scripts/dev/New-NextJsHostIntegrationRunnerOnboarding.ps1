param(
  [string]$MatrixPath = '',
  [string[]]$TargetId = @(),
  [string]$ServiceManager = '',
  [string]$ReverseProxy = '',
  [string]$RepositoryUrl = 'https://github.com/Yunushan/node-enterprise-deploy-kit',
  [string]$OutputPath = '',
  [ValidateSet('Json', 'Markdown')]
  [string]$Format = 'Markdown',
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  (($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Get-WorkflowPlatform {
  param([string]$Category)
  if ($Category -in @('windows-client', 'windows-server')) { return 'windows' }
  if ($Category -in @('linux', 'macos')) { return 'unix' }
  return ''
}

function New-RunnerProfile {
  param([object]$Target, [string]$ServiceManager, [string]$ReverseProxy, [string]$RepositoryUrl)
  $targetId = Normalize-Token ([string]$Target.id)
  $manager = Normalize-Token $ServiceManager
  $proxy = Normalize-Token $ReverseProxy
  $platform = Get-WorkflowPlatform ([string]$Target.category)
  if (-not $platform) { throw "Target '$targetId' is not workflow-capable." }
  $labels = @('self-hosted', $targetId, "nextjs-manager-$manager", "nextjs-proxy-$proxy")
  $preflight = if ($platform -eq 'windows') {
    "node scripts/dev/Test-NextJsHostIntegrationPrerequisites.mjs --platform windows --manager $manager --proxy $proxy"
  } else {
    "node scripts/dev/Test-NextJsHostIntegrationPrerequisites.mjs --platform unix --manager $manager --proxy $proxy"
  }
  $runnerName = "nextjs-$targetId-$manager-$proxy"
  $labelList = $labels -join ','
  $registrationCommands = if ($platform -eq 'windows') {
    @(
      ".\config.cmd --unattended --url $RepositoryUrl --token <issued-token> --name $runnerName --labels $labelList",
      '.\svc install',
      '.\svc start'
    )
  } else {
    @(
      "./config.sh --unattended --url $RepositoryUrl --token <issued-token> --name $runnerName --labels $labelList",
      'sudo ./svc.sh install',
      'sudo ./svc.sh start'
    )
  }
  [pscustomobject]@{
    targetId = $targetId
    targetName = [string]$Target.name
    platform = $platform
    serviceManager = $manager
    reverseProxy = $proxy
    labels = $labels
    runnerName = $runnerName
    registrationCommands = $registrationCommands
    minimumNodeVersion = [string]$Target.nodeRuntimeSupport.minimumNodeVersion
    preflightCommand = $preflight
    administratorRequired = $platform -eq 'windows'
    passwordlessSudoRequired = $platform -eq 'unix'
    nssmPathRequired = $manager -eq 'nssm'
    iisModulesRequired = $proxy -eq 'iis'
  }
}

function ConvertTo-OnboardingMarkdown {
  param([object]$Document)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Next.js Native Runner Onboarding') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Prepare a dedicated verification host or approved non-production test node that exactly matches the target platform. The native workflow creates and removes temporary services and proxy configuration; do not attach these labels to an unrelated production workload host.') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Download the GitHub Actions runner through the repository Settings > Actions > Runners flow. The commands below require a short-lived registration token issued there; this artifact never creates or prints one.') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('For a runner behind corporate HTTPS inspection, repair the operating-system trust store and configure the runner Node.js process with `NODE_OPTIONS=--use-system-ca`. Do not bypass verification with `npm config set strict-ssl false` or `NODE_TLS_REJECT_UNAUTHORIZED=0`.') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($profile in @($Document.profiles)) {
    $lines.Add("## $($profile.targetId) / $($profile.serviceManager) / $($profile.reverseProxy)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("- Platform: $($profile.platform)") | Out-Null
    $lines.Add("- Node.js floor: $($profile.minimumNodeVersion)") | Out-Null
    $lines.Add("- Runner labels: ``$($profile.labels -join '`, `')``") | Out-Null
    $lines.Add('- Register the downloaded runner and install its service:') | Out-Null
    $lines.Add('```') | Out-Null
    foreach ($command in @($profile.registrationCommands)) { $lines.Add($command) | Out-Null }
    $lines.Add('```') | Out-Null
    if ($profile.administratorRequired) {
      $lines.Add('- Runner requirement: run the Windows runner service as Administrator.') | Out-Null
    } else {
      $lines.Add('- Runner requirement: provide passwordless `sudo` for temporary service and proxy validation.') | Out-Null
    }
    if ($profile.nssmPathRequired) {
      $lines.Add('- NSSM requirement: set `NSSM_PATH` to an approved readable `nssm.exe` before registering this capability label.') | Out-Null
    }
    if ($profile.iisModulesRequired) {
      $lines.Add('- IIS requirement: install IIS WebAdministration, URL Rewrite, and Application Request Routing before registering this capability label.') | Out-Null
    }
    $lines.Add('- After checkout, run this non-mutating prerequisite check:') | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add($profile.preflightCommand) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add('') | Out-Null
  }
  ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Invoke-SelfTest {
  $matrix = [pscustomobject]@{
    targets = @(
      [pscustomobject]@{
        id = 'windows-server-2022'; name = 'Windows Server 2022'; category = 'windows-server'
        serviceManagers = @('winsw'); reverseProxies = @('iis')
        nodeRuntimeSupport = [pscustomobject]@{ minimumNodeVersion = '20.9.0' }
      },
      [pscustomobject]@{
        id = 'ubuntu'; name = 'Ubuntu'; category = 'linux'
        serviceManagers = @('systemd', 'systemv'); reverseProxies = @('nginx')
        nodeRuntimeSupport = [pscustomobject]@{ minimumNodeVersion = '20.9.0' }
      }
    )
  }
  $repositoryUrl = 'https://github.com/example/repository'
  $windows = New-RunnerProfile -Target $matrix.targets[0] -ServiceManager 'winsw' -ReverseProxy 'iis' -RepositoryUrl $repositoryUrl
  if (($windows.labels -join ',') -ne 'self-hosted,windows-server-2022,nextjs-manager-winsw,nextjs-proxy-iis' -or -not $windows.administratorRequired -or -not $windows.iisModulesRequired) {
    throw 'Runner onboarding self-test did not create the required Windows capability labels.'
  }
  $nssm = New-RunnerProfile -Target ([pscustomobject]@{ id = 'windows-11'; name = 'Windows 11'; category = 'windows-client'; nodeRuntimeSupport = [pscustomobject]@{ minimumNodeVersion = '20.9.0' } }) -ServiceManager 'nssm' -ReverseProxy 'none' -RepositoryUrl $repositoryUrl
  if (-not $nssm.nssmPathRequired) {
    throw 'Runner onboarding self-test did not require NSSM_PATH for NSSM profiles.'
  }
  $unix = New-RunnerProfile -Target $matrix.targets[1] -ServiceManager 'systemd' -ReverseProxy 'nginx' -RepositoryUrl $repositoryUrl
  if ($unix.preflightCommand -notmatch '--platform unix' -or -not $unix.passwordlessSudoRequired) {
    throw 'Runner onboarding self-test did not create the required Unix preflight profile.'
  }
  $markdown = ConvertTo-OnboardingMarkdown -Document ([pscustomobject]@{ profiles = @($windows, $nssm, $unix) })
  if ($markdown.Contains('<token>') -or -not $markdown.Contains('<issued-token>') -or -not $markdown.Contains('.\config.cmd') -or -not $markdown.Contains('./config.sh') -or -not $markdown.Contains('nextjs-manager-systemd') -or -not $markdown.Contains('NSSM_PATH') -or -not $markdown.Contains('Application Request Routing')) {
    throw 'Runner onboarding self-test produced unsafe or incomplete instructions.'
  }
  Write-Host 'Next.js native runner onboarding self-test OK'
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot 'config\support-matrix.example.json'
} elseif (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}
if ($RepositoryUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'RepositoryUrl must be an https://github.com/owner/repository URL.' }
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) { throw "Support matrix was not found: $MatrixPath" }
& (Join-Path $ScriptDir 'Test-SupportMatrix.ps1') -MatrixPath $MatrixPath | Out-Null

$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requestedTargets = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ } | Sort-Object -Unique)
if ($requestedTargets.Count -eq 0) { throw 'At least one TargetId is required.' }
if ([string]::IsNullOrWhiteSpace($ServiceManager) -xor [string]::IsNullOrWhiteSpace($ReverseProxy)) {
  throw 'ServiceManager and ReverseProxy must be supplied together.'
}
$requestedManager = Normalize-Token $ServiceManager
$requestedProxy = Normalize-Token $ReverseProxy
$profiles = New-Object System.Collections.Generic.List[object]
foreach ($targetId in $requestedTargets) {
  $target = @($matrix.targets | Where-Object { (Normalize-Token ([string]$_.id)) -eq $targetId })
  if ($target.Count -ne 1) { throw "Unknown support matrix target id: $targetId" }
  $target = $target[0]
  if ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true) {
    throw "Target '$targetId' is local-command-only and cannot use the native runner onboarding workflow."
  }
  if (-not (Get-WorkflowPlatform ([string]$target.category))) { throw "Target '$targetId' is not workflow-capable." }
  $managers = @($target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) })
  $proxies = @($target.reverseProxies | ForEach-Object { Normalize-Token ([string]$_) })
  if ($requestedManager) {
    if ($managers -notcontains $requestedManager -or $proxies -notcontains $requestedProxy) {
      throw "Requested manager/proxy combination is not declared for target '$targetId'."
    }
    $profiles.Add((New-RunnerProfile -Target $target -ServiceManager $requestedManager -ReverseProxy $requestedProxy -RepositoryUrl $RepositoryUrl)) | Out-Null
  } else {
    foreach ($manager in $managers) {
      foreach ($proxy in $proxies) {
        $profiles.Add((New-RunnerProfile -Target $target -ServiceManager $manager -ReverseProxy $proxy -RepositoryUrl $RepositoryUrl)) | Out-Null
      }
    }
  }
}

$document = [pscustomobject]@{
  schemaVersion = 1
  kind = 'nextjs-native-runner-onboarding'
  repositoryUrl = $RepositoryUrl
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  profiles = @($profiles | Sort-Object targetId, serviceManager, reverseProxy)
}
$content = if ($Format -eq 'Json') { $document | ConvertTo-Json -Depth 6 } else { ConvertTo-OnboardingMarkdown -Document $document }
if ($OutputPath) {
  $directory = Split-Path -Parent $OutputPath
  if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Set-Content -LiteralPath $OutputPath -Value $content -NoNewline
} elseif (-not $Quiet) {
  Write-Output $content
}
