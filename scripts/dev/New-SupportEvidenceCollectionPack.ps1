param(
  [string]$MatrixPath = "",
  [string]$OutputDirectory = ".\evidence\collection-pack",
  [string]$EvidencePath = ".\evidence",
  [string]$ArtifactPath = ".\evidence-downloads",
  [string]$ReleaseOutputDirectory = ".\release-evidence",
  [string]$BundleName = "support-evidence",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [string]$WorkflowFile = "host-evidence.yml",
  [string]$WorkflowRef = "main",
  [switch]$ProductionRecommendedOnly,
  [switch]$FailOnWarnings,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$Quiet,
  [switch]$PassThru,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot "config\support-matrix.example.json"
}
if (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
  $OutputDirectory = Join-Path (Get-Location) $OutputDirectory
}

function Quote-PowerShellArgument {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-DisplayPath {
  param(
    [string]$Path,
    [string]$OutsideRepositoryLabel = "outside-repository"
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if ($fullPath.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
  if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
  }

  return $OutsideRepositoryLabel
}

function Resolve-OutputRelativePath {
  param([string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return Join-Path $RepoRoot $Path
}

function Add-PlanFilterArguments {
  param([hashtable]$Arguments)

  if ($TargetId.Count -gt 0) { $Arguments["TargetId"] = [string[]]$TargetId }
  if ($Category.Count -gt 0) { $Arguments["Category"] = [string[]]$Category }
  if ($ProductionRecommendedOnly) { $Arguments["ProductionRecommendedOnly"] = $true }
  if ($FailOnWarnings) { $Arguments["FailOnWarnings"] = $true }
}

function Add-ReleaseFilterArguments {
  param([System.Collections.Generic.List[string]]$Lines)

  foreach ($target in @($TargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $Lines.Add("    -TargetId $(Quote-PowerShellArgument $target) ``") | Out-Null
  }
  foreach ($category in @($Category | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $Lines.Add("    -Category $(Quote-PowerShellArgument $category) ``") | Out-Null
  }
  if ($ProductionRecommendedOnly) {
    $Lines.Add("    -ProductionRecommendedOnly ``") | Out-Null
  }
  if ($IncludeServiceOnly) {
    $Lines.Add("    -IncludeServiceOnly ``") | Out-Null
  }
  if ($IncludeFallback) {
    $Lines.Add("    -IncludeFallback ``") | Out-Null
  }
}

function Get-PlanEntries {
  param([object]$Plan)
  return @($Plan.strictEvidence) + @($Plan.serviceOnlyEvidence) + @($Plan.fallbackEvidence)
}

function ConvertTo-ManifestRow {
  param(
    [object]$Entry,
    [string]$ArtifactPath
  )

  $evidenceName = ""
  $workflowInputs = $Entry.workflowInputs
  if ($null -ne $workflowInputs) {
    $evidenceName = [string]$workflowInputs.evidence_name
  }
  $artifactDirectory = ""
  if (-not [string]::IsNullOrWhiteSpace($evidenceName)) {
    $artifactDirectory = (Join-Path $ArtifactPath $evidenceName).Replace("\", "/")
  }

  [pscustomobject]@{
    kind = [string]$Entry.kind
    targetId = [string]$Entry.targetId
    nextJsMode = [string]$Entry.nextJsMode
    serviceManager = [string]$Entry.serviceManager
    reverseProxy = [string]$Entry.reverseProxy
    evidenceName = $evidenceName
    evidenceFile = [string]$Entry.evidenceFile
    artifactDirectory = $artifactDirectory
    collectionCommand = [string]$Entry.collectionCommand
    validationCommand = [string]$Entry.validationCommand
  }
}

function New-CollectionManifestFiles {
  param(
    [object]$Plan,
    [string]$ArtifactPath,
    [string]$WorkflowArtifactsJson,
    [string]$WorkflowArtifactsCsv,
    [string]$LocalOnlyJson,
    [string]$LocalOnlyCsv
  )

  $entries = Get-PlanEntries -Plan $Plan
  $workflowRows = @($entries |
    Where-Object { $_.workflowDispatchSupported -eq $true } |
    ForEach-Object { ConvertTo-ManifestRow -Entry $_ -ArtifactPath $ArtifactPath })
  $localOnlyRows = @($entries |
    Where-Object { $_.workflowDispatchSupported -ne $true } |
    ForEach-Object { ConvertTo-ManifestRow -Entry $_ -ArtifactPath $ArtifactPath })

  $workflowRows | ConvertTo-Json -Depth 6 | Set-Content -Path $WorkflowArtifactsJson -Encoding UTF8
  $workflowRows | Export-Csv -Path $WorkflowArtifactsCsv -NoTypeInformation -Encoding UTF8
  $localOnlyRows | ConvertTo-Json -Depth 6 | Set-Content -Path $LocalOnlyJson -Encoding UTF8
  $localOnlyRows | Export-Csv -Path $LocalOnlyCsv -NoTypeInformation -Encoding UTF8
}

function New-ReleaseCommandScript {
  param(
    [string]$Path,
    [string]$EvidencePath,
    [string]$ArtifactPath,
    [string]$ReleaseOutputDirectory,
    [string]$BundleName,
    [string]$MatrixPath
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("param(") | Out-Null
  $lines.Add("  [switch]`$Run,") | Out-Null
  $lines.Add("  [switch]`$StrictCiRelease,") | Out-Null
  $lines.Add("  [switch]`$RequireFinalFullMatrixReleaseClaim,") | Out-Null
  $lines.Add("  [switch]`$AllowLocalCollection,") | Out-Null
  $lines.Add("  [switch]`$Force") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Set-StrictMode -Version Latest") | Out-Null
  $lines.Add("`$ErrorActionPreference = `"Stop`"") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$arguments = @(") | Out-Null
  $lines.Add("  '-ArtifactPath', $(Quote-PowerShellArgument $ArtifactPath),") | Out-Null
  $lines.Add("  '-EvidencePath', $(Quote-PowerShellArgument $EvidencePath),") | Out-Null
  $lines.Add("  '-MatrixPath', $(Quote-PowerShellArgument $MatrixPath),") | Out-Null
  $lines.Add("  '-OutputDirectory', $(Quote-PowerShellArgument $ReleaseOutputDirectory),") | Out-Null
  $lines.Add("  '-BundleName', $(Quote-PowerShellArgument $BundleName)") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  foreach ($target in @($TargetId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $lines.Add("`$arguments += @('-TargetId', $(Quote-PowerShellArgument $target))") | Out-Null
  }
  foreach ($category in @($Category | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $lines.Add("`$arguments += @('-Category', $(Quote-PowerShellArgument $category))") | Out-Null
  }
  if ($ProductionRecommendedOnly) {
    $lines.Add("`$arguments += '-ProductionRecommendedOnly'") | Out-Null
  }
  if ($IncludeServiceOnly) {
    $lines.Add("`$arguments += '-IncludeServiceOnly'") | Out-Null
  }
  if ($IncludeFallback) {
    $lines.Add("`$arguments += '-IncludeFallback'") | Out-Null
  }
  $lines.Add("if (`$StrictCiRelease) { `$arguments += '-StrictCiRelease' }") | Out-Null
  $lines.Add("if (`$RequireFinalFullMatrixReleaseClaim) { `$arguments += '-RequireFinalFullMatrixReleaseClaim' }") | Out-Null
  $lines.Add("if (`$AllowLocalCollection) { `$arguments += '-AllowLocalCollection' }") | Out-Null
  $lines.Add("if (`$Force) { `$arguments += '-Force' }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$Run) {") | Out-Null
  $lines.Add("  & .\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 @arguments") | Out-Null
  $lines.Add("  exit `$LASTEXITCODE") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Write-Host 'Review downloaded artifacts and local-only evidence, then rerun this script with -Run.'") | Out-Null
  $lines.Add("Write-Host ''") | Out-Null
  $lines.Add("Write-Host '.\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 ' -NoNewline") | Out-Null
  $lines.Add("Write-Host (`$arguments -join ' ')") | Out-Null

  $lines -join [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function New-ArtifactDownloadScript {
  param(
    [string]$Path,
    [object]$Plan,
    [string]$ArtifactPath,
    [string]$WorkflowFile,
    [string]$WorkflowRef
  )

  $entries = Get-PlanEntries -Plan $Plan
  $workflowEntries = @($entries | Where-Object {
      $_.workflowDispatchSupported -eq $true -and
      $null -ne $_.workflowInputs -and
      -not [string]::IsNullOrWhiteSpace([string]$_.workflowInputs.evidence_name)
    })

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("param(") | Out-Null
  $lines.Add("  [string[]]`$RunId = @(),") | Out-Null
  $lines.Add("  [switch]`$Run,") | Out-Null
  $lines.Add("  [switch]`$Force,") | Out-Null
  $lines.Add("  [switch]`$ContinueOnMissing") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Set-StrictMode -Version Latest") | Out-Null
  $lines.Add("`$ErrorActionPreference = `"Stop`"") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$ArtifactPath = $(Quote-PowerShellArgument $ArtifactPath)") | Out-Null
  $lines.Add("`$WorkflowFile = $(Quote-PowerShellArgument $WorkflowFile)") | Out-Null
  $lines.Add("`$WorkflowRef = $(Quote-PowerShellArgument $WorkflowRef)") | Out-Null
  $lines.Add("`$ExpectedArtifacts = @(") | Out-Null
  foreach ($entry in $workflowEntries) {
    $inputs = $entry.workflowInputs
    $lines.Add("  [pscustomobject]@{") | Out-Null
    $lines.Add("    Kind = $(Quote-PowerShellArgument ([string]$entry.kind))") | Out-Null
    $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$entry.targetId))") | Out-Null
    $lines.Add("    NextJsMode = $(Quote-PowerShellArgument ([string]$entry.nextJsMode))") | Out-Null
    $lines.Add("    ServiceManager = $(Quote-PowerShellArgument ([string]$entry.serviceManager))") | Out-Null
    $lines.Add("    ReverseProxy = $(Quote-PowerShellArgument ([string]$entry.reverseProxy))") | Out-Null
    $lines.Add("    EvidenceName = $(Quote-PowerShellArgument ([string]$inputs.evidence_name))") | Out-Null
    $lines.Add("  }") | Out-Null
  }
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$ExpectedArtifacts.Count -eq 0) {") | Out-Null
  $lines.Add("  Write-Host 'No workflow-capable artifacts are expected for this scoped plan.'") | Out-Null
  $lines.Add("  return") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (-not `$Run) {") | Out-Null
  $lines.Add("  Write-Host 'Review successful host-evidence workflow runs, then rerun with -RunId <id[,id...]> -Run.'") | Out-Null
  $lines.Add("  Write-Host ''") | Out-Null
  $lines.Add("  Write-Host `"gh run list --workflow `$WorkflowFile --event workflow_dispatch --branch `$WorkflowRef --limit 100`"") | Out-Null
  $lines.Add("  Write-Host ''") | Out-Null
  $lines.Add("  Write-Host 'Expected artifact download commands:'") | Out-Null
  $lines.Add("  foreach (`$artifact in `$ExpectedArtifacts) {") | Out-Null
  $lines.Add("    `$destination = Join-Path `$ArtifactPath `$artifact.EvidenceName") | Out-Null
  $lines.Add("    Write-Host (`"gh run download RUN_ID --name '{0}' --dir '{1}'`" -f `$artifact.EvidenceName, `$destination)") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  return") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$RunId.Count -eq 0) {") | Out-Null
  $lines.Add("  throw 'At least one -RunId value is required when -Run is supplied.'") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("`$gh = Get-Command gh -ErrorAction SilentlyContinue") | Out-Null
  $lines.Add("if (-not `$gh) {") | Out-Null
  $lines.Add("  throw 'GitHub CLI gh was not found. Install gh or download artifacts from the Actions UI into ArtifactPath.'") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("New-Item -ItemType Directory -Path `$ArtifactPath -Force | Out-Null") | Out-Null
  $lines.Add("`$missing = New-Object System.Collections.Generic.List[string]") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("foreach (`$artifact in `$ExpectedArtifacts) {") | Out-Null
  $lines.Add("  `$destination = Join-Path `$ArtifactPath `$artifact.EvidenceName") | Out-Null
  $lines.Add("  if ((Test-Path -LiteralPath `$destination) -and `$Force) {") | Out-Null
  $lines.Add("    Remove-Item -LiteralPath `$destination -Recurse -Force") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  New-Item -ItemType Directory -Path `$destination -Force | Out-Null") | Out-Null
  $lines.Add("  `$downloaded = `$false") | Out-Null
  $lines.Add("  foreach (`$id in `$RunId) {") | Out-Null
  $lines.Add("    & `$gh.Source run download `$id --name `$artifact.EvidenceName --dir `$destination") | Out-Null
  $lines.Add("    if (`$LASTEXITCODE -eq 0) {") | Out-Null
  $lines.Add("      `$downloaded = `$true") | Out-Null
  $lines.Add("      break") | Out-Null
  $lines.Add("    }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  if (-not `$downloaded) {") | Out-Null
  $lines.Add("    `$missing.Add(`$artifact.EvidenceName) | Out-Null") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$missing.Count -gt 0) {") | Out-Null
  $lines.Add("  `$message = 'Missing expected host-evidence artifact(s): ' + (`$missing -join ', ')") | Out-Null
  $lines.Add("  if (`$ContinueOnMissing) {") | Out-Null
  $lines.Add("    Write-Warning `$message") | Out-Null
  $lines.Add("  } else {") | Out-Null
  $lines.Add("    throw `$message") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Write-Host `"Downloaded host-evidence artifacts into `$ArtifactPath`"") | Out-Null

  $lines -join [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function New-StagingAuditScript {
  param(
    [string]$Path,
    [object]$Plan,
    [string]$ArtifactPath,
    [string]$EvidencePath,
    [string]$MatrixPath
  )

  $entries = Get-PlanEntries -Plan $Plan
  $workflowEntries = @($entries | Where-Object {
      $_.workflowDispatchSupported -eq $true -and
      $null -ne $_.workflowInputs -and
      -not [string]::IsNullOrWhiteSpace([string]$_.workflowInputs.evidence_name)
    })
  $localOnlyEntries = @($entries | Where-Object { $_.workflowDispatchSupported -ne $true })

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("param(") | Out-Null
  $lines.Add("  [string]`$ArtifactPath = $(Quote-PowerShellArgument $ArtifactPath),") | Out-Null
  $lines.Add("  [string]`$EvidencePath = $(Quote-PowerShellArgument $EvidencePath),") | Out-Null
  $lines.Add("  [switch]`$ValidateWithHostEvidence,") | Out-Null
  $lines.Add("  [string]`$HostEvidenceValidatorPath = `"`",") | Out-Null
  $lines.Add("  [switch]`$ReportOnly,") | Out-Null
  $lines.Add("  [switch]`$PassThru") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Set-StrictMode -Version Latest") | Out-Null
  $lines.Add("`$ErrorActionPreference = `"Stop`"") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$MatrixPath = $(Quote-PowerShellArgument $MatrixPath)") | Out-Null
  $lines.Add("`$ExpectedMatrixSha256 = if (Test-Path -LiteralPath `$MatrixPath -PathType Leaf) { (Get-FileHash -LiteralPath `$MatrixPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { `"`" }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$ExpectedArtifacts = @(") | Out-Null
  foreach ($entry in $workflowEntries) {
    $inputs = $entry.workflowInputs
    $lines.Add("  [pscustomobject]@{") | Out-Null
    $lines.Add("    Kind = $(Quote-PowerShellArgument ([string]$entry.kind))") | Out-Null
    $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$entry.targetId))") | Out-Null
    $lines.Add("    NextJsMode = $(Quote-PowerShellArgument ([string]$entry.nextJsMode))") | Out-Null
    $lines.Add("    ServiceManager = $(Quote-PowerShellArgument ([string]$entry.serviceManager))") | Out-Null
    $lines.Add("    ReverseProxy = $(Quote-PowerShellArgument ([string]$entry.reverseProxy))") | Out-Null
    $lines.Add("    EvidenceName = $(Quote-PowerShellArgument ([string]$inputs.evidence_name))") | Out-Null
    $lines.Add("    MatrixPath = $(Quote-PowerShellArgument ([string]$inputs.matrix_path))") | Out-Null
    $lines.Add("    EvidenceFile = $(Quote-PowerShellArgument ([string]$entry.evidenceFile))") | Out-Null
    $lines.Add("    RequiredMinimumUptimeHours = $([int]$entry.requiredMinimumUptimeHours)") | Out-Null
    $lines.Add("    FailOnWarnings = $(if ($FailOnWarnings) { '$true' } else { '$false' })") | Out-Null
    $lines.Add("    WorkflowDispatchSupported = `$true") | Out-Null
    $lines.Add("  }") | Out-Null
  }
  $lines.Add(")") | Out-Null
  $lines.Add("`$LocalOnlyEvidence = @(") | Out-Null
  foreach ($entry in $localOnlyEntries) {
    $lines.Add("  [pscustomobject]@{") | Out-Null
    $lines.Add("    Kind = $(Quote-PowerShellArgument ([string]$entry.kind))") | Out-Null
    $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$entry.targetId))") | Out-Null
    $lines.Add("    NextJsMode = $(Quote-PowerShellArgument ([string]$entry.nextJsMode))") | Out-Null
    $lines.Add("    ServiceManager = $(Quote-PowerShellArgument ([string]$entry.serviceManager))") | Out-Null
    $lines.Add("    ReverseProxy = $(Quote-PowerShellArgument ([string]$entry.reverseProxy))") | Out-Null
    $lines.Add("    EvidenceFile = $(Quote-PowerShellArgument ([string]$entry.evidenceFile))") | Out-Null
    $lines.Add("    RequiredMinimumUptimeHours = $([int]$entry.requiredMinimumUptimeHours)") | Out-Null
    $lines.Add("    FailOnWarnings = $(if ($FailOnWarnings) { '$true' } else { '$false' })") | Out-Null
    $lines.Add("    WorkflowDispatchSupported = `$false") | Out-Null
    $lines.Add("  }") | Out-Null
  }
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Resolve-CollectionRelativePath {") | Out-Null
  $lines.Add("  param(") | Out-Null
  $lines.Add("    [string]`$BasePath,") | Out-Null
  $lines.Add("    [string]`$Path,") | Out-Null
  $lines.Add("    [string]`$LeadingRoot") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if ([string]::IsNullOrWhiteSpace(`$Path)) { return `"`" }") | Out-Null
  $lines.Add("  if ([System.IO.Path]::IsPathRooted(`$Path)) { return [System.IO.Path]::GetFullPath(`$Path) }") | Out-Null
  $lines.Add("  `$normalized = `$Path -replace '\\', '/'") | Out-Null
  $lines.Add("  `$leadingPrefix = `"{0}/`" -f `$LeadingRoot") | Out-Null
  $lines.Add("  if (-not [string]::IsNullOrWhiteSpace(`$LeadingRoot) -and `$normalized.StartsWith(`$leadingPrefix, [StringComparison]::OrdinalIgnoreCase)) {") | Out-Null
  $lines.Add("    `$normalized = `$normalized.Substring(`$leadingPrefix.Length)") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  `$resolved = `$BasePath") | Out-Null
  $lines.Add("  foreach (`$part in @(`$normalized -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace(`$_) })) {") | Out-Null
  $lines.Add("    `$resolved = Join-Path `$resolved `$part") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  return [System.IO.Path]::GetFullPath(`$resolved)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Find-StatusJson {") | Out-Null
  $lines.Add("  param([string]`$Directory)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if (-not (Test-Path -LiteralPath `$Directory -PathType Container)) { return `$null }") | Out-Null
  $lines.Add("  `$directStatusPath = Join-Path `$Directory `"status.json`"") | Out-Null
  $lines.Add("  if (Test-Path -LiteralPath `$directStatusPath -PathType Leaf) {") | Out-Null
  $lines.Add("    return (Get-Item -LiteralPath `$directStatusPath).FullName") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  `$nestedStatusPath = Get-ChildItem -LiteralPath `$Directory -Recurse -Filter `"status.json`" -File -ErrorAction SilentlyContinue | Select-Object -First 1") | Out-Null
  $lines.Add("  if (`$null -eq `$nestedStatusPath) { return `$null }") | Out-Null
  $lines.Add("  return `$nestedStatusPath.FullName") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Read-EvidenceJson {") | Out-Null
  $lines.Add("  param([string]`$Path)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  try {") | Out-Null
  $lines.Add("    return (Get-Content -LiteralPath `$Path -Raw | ConvertFrom-Json)") | Out-Null
  $lines.Add("  } catch {") | Out-Null
  $lines.Add("    throw `"Evidence JSON could not be parsed: `$Path. `$(`$_.Exception.Message)`"") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-ObjectPropertyValue {") | Out-Null
  $lines.Add("  param(") | Out-Null
  $lines.Add("    [object]`$Object,") | Out-Null
  $lines.Add("    [string[]]`$Names") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if (`$null -eq `$Object) { return `$null }") | Out-Null
  $lines.Add("  `$properties = `$Object.PSObject.Properties") | Out-Null
  $lines.Add("  foreach (`$name in `$Names) {") | Out-Null
  $lines.Add("    `$property = `$properties[`$name]") | Out-Null
  $lines.Add("    if (`$null -ne `$property) { return `$property.Value }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  return `$null") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-ObjectStringValue {") | Out-Null
  $lines.Add("  param(") | Out-Null
  $lines.Add("    [object]`$Object,") | Out-Null
  $lines.Add("    [string[]]`$Names") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$value = Get-ObjectPropertyValue -Object `$Object -Names `$Names") | Out-Null
  $lines.Add("  if (`$null -eq `$value) { return `"`" }") | Out-Null
  $lines.Add("  return [string]`$value") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Normalize-CollectionToken {") | Out-Null
  $lines.Add("  param([string]`$Value)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if ([string]::IsNullOrWhiteSpace(`$Value)) { return `"`" }") | Out-Null
  $lines.Add("  return ((`$Value.Trim().ToLowerInvariant() -replace '_', '-') -replace '\s+', '-')") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Normalize-CollectionReverseProxy {") | Out-Null
  $lines.Add("  param([string]`$Value)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$normalized = Normalize-CollectionToken `$Value") | Out-Null
  $lines.Add("  if ([string]::IsNullOrWhiteSpace(`$normalized) -or `$normalized -in @('disabled', 'not-applicable', 'not-configured')) { return 'none' }") | Out-Null
  $lines.Add("  return `$normalized") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Resolve-HostEvidenceValidatorPath {") | Out-Null
  $lines.Add("  if (-not [string]::IsNullOrWhiteSpace(`$HostEvidenceValidatorPath)) {") | Out-Null
  $lines.Add("    if (-not (Test-Path -LiteralPath `$HostEvidenceValidatorPath -PathType Leaf)) {") | Out-Null
  $lines.Add("      throw `"Host evidence validator not found: `$HostEvidenceValidatorPath`"") | Out-Null
  $lines.Add("    }") | Out-Null
  $lines.Add("    return (Resolve-Path -LiteralPath `$HostEvidenceValidatorPath).ProviderPath") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$candidates = @(") | Out-Null
  $lines.Add("    (Join-Path (Get-Location) `"scripts\dev\Test-HostEvidence.ps1`"),") | Out-Null
  $lines.Add("    (Join-Path `$PSScriptRoot `"..\..\scripts\dev\Test-HostEvidence.ps1`"),") | Out-Null
  $lines.Add("    (Join-Path `$PSScriptRoot `"scripts\dev\Test-HostEvidence.ps1`")") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("  foreach (`$candidate in `$candidates) {") | Out-Null
  $lines.Add("    if (Test-Path -LiteralPath `$candidate -PathType Leaf) {") | Out-Null
  $lines.Add("      return (Resolve-Path -LiteralPath `$candidate).ProviderPath") | Out-Null
  $lines.Add("    }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  throw `"Test-HostEvidence.ps1 was not found. Run this staging audit from the repository root, keep the generated pack under evidence\collection-pack, pass -HostEvidenceValidatorPath, or omit -ValidateWithHostEvidence.`"") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Invoke-HostEvidenceValidation {") | Out-Null
  $lines.Add("  param(") | Out-Null
  $lines.Add("    [string]`$StatusPath,") | Out-Null
  $lines.Add("    [object]`$Expected") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if (-not `$ValidateWithHostEvidence) { return `$null }") | Out-Null
  $lines.Add("  `$validatorPath = Resolve-HostEvidenceValidatorPath") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$args = @(") | Out-Null
  $lines.Add("    '-EvidencePath', `$StatusPath,") | Out-Null
  $lines.Add("    '-RequireNextJs',") | Out-Null
  $lines.Add("    '-RequireDeploymentIdentity',") | Out-Null
  $lines.Add("    '-RequireCollectorSha256',") | Out-Null
  $lines.Add("    '-RequireMinimumUptimeHours', [string]`$Expected.RequiredMinimumUptimeHours,") | Out-Null
  $lines.Add("    '-MaxEvidenceAgeDays', '1',") | Out-Null
  $lines.Add("    '-ExpectedTargetId', `$Expected.TargetId,") | Out-Null
  $lines.Add("    '-ExpectedNextJsMode', `$Expected.NextJsMode,") | Out-Null
  $lines.Add("    '-ExpectedServiceManager', `$Expected.ServiceManager,") | Out-Null
  $lines.Add("    '-ExpectedReverseProxy', `$Expected.ReverseProxy,") | Out-Null
  $lines.Add("    '-RequireReverseProxy'") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("  if (`$Expected.WorkflowDispatchSupported) {") | Out-Null
  $lines.Add("    `$args += @('-RequireCiCollection', '-RequireHostEvidenceWorkflowCollection')") | Out-Null
  $lines.Add("    if (`$Expected.PSObject.Properties['MatrixPath'] -and -not [string]::IsNullOrWhiteSpace([string]`$Expected.MatrixPath)) { `$args += @('-ExpectedMatrixPath', [string]`$Expected.MatrixPath) }") | Out-Null
  $lines.Add("    if (-not [string]::IsNullOrWhiteSpace(`$ExpectedMatrixSha256)) { `$args += @('-ExpectedMatrixSha256', `$ExpectedMatrixSha256) }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  if ((Normalize-CollectionReverseProxy `$Expected.ReverseProxy) -eq 'none') { `$args += '-AllowReverseProxyNone' }") | Out-Null
  $lines.Add("  if (`$Expected.FailOnWarnings) { `$args += '-FailOnWarnings' }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  try {") | Out-Null
  $lines.Add("    & `$validatorPath @args | Out-Null") | Out-Null
  $lines.Add("    return `$null") | Out-Null
  $lines.Add("  } catch {") | Out-Null
  $lines.Add("    return [pscustomobject]@{") | Out-Null
  $lines.Add("      targetId = `$Expected.TargetId") | Out-Null
  $lines.Add("      nextJsMode = `$Expected.NextJsMode") | Out-Null
  $lines.Add("      serviceManager = `$Expected.ServiceManager") | Out-Null
  $lines.Add("      reverseProxy = `$Expected.ReverseProxy") | Out-Null
  $lines.Add("      evidenceName = if (`$Expected.PSObject.Properties['EvidenceName']) { `$Expected.EvidenceName } else { `"`" }") | Out-Null
  $lines.Add("      evidenceFile = if (`$Expected.PSObject.Properties['EvidenceFile']) { `$Expected.EvidenceFile } else { `"`" }") | Out-Null
  $lines.Add("      sourcePath = `$StatusPath") | Out-Null
  $lines.Add("      reason = `"host evidence validation failed: `$(`$_.Exception.Message)`"") | Out-Null
  $lines.Add("    }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-EvidenceTargetId {") | Out-Null
  $lines.Add("  param([object]`$Evidence)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$platform = Get-ObjectPropertyValue -Object `$Evidence -Names @('Platform', 'platform')") | Out-Null
  $lines.Add("  `$value = Get-ObjectStringValue -Object `$Evidence -Names @('SupportTargetId', 'supportTargetId', 'TargetId', 'targetId')") | Out-Null
  $lines.Add("  if (-not `$value) { `$value = Get-ObjectStringValue -Object `$platform -Names @('SupportTargetId', 'supportTargetId', 'TargetId', 'targetId') }") | Out-Null
  $lines.Add("  return (Normalize-CollectionToken `$value)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-EvidenceNextJsMode {") | Out-Null
  $lines.Add("  param([object]`$Evidence)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$nextJs = Get-ObjectPropertyValue -Object `$Evidence -Names @('NextJsRuntime', 'nextJsRuntime')") | Out-Null
  $lines.Add("  `$platform = Get-ObjectPropertyValue -Object `$Evidence -Names @('Platform', 'platform')") | Out-Null
  $lines.Add("  `$mode = Get-ObjectStringValue -Object `$nextJs -Names @('Mode', 'mode')") | Out-Null
  $lines.Add("  if (-not `$mode) { `$mode = Get-ObjectStringValue -Object `$platform -Names @('NextjsDeploymentMode', 'nextjsDeploymentMode', 'NextJsDeploymentMode') }") | Out-Null
  $lines.Add("  if (-not `$mode) { `$mode = Get-ObjectStringValue -Object `$Evidence -Names @('NextjsDeploymentMode', 'nextjsDeploymentMode', 'NextJsDeploymentMode') }") | Out-Null
  $lines.Add("  return (Normalize-CollectionToken `$mode)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-EvidenceServiceManager {") | Out-Null
  $lines.Add("  param([object]`$Evidence)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$platform = Get-ObjectPropertyValue -Object `$Evidence -Names @('Platform', 'platform')") | Out-Null
  $lines.Add("  `$serviceManager = Get-ObjectStringValue -Object `$platform -Names @('ServiceManager', 'serviceManager')") | Out-Null
  $lines.Add("  if (-not `$serviceManager) { `$serviceManager = Get-ObjectStringValue -Object `$Evidence -Names @('ServiceManager', 'serviceManager') }") | Out-Null
  $lines.Add("  return (Normalize-CollectionToken `$serviceManager)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-EvidenceReverseProxy {") | Out-Null
  $lines.Add("  param([object]`$Evidence)") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$reverseProxy = Get-ObjectPropertyValue -Object `$Evidence -Names @('ReverseProxy', 'reverseProxy')") | Out-Null
  $lines.Add("  `$platform = Get-ObjectPropertyValue -Object `$Evidence -Names @('Platform', 'platform')") | Out-Null
  $lines.Add("  `$mode = Get-ObjectStringValue -Object `$reverseProxy -Names @('Mode', 'mode')") | Out-Null
  $lines.Add("  if (-not `$mode) { `$mode = Get-ObjectStringValue -Object `$platform -Names @('ReverseProxy', 'reverseProxy') }") | Out-Null
  $lines.Add("  if (-not `$mode) { `$mode = Get-ObjectStringValue -Object `$Evidence -Names @('ReverseProxy', 'reverseProxy') }") | Out-Null
  $lines.Add("  return (Normalize-CollectionReverseProxy `$mode)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("function Get-EvidenceIdentityMismatch {") | Out-Null
  $lines.Add("  param(") | Out-Null
  $lines.Add("    [object]`$Evidence,") | Out-Null
  $lines.Add("    [object]`$Expected,") | Out-Null
  $lines.Add("    [string]`$SourcePath") | Out-Null
  $lines.Add("  )") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  `$expectedTargetId = Normalize-CollectionToken `$Expected.TargetId") | Out-Null
  $lines.Add("  `$expectedNextJsMode = Normalize-CollectionToken `$Expected.NextJsMode") | Out-Null
  $lines.Add("  `$expectedServiceManager = Normalize-CollectionToken `$Expected.ServiceManager") | Out-Null
  $lines.Add("  `$expectedReverseProxy = Normalize-CollectionReverseProxy `$Expected.ReverseProxy") | Out-Null
  $lines.Add("  `$actualTargetId = Get-EvidenceTargetId -Evidence `$Evidence") | Out-Null
  $lines.Add("  `$actualNextJsMode = Get-EvidenceNextJsMode -Evidence `$Evidence") | Out-Null
  $lines.Add("  `$actualServiceManager = Get-EvidenceServiceManager -Evidence `$Evidence") | Out-Null
  $lines.Add("  `$actualReverseProxy = Get-EvidenceReverseProxy -Evidence `$Evidence") | Out-Null
  $lines.Add("  `$issues = New-Object System.Collections.Generic.List[string]") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  if (`$actualTargetId -ne `$expectedTargetId) { `$issues.Add(`"targetId expected '`$expectedTargetId' but found '`$actualTargetId'`") | Out-Null }") | Out-Null
  $lines.Add("  if (`$actualNextJsMode -ne `$expectedNextJsMode) { `$issues.Add(`"nextJsMode expected '`$expectedNextJsMode' but found '`$actualNextJsMode'`") | Out-Null }") | Out-Null
  $lines.Add("  if (`$actualServiceManager -ne `$expectedServiceManager) { `$issues.Add(`"serviceManager expected '`$expectedServiceManager' but found '`$actualServiceManager'`") | Out-Null }") | Out-Null
  $lines.Add("  if (`$actualReverseProxy -ne `$expectedReverseProxy) { `$issues.Add(`"reverseProxy expected '`$expectedReverseProxy' but found '`$actualReverseProxy'`") | Out-Null }") | Out-Null
  $lines.Add("  if (`$issues.Count -eq 0) { return `$null }") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("  return [pscustomobject]@{") | Out-Null
  $lines.Add("    targetId = `$Expected.TargetId") | Out-Null
  $lines.Add("    nextJsMode = `$Expected.NextJsMode") | Out-Null
  $lines.Add("    serviceManager = `$Expected.ServiceManager") | Out-Null
  $lines.Add("    reverseProxy = `$Expected.ReverseProxy") | Out-Null
  $lines.Add("    evidenceName = if (`$Expected.PSObject.Properties['EvidenceName']) { `$Expected.EvidenceName } else { `"`" }") | Out-Null
  $lines.Add("    evidenceFile = if (`$Expected.PSObject.Properties['EvidenceFile']) { `$Expected.EvidenceFile } else { `"`" }") | Out-Null
  $lines.Add("    sourcePath = `$SourcePath") | Out-Null
  $lines.Add("    expectedTargetId = `$expectedTargetId") | Out-Null
  $lines.Add("    actualTargetId = `$actualTargetId") | Out-Null
  $lines.Add("    expectedNextJsMode = `$expectedNextJsMode") | Out-Null
  $lines.Add("    actualNextJsMode = `$actualNextJsMode") | Out-Null
  $lines.Add("    expectedServiceManager = `$expectedServiceManager") | Out-Null
  $lines.Add("    actualServiceManager = `$actualServiceManager") | Out-Null
  $lines.Add("    expectedReverseProxy = `$expectedReverseProxy") | Out-Null
  $lines.Add("    actualReverseProxy = `$actualReverseProxy") | Out-Null
  $lines.Add("    reason = 'identity mismatch: ' + (`$issues -join '; ')") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$artifactRoot = [System.IO.Path]::GetFullPath(`$ArtifactPath)") | Out-Null
  $lines.Add("`$evidenceRoot = [System.IO.Path]::GetFullPath(`$EvidencePath)") | Out-Null
  $lines.Add("`$missingWorkflowArtifacts = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("`$invalidWorkflowArtifacts = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("`$presentWorkflowArtifacts = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("`$missingLocalOnlyEvidence = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("`$invalidLocalOnlyEvidence = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("`$presentLocalOnlyEvidence = New-Object System.Collections.Generic.List[object]") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("foreach (`$artifact in `$ExpectedArtifacts) {") | Out-Null
  $lines.Add("  `$destination = Join-Path `$artifactRoot `$artifact.EvidenceName") | Out-Null
  $lines.Add("  `$statusPath = Find-StatusJson -Directory `$destination") | Out-Null
  $lines.Add("  if ([string]::IsNullOrWhiteSpace(`$statusPath)) {") | Out-Null
  $lines.Add("    `$missingWorkflowArtifacts.Add([pscustomobject]@{ targetId = `$artifact.TargetId; nextJsMode = `$artifact.NextJsMode; serviceManager = `$artifact.ServiceManager; reverseProxy = `$artifact.ReverseProxy; evidenceName = `$artifact.EvidenceName; expectedDirectory = `$destination; reason = `"missing status.json`" }) | Out-Null") | Out-Null
  $lines.Add("  } else {") | Out-Null
  $lines.Add("    `$statusEvidence = Read-EvidenceJson -Path `$statusPath") | Out-Null
  $lines.Add("    `$mismatch = Get-EvidenceIdentityMismatch -Evidence `$statusEvidence -Expected `$artifact -SourcePath `$statusPath") | Out-Null
    $lines.Add("    if (`$null -ne `$mismatch) {") | Out-Null
    $lines.Add("      `$invalidWorkflowArtifacts.Add(`$mismatch) | Out-Null") | Out-Null
    $lines.Add("    } else {") | Out-Null
    $lines.Add("      `$validationFailure = Invoke-HostEvidenceValidation -StatusPath `$statusPath -Expected `$artifact") | Out-Null
    $lines.Add("      if (`$null -ne `$validationFailure) {") | Out-Null
    $lines.Add("        `$invalidWorkflowArtifacts.Add(`$validationFailure) | Out-Null") | Out-Null
    $lines.Add("      } else {") | Out-Null
    $lines.Add("        `$presentWorkflowArtifacts.Add([pscustomobject]@{ targetId = `$artifact.TargetId; nextJsMode = `$artifact.NextJsMode; serviceManager = `$artifact.ServiceManager; reverseProxy = `$artifact.ReverseProxy; evidenceName = `$artifact.EvidenceName; statusPath = `$statusPath }) | Out-Null") | Out-Null
    $lines.Add("      }") | Out-Null
    $lines.Add("    }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("foreach (`$evidence in `$LocalOnlyEvidence) {") | Out-Null
  $lines.Add("  `$expectedPath = Resolve-CollectionRelativePath -BasePath `$evidenceRoot -Path `$evidence.EvidenceFile -LeadingRoot `"evidence`"") | Out-Null
  $lines.Add("  if (-not (Test-Path -LiteralPath `$expectedPath -PathType Leaf)) {") | Out-Null
  $lines.Add("    `$missingLocalOnlyEvidence.Add([pscustomobject]@{ targetId = `$evidence.TargetId; nextJsMode = `$evidence.NextJsMode; serviceManager = `$evidence.ServiceManager; reverseProxy = `$evidence.ReverseProxy; evidenceFile = `$evidence.EvidenceFile; expectedPath = `$expectedPath; reason = `"missing evidence file`" }) | Out-Null") | Out-Null
  $lines.Add("  } else {") | Out-Null
  $lines.Add("    `$localEvidenceJson = Read-EvidenceJson -Path `$expectedPath") | Out-Null
  $lines.Add("    `$mismatch = Get-EvidenceIdentityMismatch -Evidence `$localEvidenceJson -Expected `$evidence -SourcePath `$expectedPath") | Out-Null
    $lines.Add("    if (`$null -ne `$mismatch) {") | Out-Null
    $lines.Add("      `$invalidLocalOnlyEvidence.Add(`$mismatch) | Out-Null") | Out-Null
    $lines.Add("    } else {") | Out-Null
    $lines.Add("      `$validationFailure = Invoke-HostEvidenceValidation -StatusPath `$expectedPath -Expected `$evidence") | Out-Null
    $lines.Add("      if (`$null -ne `$validationFailure) {") | Out-Null
    $lines.Add("        `$invalidLocalOnlyEvidence.Add(`$validationFailure) | Out-Null") | Out-Null
    $lines.Add("      } else {") | Out-Null
    $lines.Add("        `$presentLocalOnlyEvidence.Add([pscustomobject]@{ targetId = `$evidence.TargetId; nextJsMode = `$evidence.NextJsMode; serviceManager = `$evidence.ServiceManager; reverseProxy = `$evidence.ReverseProxy; evidenceFile = `$evidence.EvidenceFile; evidencePath = `$expectedPath }) | Out-Null") | Out-Null
    $lines.Add("      }") | Out-Null
    $lines.Add("    }") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$result = [pscustomobject]@{") | Out-Null
  $lines.Add("  artifactPath = `$artifactRoot") | Out-Null
  $lines.Add("  evidencePath = `$evidenceRoot") | Out-Null
  $lines.Add("  expectedWorkflowArtifactCount = `$ExpectedArtifacts.Count") | Out-Null
  $lines.Add("  presentWorkflowArtifactCount = `$presentWorkflowArtifacts.Count") | Out-Null
  $lines.Add("  missingWorkflowArtifactCount = `$missingWorkflowArtifacts.Count") | Out-Null
  $lines.Add("  invalidWorkflowArtifactCount = `$invalidWorkflowArtifacts.Count") | Out-Null
  $lines.Add("  expectedLocalOnlyEvidenceCount = `$LocalOnlyEvidence.Count") | Out-Null
  $lines.Add("  presentLocalOnlyEvidenceCount = `$presentLocalOnlyEvidence.Count") | Out-Null
  $lines.Add("  missingLocalOnlyEvidenceCount = `$missingLocalOnlyEvidence.Count") | Out-Null
  $lines.Add("  invalidLocalOnlyEvidenceCount = `$invalidLocalOnlyEvidence.Count") | Out-Null
  $lines.Add("  presentWorkflowArtifacts = @(`$presentWorkflowArtifacts.ToArray())") | Out-Null
  $lines.Add("  missingWorkflowArtifacts = @(`$missingWorkflowArtifacts.ToArray())") | Out-Null
  $lines.Add("  invalidWorkflowArtifacts = @(`$invalidWorkflowArtifacts.ToArray())") | Out-Null
  $lines.Add("  presentLocalOnlyEvidence = @(`$presentLocalOnlyEvidence.ToArray())") | Out-Null
  $lines.Add("  missingLocalOnlyEvidence = @(`$missingLocalOnlyEvidence.ToArray())") | Out-Null
  $lines.Add("  invalidLocalOnlyEvidence = @(`$invalidLocalOnlyEvidence.ToArray())") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$missingWorkflowArtifacts.Count -gt 0 -or `$invalidWorkflowArtifacts.Count -gt 0 -or `$missingLocalOnlyEvidence.Count -gt 0 -or `$invalidLocalOnlyEvidence.Count -gt 0) {") | Out-Null
  $lines.Add("  `$message = `"Host evidence collection staging is incomplete or mismatched: {0} workflow artifact(s) missing, {1} workflow artifact(s) invalid, {2} local-only evidence file(s) missing, {3} local-only evidence file(s) invalid.`" -f `$missingWorkflowArtifacts.Count, `$invalidWorkflowArtifacts.Count, `$missingLocalOnlyEvidence.Count, `$invalidLocalOnlyEvidence.Count") | Out-Null
  $lines.Add("  if (`$ReportOnly) {") | Out-Null
  $lines.Add("    Write-Warning `$message") | Out-Null
  $lines.Add("  } else {") | Out-Null
  $lines.Add("    throw `$message") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("} else {") | Out-Null
  $lines.Add("  Write-Host 'Host evidence collection staging is complete.'") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (`$PassThru) { `$result }") | Out-Null

  $lines -join [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function New-CollectionProgressScript {
  param(
    [string]$Path,
    [string]$StagingAuditScript,
    [string]$ArtifactPath,
    [string]$EvidencePath
  )

  $stagingAuditScriptName = Split-Path -Leaf $StagingAuditScript
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("param(") | Out-Null
  $lines.Add("  [string]`$ArtifactPath = $(Quote-PowerShellArgument $ArtifactPath),") | Out-Null
  $lines.Add("  [string]`$EvidencePath = $(Quote-PowerShellArgument $EvidencePath),") | Out-Null
  $lines.Add("  [string]`$OutputDirectory = (Join-Path `$PSScriptRoot 'progress'),") | Out-Null
  $lines.Add("  [switch]`$ValidateWithHostEvidence,") | Out-Null
  $lines.Add("  [string]`$HostEvidenceValidatorPath = `"`",") | Out-Null
  $lines.Add("  [switch]`$PassThru") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Set-StrictMode -Version Latest") | Out-Null
  $lines.Add("`$ErrorActionPreference = `"Stop`"") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$stagingAuditScript = Join-Path `$PSScriptRoot $(Quote-PowerShellArgument $stagingAuditScriptName)") | Out-Null
  $lines.Add("if (-not (Test-Path -LiteralPath `$stagingAuditScript -PathType Leaf)) { throw `"Staging audit script was not found: `$stagingAuditScript`" }") | Out-Null
  $lines.Add("`$auditArguments = @{ ArtifactPath = `$ArtifactPath; EvidencePath = `$EvidencePath; ReportOnly = `$true; PassThru = `$true }") | Out-Null
  $lines.Add("if (`$ValidateWithHostEvidence) { `$auditArguments.ValidateWithHostEvidence = `$true }") | Out-Null
  $lines.Add("if (-not [string]::IsNullOrWhiteSpace(`$HostEvidenceValidatorPath)) { `$auditArguments.HostEvidenceValidatorPath = `$HostEvidenceValidatorPath }") | Out-Null
  $lines.Add("`$audit = & `$stagingAuditScript @auditArguments") | Out-Null
  $lines.Add("`$expectedCount = [int]`$audit.expectedWorkflowArtifactCount + [int]`$audit.expectedLocalOnlyEvidenceCount") | Out-Null
  $lines.Add("`$presentCount = [int]`$audit.presentWorkflowArtifactCount + [int]`$audit.presentLocalOnlyEvidenceCount") | Out-Null
  $lines.Add("`$missingCount = [int]`$audit.missingWorkflowArtifactCount + [int]`$audit.missingLocalOnlyEvidenceCount") | Out-Null
  $lines.Add("`$invalidCount = [int]`$audit.invalidWorkflowArtifactCount + [int]`$audit.invalidLocalOnlyEvidenceCount") | Out-Null
  $lines.Add("function New-RowState {") | Out-Null
  $lines.Add("  param([object]`$Row, [string]`$CollectionPath, [string]`$Status)") | Out-Null
  $lines.Add("  `$evidence = if (`$Row.PSObject.Properties['evidenceName']) { [string]`$Row.evidenceName } else { [string]`$Row.evidenceFile }") | Out-Null
  $lines.Add("  `$reason = if (`$Row.PSObject.Properties['reason']) { [string]`$Row.reason } else { `"`" }") | Out-Null
  $lines.Add("  [pscustomobject]@{ targetId = [string]`$Row.targetId; nextJsMode = [string]`$Row.nextJsMode; serviceManager = [string]`$Row.serviceManager; reverseProxy = [string]`$Row.reverseProxy; collectionPath = `$CollectionPath; status = `$Status; evidence = `$evidence; reason = `$reason }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("`$rowStates = @(") | Out-Null
  $lines.Add("  @(`$audit.presentWorkflowArtifacts | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'workflow-artifact' -Status 'present' })") | Out-Null
  $lines.Add("  @(`$audit.missingWorkflowArtifacts | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'workflow-artifact' -Status 'missing' })") | Out-Null
  $lines.Add("  @(`$audit.invalidWorkflowArtifacts | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'workflow-artifact' -Status 'invalid' })") | Out-Null
  $lines.Add("  @(`$audit.presentLocalOnlyEvidence | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'local-command-only' -Status 'present' })") | Out-Null
  $lines.Add("  @(`$audit.missingLocalOnlyEvidence | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'local-command-only' -Status 'missing' })") | Out-Null
  $lines.Add("  @(`$audit.invalidLocalOnlyEvidence | ForEach-Object { New-RowState -Row `$_ -CollectionPath 'local-command-only' -Status 'invalid' })") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("`$targetSummary = @(`$rowStates | Group-Object targetId | Sort-Object Name | ForEach-Object { [pscustomobject]@{ targetId = [string]`$_.Name; expected = @(`$_.Group).Count; present = @(`$_.Group | Where-Object { `$_.status -eq 'present' }).Count; missing = @(`$_.Group | Where-Object { `$_.status -eq 'missing' }).Count; invalid = @(`$_.Group | Where-Object { `$_.status -eq 'invalid' }).Count } })") | Out-Null
  $lines.Add("`$unresolved = @(`$rowStates | Where-Object { `$_.status -ne 'present' })") | Out-Null
  $lines.Add("`$report = [ordered]@{") | Out-Null
  $lines.Add("  schemaVersion = 1") | Out-Null
  $lines.Add("  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')") | Out-Null
  $lines.Add("  complete = (`$missingCount -eq 0 -and `$invalidCount -eq 0)") | Out-Null
  $lines.Add("  validationWithHostEvidence = [bool]`$ValidateWithHostEvidence") | Out-Null
  $lines.Add("  expectedCount = `$expectedCount") | Out-Null
  $lines.Add("  presentCount = `$presentCount") | Out-Null
  $lines.Add("  missingCount = `$missingCount") | Out-Null
  $lines.Add("  invalidCount = `$invalidCount") | Out-Null
  $lines.Add("  workflowArtifacts = [ordered]@{ expected = [int]`$audit.expectedWorkflowArtifactCount; present = [int]`$audit.presentWorkflowArtifactCount; missing = [int]`$audit.missingWorkflowArtifactCount; invalid = [int]`$audit.invalidWorkflowArtifactCount }") | Out-Null
  $lines.Add("  localOnlyEvidence = [ordered]@{ expected = [int]`$audit.expectedLocalOnlyEvidenceCount; present = [int]`$audit.presentLocalOnlyEvidenceCount; missing = [int]`$audit.missingLocalOnlyEvidenceCount; invalid = [int]`$audit.invalidLocalOnlyEvidenceCount }") | Out-Null
  $lines.Add("  targetSummary = @(`$targetSummary)") | Out-Null
  $lines.Add("  unresolvedRows = @(`$unresolved)") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("New-Item -ItemType Directory -Path `$OutputDirectory -Force | Out-Null") | Out-Null
  $lines.Add("`$jsonPath = Join-Path `$OutputDirectory 'host-evidence-collection-progress.json'") | Out-Null
  $lines.Add("`$markdownPath = Join-Path `$OutputDirectory 'host-evidence-collection-progress.md'") | Out-Null
  $lines.Add("`$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `$jsonPath -Encoding UTF8") | Out-Null
  $lines.Add("`$markdown = New-Object System.Collections.Generic.List[string]") | Out-Null
  $lines.Add("`$markdown.Add('# Host Evidence Collection Progress') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('- Generated: {0}' -f `$report.generatedAtUtc)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('- Complete: {0}' -f `$report.complete)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('- Full host validation: {0}' -f `$report.validationWithHostEvidence)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('| Collection path | Expected | Present | Missing | Invalid |') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('|---|---:|---:|---:|---:|') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('| Workflow artifacts | {0} | {1} | {2} | {3} |' -f `$report.workflowArtifacts.expected, `$report.workflowArtifacts.present, `$report.workflowArtifacts.missing, `$report.workflowArtifacts.invalid)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('| Local-command-only evidence | {0} | {1} | {2} | {3} |' -f `$report.localOnlyEvidence.expected, `$report.localOnlyEvidence.present, `$report.localOnlyEvidence.missing, `$report.localOnlyEvidence.invalid)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add(('| Total | {0} | {1} | {2} | {3} |' -f `$report.expectedCount, `$report.presentCount, `$report.missingCount, `$report.invalidCount)) | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('## Target Coverage') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('| Target | Expected | Present | Missing | Invalid |') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('|---|---:|---:|---:|---:|') | Out-Null") | Out-Null
  $lines.Add("foreach (`$target in `$report.targetSummary) { `$markdown.Add(('| {0} | {1} | {2} | {3} | {4} |' -f `$target.targetId, `$target.expected, `$target.present, `$target.missing, `$target.invalid)) | Out-Null }") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('## Unresolved Rows') | Out-Null") | Out-Null
  $lines.Add("`$markdown.Add('') | Out-Null") | Out-Null
  $lines.Add("if (`$report.unresolvedRows.Count -eq 0) { `$markdown.Add('All expected real-host evidence rows are present and valid.') | Out-Null } else {") | Out-Null
  $lines.Add("  `$markdown.Add('| Target | Mode | Service | Proxy | Evidence | Reason |') | Out-Null") | Out-Null
  $lines.Add("  `$markdown.Add('|---|---|---|---|---|---|') | Out-Null") | Out-Null
  $lines.Add("  foreach (`$row in `$report.unresolvedRows) {") | Out-Null
  $lines.Add("    `$reason = ([string]`$row.reason).Replace('|', '\\|')") | Out-Null
  $lines.Add("    `$markdown.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `$row.targetId, `$row.nextJsMode, `$row.serviceManager, `$row.reverseProxy, `$row.evidence, `$reason)) | Out-Null") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("`$markdown -join [Environment]::NewLine | Set-Content -LiteralPath `$markdownPath -Encoding UTF8") | Out-Null
  $lines.Add("Write-Host (`"Host evidence collection progress written: `$jsonPath`" )") | Out-Null
  $lines.Add("Write-Host (`"Host evidence collection progress written: `$markdownPath`" )") | Out-Null
  $lines.Add("if (`$PassThru) { [pscustomobject]@{ jsonPath = `$jsonPath; markdownPath = `$markdownPath; report = `$report } }") | Out-Null

  $lines -join [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function New-Readme {
  param(
    [string]$Path,
    [string]$PlanMarkdown,
    [string]$PlanJson,
    [string]$DispatchMarkdown,
    [string]$DispatchScript,
    [string]$DownloadScript,
    [string]$WorkflowArtifactsJson,
    [string]$WorkflowArtifactsCsv,
    [string]$LocalOnlyJson,
    [string]$LocalOnlyCsv,
    [string]$StagingAuditScript,
    [string]$ProgressScript,
    [string]$ReleaseScript,
    [string]$EvidencePath,
    [string]$ArtifactPath,
    [string]$ReleaseOutputDirectory,
    [string]$BundleName
  )

  $tick = [char]96
  $fence = "$tick$tick$tick"
  $planMarkdownName = Split-Path -Leaf $PlanMarkdown
  $planJsonName = Split-Path -Leaf $PlanJson
  $dispatchMarkdownName = Split-Path -Leaf $DispatchMarkdown
  $dispatchScriptName = Split-Path -Leaf $DispatchScript
  $downloadScriptName = Split-Path -Leaf $DownloadScript
  $workflowArtifactsJsonName = Split-Path -Leaf $WorkflowArtifactsJson
  $workflowArtifactsCsvName = Split-Path -Leaf $WorkflowArtifactsCsv
  $localOnlyJsonName = Split-Path -Leaf $LocalOnlyJson
  $localOnlyCsvName = Split-Path -Leaf $LocalOnlyCsv
  $stagingAuditScriptName = Split-Path -Leaf $StagingAuditScript
  $progressScriptName = Split-Path -Leaf $ProgressScript
  $releaseScriptName = Split-Path -Leaf $ReleaseScript
  $artifactDisplayPath = Get-DisplayPath (Resolve-OutputRelativePath $ArtifactPath)
  $evidenceDisplayPath = Get-DisplayPath (Resolve-OutputRelativePath $EvidencePath)
  $releaseOutputDisplayPath = Get-DisplayPath (Resolve-OutputRelativePath $ReleaseOutputDirectory)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Support Evidence Collection Pack") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("This generated pack ties the support matrix to the real-host collection workflow for one release evidence pass.") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Files") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("- {0}{1}{0}: human checklist for every selected target/mode/service/proxy row." -f $tick, $planMarkdownName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: machine-readable plan with workflow inputs and validation commands." -f $tick, $planJsonName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: reviewable {0}gh workflow run host-evidence.yml{0} commands." -f $tick, $dispatchMarkdownName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: guarded dispatcher; prints commands until run with {0}-Run{0}." -f $tick, $dispatchScriptName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: guarded artifact downloader keyed by expected evidence names." -f $tick, $downloadScriptName)) | Out-Null
  $lines.Add(("- {0}{1}{0} / {0}{2}{0}: expected workflow artifact names and canonical destinations." -f $tick, $workflowArtifactsJsonName, $workflowArtifactsCsvName)) | Out-Null
  $lines.Add(("- {0}{1}{0} / {0}{2}{0}: local-command-only rows that must be collected outside GitHub Actions." -f $tick, $localOnlyJsonName, $localOnlyCsvName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: pre-release staging audit for downloaded {0}status.json{0} artifacts, local-only evidence files, and matrix-row identity." -f $tick, $stagingAuditScriptName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: writes JSON and Markdown progress reports with exact missing or invalid real-host rows." -f $tick, $progressScriptName)) | Out-Null
  $lines.Add(("- {0}{1}{0}: guarded release gate; imports artifacts, checks coverage, bundles evidence, and writes detailed readiness plus redacted summary JSON when run with {0}-Run{0}." -f $tick, $releaseScriptName)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Operator Sequence") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("1. Deploy the same release artifact to each target host and keep the private config in the self-hosted runner workspace.") | Out-Null
  $lines.Add(("2. Review {0}{1}{0}, {0}{2}{0}, and {0}{3}{0}." -f $tick, $planMarkdownName, $workflowArtifactsCsvName, $localOnlyCsvName)) | Out-Null
  $lines.Add("3. Review dispatcher output:") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $DispatchScript)") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("4. Dispatch workflow-capable rows only after runner labels point at real Windows, Windows Server, Linux, or macOS hosts:") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $DispatchScript) -Run") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("5. Download successful {0}host-evidence{0} workflow artifacts into {0}{1}{0}. Review run IDs first:" -f $tick, $artifactDisplayPath)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $DownloadScript)") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $DownloadScript) -RunId RUN_ID1,RUN_ID2 -Run") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("   The downloader prints {0}gh run list{0} and exact {0}gh run download --name <evidence_name>{0} commands when run without {0}-Run{0}. Downloaded artifacts are placed in per-evidence folders listed in {0}{1}{0} so the importer can match them back to matrix rows." -f $tick, $workflowArtifactsCsvName)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("6. Collect local-command-only rows listed in {0}{1}{0} on their hosts with the commands from {0}{2}{0}, then place the validated files under {0}{3}{0}." -f $tick, $localOnlyCsvName, $planMarkdownName, $evidenceDisplayPath)) | Out-Null
  $lines.Add("7. Write a collection progress report while evidence is still arriving:") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $ProgressScript)") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $ProgressScript) -ValidateWithHostEvidence") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("   The report writes JSON and Markdown files under the pack's progress directory. Use its unresolved-row table to dispatch or collect the exact missing host/mode/service/proxy combination.") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("8. Audit the staged evidence before running release readiness:") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $StagingAuditScript)") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $StagingAuditScript) -ValidateWithHostEvidence") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $StagingAuditScript) -ValidateWithHostEvidence -HostEvidenceValidatorPath .\scripts\dev\Test-HostEvidence.ps1") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("   Use {0}-ReportOnly{0} for a baseline inventory while collection is still in progress. Without {0}-ReportOnly{0}, the audit fails on missing downloaded {0}status.json{0} artifacts, missing local-only evidence files, or evidence whose target/mode/service/proxy identity does not match the matrix row. Add {0}-ValidateWithHostEvidence{0} to run {0}Test-HostEvidence.ps1{0} against each staged row before the release gate, including uptime, Next.js, reverse-proxy, collector SHA256, and workflow provenance checks. The audit auto-resolves the validator from the repository root or the default {0}evidence\collection-pack{0} location; pass {0}-HostEvidenceValidatorPath{0} if the pack was copied elsewhere." -f $tick)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("9. Run the release gate. It imports downloaded artifacts, refuses incomplete coverage, creates the bundle, and writes {0}release-readiness.json{0} plus {0}release-readiness-summary.json{0}:" -f $tick)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("${fence}powershell") | Out-Null
  $lines.Add("& $(Quote-PowerShellArgument $ReleaseScript) -Run") | Out-Null
  $lines.Add($fence) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("Use {0}-StrictCiRelease{0} on the generated release script only from a clean, committed CI-controlled final signoff path. Add {0}-RequireFinalFullMatrixReleaseClaim{0} with {0}-StrictCiRelease{0} when a release must fail unless readiness proves a final full-matrix claim." -f $tick)) | Out-Null
  $lines.Add(("Publish {0}release-readiness-summary.json{0} as the normal CI/review artifact. Keep the full evidence bundle in restricted private storage unless {0}upload_private_bundle=true{0} is explicitly needed for a separate verifier run; otherwise the self-hosted run is the final CI gate and {0}release-evidence.yml{0} cannot download a bundle from it." -f $tick)) | Out-Null
  $lines.Add(("Reviewers can validate the redacted summary without the private bundle by running {0}Test-ReleaseReadinessSummary.ps1 -InputPath <release-readiness-summary.json> -MatrixPath <support-matrix.json> -RequireFinalFullMatrixReleaseClaim{0}; this checks the final claim, strict CI full-matrix claim kind, complete coverage, clean provenance, required uptime, support matrix SHA256, target count, saved bundleSupportScope target counts, and runtime support tiers." -f $tick)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Output Targets") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("- Evidence path: {0}{1}{0}" -f $tick, $evidenceDisplayPath)) | Out-Null
  $lines.Add(("- Downloaded artifacts: {0}{1}{0}" -f $tick, $artifactDisplayPath)) | Out-Null
  $lines.Add(("- Release evidence output: {0}{1}{0}" -f $tick, $releaseOutputDisplayPath)) | Out-Null
  $lines.Add(("- Bundle name: {0}{1}{0}" -f $tick, $BundleName)) | Out-Null

  $lines -join [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-SelfTest {
  $selfTestRoot = Join-Path $RepoRoot ".tmp\support-evidence-collection-pack-$([Guid]::NewGuid().ToString('N'))"
  $result = & $PSCommandPath `
    -OutputDirectory $selfTestRoot `
    -EvidencePath ".\evidence" `
    -ArtifactPath ".\evidence-downloads" `
    -ReleaseOutputDirectory ".\release-evidence" `
    -BundleName "selftest-support-evidence" `
    -TargetId windows-11,ubuntu,freebsd `
    -IncludeServiceOnly `
    -IncludeFallback `
    -PassThru `
    -Quiet

  foreach ($path in @(
      $result.planJson,
      $result.planMarkdown,
      $result.dispatchMarkdown,
      $result.dispatchScript,
      $result.downloadScript,
      $result.workflowArtifactsJson,
      $result.workflowArtifactsCsv,
      $result.localOnlyJson,
      $result.localOnlyCsv,
      $result.stagingAuditScript,
      $result.progressScript,
      $result.releaseScript,
      $result.readme
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Support evidence collection pack self-test failed: missing generated file $path."
    }
  }

  $plan = Get-Content -LiteralPath $result.planJson -Raw | ConvertFrom-Json
  $selectedTargets = @($plan.filters.selectedTargets)
  if ($selectedTargets.Count -ne 3 -or $selectedTargets -notcontains "windows-11" -or $selectedTargets -notcontains "ubuntu" -or $selectedTargets -notcontains "freebsd") {
    throw "Support evidence collection pack self-test failed: target filter did not select expected workflow and local-only targets."
  }

  $dispatchScriptText = Get-Content -LiteralPath $result.dispatchScript -Raw
  if (-not $dispatchScriptText.Contains("[switch]`$Run")) {
    throw "Support evidence collection pack self-test failed: dispatcher is missing the Run safety switch."
  }
  $downloadScriptText = Get-Content -LiteralPath $result.downloadScript -Raw
  if (-not $downloadScriptText.Contains("gh run download") -or -not $downloadScriptText.Contains("[string[]]`$RunId")) {
    throw "Support evidence collection pack self-test failed: downloader is missing guarded gh run download support."
  }
  if (-not $downloadScriptText.Contains("windows-11-standalone-winsw-iis") -or $downloadScriptText.Contains("windows-server-2012")) {
    throw "Support evidence collection pack self-test failed: downloader did not preserve the scoped expected artifact names."
  }
  if ($downloadScriptText.Contains("freebsd-standalone-bsdrc-nginx")) {
    throw "Support evidence collection pack self-test failed: downloader should not include local-command-only artifacts."
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($result.downloadScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence collection pack self-test failed: generated download script parse errors: $messages"
  }

  $stagingAuditScriptText = Get-Content -LiteralPath $result.stagingAuditScript -Raw
  if (-not $stagingAuditScriptText.Contains("status.json") -or -not $stagingAuditScriptText.Contains("LocalOnlyEvidence")) {
    throw "Support evidence collection pack self-test failed: staging audit script is missing workflow or local-only checks."
  }
  foreach ($expected in @("ValidateWithHostEvidence", "HostEvidenceValidatorPath", "Resolve-HostEvidenceValidatorPath", "Test-HostEvidence.ps1", "RequireCollectorSha256", "RequireHostEvidenceWorkflowCollection", "ExpectedMatrixSha256", "ExpectedMatrixPath", "MatrixPath", "RequiredMinimumUptimeHours")) {
    if (-not $stagingAuditScriptText.Contains($expected)) {
      throw "Support evidence collection pack self-test failed: staging audit script is missing '$expected'."
    }
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($result.stagingAuditScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence collection pack self-test failed: generated staging audit script parse errors: $messages"
  }

  $progressScriptText = Get-Content -LiteralPath $result.progressScript -Raw
  foreach ($expected in @("host-evidence-collection-progress.json", "host-evidence-collection-progress.md", "unresolvedRows", "targetSummary", "Target Coverage", "ValidateWithHostEvidence")) {
    if (-not $progressScriptText.Contains($expected)) {
      throw "Support evidence collection pack self-test failed: progress script is missing '$expected'."
    }
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($result.progressScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence collection pack self-test failed: generated progress script parse errors: $messages"
  }

  $releaseScriptText = Get-Content -LiteralPath $result.releaseScript -Raw
  if (-not $releaseScriptText.Contains("Invoke-SupportEvidenceReleaseWorkflow.ps1")) {
    throw "Support evidence collection pack self-test failed: release script does not call the release workflow."
  }
  if (-not $releaseScriptText.Contains("-IncludeServiceOnly") -or -not $releaseScriptText.Contains("-IncludeFallback")) {
    throw "Support evidence collection pack self-test failed: release script did not preserve evidence scope switches."
  }
  if (-not $releaseScriptText.Contains("RequireFinalFullMatrixReleaseClaim")) {
    throw "Support evidence collection pack self-test failed: release script did not expose the final full-matrix claim gate."
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($result.releaseScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence collection pack self-test failed: generated release script parse errors: $messages"
  }

  $readmeText = Get-Content -LiteralPath $result.readme -Raw
  foreach ($expected in @("expected-workflow-artifacts.csv", "local-command-only-evidence.csv", "Test-HostEvidenceCollectionStaging", "ValidateWithHostEvidence", "HostEvidenceValidatorPath", "Test-HostEvidence.ps1", "Test-ReleaseReadinessSummary.ps1", "-MatrixPath", "strict CI full-matrix claim kind", "support matrix SHA256", "bundleSupportScope target counts", "runtime support tiers", "Invoke-HostEvidenceArtifactDownload", "gh run download", "StrictCiRelease", "RequireFinalFullMatrixReleaseClaim", "local-command-only", "release-readiness", "release-readiness-summary.json", "upload_private_bundle=true", "restricted private storage", "self-hosted run is the final CI gate", "release-evidence.yml")) {
    if (-not $readmeText.Contains($expected)) {
      throw "Support evidence collection pack self-test failed: README is missing '$expected'."
    }
  }
  $workflowArtifactManifest = @(Get-Content -LiteralPath $result.workflowArtifactsJson -Raw | ConvertFrom-Json)
  if ($workflowArtifactManifest.Count -lt 1 -or @($workflowArtifactManifest | Where-Object { [string]$_.evidenceName -eq "windows-11-standalone-winsw-iis" }).Count -ne 1) {
    throw "Support evidence collection pack self-test failed: workflow artifact manifest is missing windows-11 standalone WinSW IIS evidence."
  }
  if (@($workflowArtifactManifest | Where-Object { [string]$_.targetId -eq "freebsd" }).Count -ne 0) {
    throw "Support evidence collection pack self-test failed: workflow artifact manifest included local-command-only FreeBSD rows."
  }
  $localOnlyManifest = @(Get-Content -LiteralPath $result.localOnlyJson -Raw | ConvertFrom-Json)
  if ($localOnlyManifest.Count -lt 1 -or @($localOnlyManifest | Where-Object { [string]$_.targetId -eq "freebsd" }).Count -lt 1) {
    throw "Support evidence collection pack self-test failed: local-only manifest is missing FreeBSD rows."
  }

  $stagingArtifactRoot = Join-Path $selfTestRoot "downloaded-artifacts"
  $stagingEvidenceRoot = Join-Path $selfTestRoot "local-evidence"
  $firstWorkflowArtifact = $workflowArtifactManifest[0]
  $firstWorkflowArtifactPath = Join-Path $stagingArtifactRoot ([string]$firstWorkflowArtifact.evidenceName)
  New-Item -ItemType Directory -Path $firstWorkflowArtifactPath -Force | Out-Null
  $firstWorkflowEvidence = [ordered]@{
    supportTargetId = [string]$firstWorkflowArtifact.targetId
    platform = [ordered]@{
      serviceManager = [string]$firstWorkflowArtifact.serviceManager
    }
    nextJsRuntime = [ordered]@{
      mode = [string]$firstWorkflowArtifact.nextJsMode
    }
    reverseProxy = [ordered]@{
      mode = [string]$firstWorkflowArtifact.reverseProxy
    }
  }
  $firstWorkflowStatusPath = Join-Path $firstWorkflowArtifactPath "status.json"
  $firstWorkflowEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $firstWorkflowStatusPath -Encoding UTF8

  $firstLocalOnlyEvidence = $localOnlyManifest[0]
  $relativeEvidenceFile = ([string]$firstLocalOnlyEvidence.evidenceFile) -replace "\\", "/"
  if ($relativeEvidenceFile.StartsWith("evidence/", [StringComparison]::OrdinalIgnoreCase)) {
    $relativeEvidenceFile = $relativeEvidenceFile.Substring("evidence/".Length)
  }
  $firstLocalOnlyEvidencePath = $stagingEvidenceRoot
  foreach ($pathPart in @($relativeEvidenceFile -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $firstLocalOnlyEvidencePath = Join-Path $firstLocalOnlyEvidencePath $pathPart
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $firstLocalOnlyEvidencePath) -Force | Out-Null
  $firstLocalOnlyEvidenceJson = [ordered]@{
    supportTargetId = [string]$firstLocalOnlyEvidence.targetId
    platform = [ordered]@{
      serviceManager = [string]$firstLocalOnlyEvidence.serviceManager
    }
    nextJsRuntime = [ordered]@{
      mode = [string]$firstLocalOnlyEvidence.nextJsMode
    }
    reverseProxy = [ordered]@{
      mode = [string]$firstLocalOnlyEvidence.reverseProxy
    }
  }
  $firstLocalOnlyEvidenceJson | ConvertTo-Json -Depth 8 | Set-Content -Path $firstLocalOnlyEvidencePath -Encoding UTF8

  $stagingAudit = & $result.stagingAuditScript `
    -ArtifactPath $stagingArtifactRoot `
    -EvidencePath $stagingEvidenceRoot `
    -ReportOnly `
    -PassThru
  if ($stagingAudit.expectedWorkflowArtifactCount -ne $workflowArtifactManifest.Count -or $stagingAudit.expectedLocalOnlyEvidenceCount -ne $localOnlyManifest.Count) {
    throw "Support evidence collection pack self-test failed: staging audit expected counts do not match generated manifests."
  }
  if ($stagingAudit.presentWorkflowArtifactCount -lt 1 -or $stagingAudit.presentLocalOnlyEvidenceCount -lt 1) {
    throw "Support evidence collection pack self-test failed: staging audit did not detect staged workflow and local-only evidence."
  }
  if ($stagingAudit.invalidWorkflowArtifactCount -ne 0 -or $stagingAudit.invalidLocalOnlyEvidenceCount -ne 0) {
    throw "Support evidence collection pack self-test failed: staging audit marked matching staged evidence as invalid."
  }
  $validationAudit = & $result.stagingAuditScript `
    -ArtifactPath $stagingArtifactRoot `
    -EvidencePath $stagingEvidenceRoot `
    -ValidateWithHostEvidence `
    -ReportOnly `
    -PassThru
  if ($validationAudit.invalidWorkflowArtifactCount -lt 1 -or $validationAudit.invalidLocalOnlyEvidenceCount -lt 1) {
    throw "Support evidence collection pack self-test failed: staging audit did not run full host evidence validation."
  }
  if ($workflowArtifactManifest.Count -gt 1 -and $stagingAudit.missingWorkflowArtifactCount -lt 1) {
    throw "Support evidence collection pack self-test failed: staging audit did not detect missing workflow artifacts."
  }
  if ($localOnlyManifest.Count -gt 1 -and $stagingAudit.missingLocalOnlyEvidenceCount -lt 1) {
    throw "Support evidence collection pack self-test failed: staging audit did not detect missing local-only evidence."
  }

  $progressOutputDirectory = Join-Path $selfTestRoot "progress"
  $progress = & $result.progressScript `
    -ArtifactPath $stagingArtifactRoot `
    -EvidencePath $stagingEvidenceRoot `
    -OutputDirectory $progressOutputDirectory `
    -PassThru
  if (-not (Test-Path -LiteralPath $progress.jsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $progress.markdownPath -PathType Leaf)) {
    throw "Support evidence collection pack self-test failed: progress script did not write both report formats."
  }
  if ($progress.report.expectedCount -ne ($stagingAudit.expectedWorkflowArtifactCount + $stagingAudit.expectedLocalOnlyEvidenceCount) -or $progress.report.unresolvedRows.Count -lt 1 -or $progress.report.targetSummary.Count -ne 3) {
    throw "Support evidence collection pack self-test failed: progress report did not preserve the staged evidence inventory."
  }

  $firstWorkflowEvidence.supportTargetId = "mismatched-target"
  $firstWorkflowEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $firstWorkflowStatusPath -Encoding UTF8
  $firstLocalOnlyEvidenceJson.nextJsRuntime.mode = "mismatched-mode"
  $firstLocalOnlyEvidenceJson | ConvertTo-Json -Depth 8 | Set-Content -Path $firstLocalOnlyEvidencePath -Encoding UTF8
  $mismatchAudit = & $result.stagingAuditScript `
    -ArtifactPath $stagingArtifactRoot `
    -EvidencePath $stagingEvidenceRoot `
    -ReportOnly `
    -PassThru
  if ($mismatchAudit.invalidWorkflowArtifactCount -lt 1 -or $mismatchAudit.invalidLocalOnlyEvidenceCount -lt 1) {
    throw "Support evidence collection pack self-test failed: staging audit did not detect mismatched workflow and local-only evidence identity."
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$planJson = Join-Path $OutputDirectory "support-evidence-plan.json"
$planMarkdown = Join-Path $OutputDirectory "support-evidence-plan.md"
$dispatchMarkdown = Join-Path $OutputDirectory "host-evidence-dispatch.md"
$dispatchScript = Join-Path $OutputDirectory "Invoke-HostEvidenceDispatch.ps1"
$downloadScript = Join-Path $OutputDirectory "Invoke-HostEvidenceArtifactDownload.ps1"
$workflowArtifactsJson = Join-Path $OutputDirectory "expected-workflow-artifacts.json"
$workflowArtifactsCsv = Join-Path $OutputDirectory "expected-workflow-artifacts.csv"
$localOnlyJson = Join-Path $OutputDirectory "local-command-only-evidence.json"
$localOnlyCsv = Join-Path $OutputDirectory "local-command-only-evidence.csv"
$stagingAuditScript = Join-Path $OutputDirectory "Test-HostEvidenceCollectionStaging.ps1"
$progressScript = Join-Path $OutputDirectory "Get-HostEvidenceCollectionProgress.ps1"
$releaseScript = Join-Path $OutputDirectory "Invoke-SupportEvidenceRelease.ps1"
$readme = Join-Path $OutputDirectory "README.md"

$basePlanArgs = @{
  MatrixPath = $MatrixPath
  WorkflowFile = $WorkflowFile
  WorkflowRef = $WorkflowRef
  Quiet = $true
}
Add-PlanFilterArguments -Arguments $basePlanArgs

$planJsonArgs = $basePlanArgs.Clone()
$planJsonArgs.Format = "Json"
$planJsonArgs.OutputPath = $planJson
& (Join-Path $ScriptDir "New-SupportEvidencePlan.ps1") @planJsonArgs | Out-Null

$planMarkdownArgs = $basePlanArgs.Clone()
$planMarkdownArgs.Format = "Markdown"
$planMarkdownArgs.OutputPath = $planMarkdown
& (Join-Path $ScriptDir "New-SupportEvidencePlan.ps1") @planMarkdownArgs | Out-Null

$dispatchMarkdownArgs = $basePlanArgs.Clone()
$dispatchMarkdownArgs.Format = "DispatchMarkdown"
$dispatchMarkdownArgs.OutputPath = $dispatchMarkdown
& (Join-Path $ScriptDir "New-SupportEvidencePlan.ps1") @dispatchMarkdownArgs | Out-Null

$dispatchScriptArgs = $basePlanArgs.Clone()
$dispatchScriptArgs.Format = "DispatchPowerShell"
$dispatchScriptArgs.OutputPath = $dispatchScript
& (Join-Path $ScriptDir "New-SupportEvidencePlan.ps1") @dispatchScriptArgs | Out-Null

$plan = Get-Content -LiteralPath $planJson -Raw | ConvertFrom-Json
New-CollectionManifestFiles `
  -Plan $plan `
  -ArtifactPath $ArtifactPath `
  -WorkflowArtifactsJson $workflowArtifactsJson `
  -WorkflowArtifactsCsv $workflowArtifactsCsv `
  -LocalOnlyJson $localOnlyJson `
  -LocalOnlyCsv $localOnlyCsv

New-ArtifactDownloadScript `
  -Path $downloadScript `
  -Plan $plan `
  -ArtifactPath $ArtifactPath `
  -WorkflowFile $WorkflowFile `
  -WorkflowRef $WorkflowRef

New-StagingAuditScript `
  -Path $stagingAuditScript `
  -Plan $plan `
  -ArtifactPath $ArtifactPath `
  -EvidencePath $EvidencePath `
  -MatrixPath (Get-DisplayPath -Path $MatrixPath)

New-CollectionProgressScript `
  -Path $progressScript `
  -StagingAuditScript $stagingAuditScript `
  -ArtifactPath $ArtifactPath `
  -EvidencePath $EvidencePath

New-ReleaseCommandScript `
  -Path $releaseScript `
  -EvidencePath $EvidencePath `
  -ArtifactPath $ArtifactPath `
  -ReleaseOutputDirectory $ReleaseOutputDirectory `
  -BundleName $BundleName `
  -MatrixPath (Get-DisplayPath -Path $MatrixPath)

New-Readme `
  -Path $readme `
  -PlanMarkdown $planMarkdown `
  -PlanJson $planJson `
  -DispatchMarkdown $dispatchMarkdown `
  -DispatchScript $dispatchScript `
  -DownloadScript $downloadScript `
  -WorkflowArtifactsJson $workflowArtifactsJson `
  -WorkflowArtifactsCsv $workflowArtifactsCsv `
  -LocalOnlyJson $localOnlyJson `
  -LocalOnlyCsv $localOnlyCsv `
  -StagingAuditScript $stagingAuditScript `
  -ProgressScript $progressScript `
  -ReleaseScript $releaseScript `
  -EvidencePath $EvidencePath `
  -ArtifactPath $ArtifactPath `
  -ReleaseOutputDirectory $ReleaseOutputDirectory `
  -BundleName $BundleName

$result = [pscustomobject]@{
  outputDirectory = $OutputDirectory
  planJson = $planJson
  planMarkdown = $planMarkdown
  dispatchMarkdown = $dispatchMarkdown
  dispatchScript = $dispatchScript
  downloadScript = $downloadScript
  workflowArtifactsJson = $workflowArtifactsJson
  workflowArtifactsCsv = $workflowArtifactsCsv
  localOnlyJson = $localOnlyJson
  localOnlyCsv = $localOnlyCsv
  stagingAuditScript = $stagingAuditScript
  progressScript = $progressScript
  releaseScript = $releaseScript
  readme = $readme
}

if (-not $Quiet) {
  Write-Host ""
  Write-Host "==> Support evidence collection pack"
  Write-Host "Output directory: $OutputDirectory"
  Write-Host "Plan: $planMarkdown"
  Write-Host "Dispatcher: $dispatchScript"
  Write-Host "Downloader: $downloadScript"
  Write-Host "Workflow artifacts: $workflowArtifactsCsv"
  Write-Host "Local-only rows: $localOnlyCsv"
  Write-Host "Staging audit: $stagingAuditScript"
  Write-Host "Collection progress: $progressScript"
  Write-Host "Release gate: $releaseScript"
}

if ($PassThru) {
  $result
}
