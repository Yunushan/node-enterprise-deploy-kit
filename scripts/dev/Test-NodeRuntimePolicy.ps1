Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDirectory = $PSScriptRoot
. (Join-Path $scriptDirectory "NodeRuntimePolicy.ps1")

$reviewDate = [datetime]"2026-10-07T00:00:00Z"
foreach ($version in @('v22.0.0', 'v24.0.0', 'v26.0.0')) {
  if (-not (Test-SupportedNodeRuntimeVersion -Version $version -AsOfUtc $reviewDate)) { throw "$version should be maintained at policy review time." }
}
foreach ($version in @('v20.19.0', 'v25.0.0', 'v99.0.0', 'v26.0.0 C:\unsafe\path', '')) {
  if (Test-SupportedNodeRuntimeVersion -Version $version -AsOfUtc $reviewDate) { throw "Unsupported runtime '$version' was accepted." }
}
if (Test-SupportedNodeRuntimeVersion -Version 'v22.0.0' -AsOfUtc ([datetime]'2027-04-30T00:00:00Z')) { throw 'Node 22 must expire on its scheduled EOL date.' }

# Exercise the actual functions used by all three validators without their
# top-level artifact collection/self-tests. No synthetic host files are written.
foreach ($validatorName in @('Test-HostEvidence.ps1', 'Test-SupportEvidenceBundle.ps1', 'Test-SupportEvidenceCoverage.ps1')) {
  & {
    param($validatorPath, $policyPath)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($validatorPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot parse $validatorPath." }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
      . ([scriptblock]::Create($definition.Extent.Text))
    }
    . $policyPath
    foreach ($case in @(
        @{ Version = 'v22.0.0'; Os = '10.15'; Arch = 'x86_64'; Accepted = $false },
        @{ Version = 'v22.0.0'; Os = '11.0'; Arch = 'x86_64'; Accepted = $true },
        @{ Version = 'v24.0.0'; Os = '12.0'; Arch = 'arm64'; Accepted = $false },
        @{ Version = 'v26.0.0'; Os = '13.4'; Arch = 'arm64'; Accepted = $false },
        @{ Version = 'v26.0.0'; Os = '13.5'; Arch = 'arm64'; Accepted = $true },
        @{ Version = 'v26.0.0'; Os = '15.0'; Arch = 'unknown'; Accepted = $false },
        @{ Version = 'v99.0.0'; Os = '15.0'; Arch = 'arm64'; Accepted = $false }
      )) {
      $evidence = [pscustomobject]@{
        platform = [pscustomobject]@{ machine = $case.Arch; osVersionId = $case.Os }
        nextJsRuntime = [pscustomobject]@{ nodeVersion = $case.Version }
      }
      if ([IO.Path]::GetFileName($validatorPath) -eq 'Test-SupportEvidenceCoverage.ps1') {
        $accepted = Test-NextJsPlatformRuntimeFloor -Evidence $evidence -SupportTargetId macos
      } else {
        $arguments = @{ Evidence = $evidence; SupportTargetId = 'macos' }
        if ([IO.Path]::GetFileName($validatorPath) -eq 'Test-HostEvidence.ps1') { $arguments.FileName = 'runtime-policy-test.json' } else { $arguments.Context = 'runtime-policy-test.json' }
        $accepted = @(Get-NextJsPlatformRuntimeIssues @arguments).Count -eq 0
      }
      if ($accepted -ne $case.Accepted) { throw "$validatorPath returned wrong result for Node $($case.Version), macOS $($case.Os), $($case.Arch)." }
    }
  } (Join-Path $scriptDirectory $validatorName) (Join-Path $scriptDirectory 'NodeRuntimePolicy.ps1')
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
  & {
    param($preflightPath)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($preflightPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Windows preflight source did not parse.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
    $script:preflightVersion = ''
    $script:preflightIssues = [Collections.Generic.List[string]]::new()
    function Get-NodeRuntimeVersion { param($NodeExe); $script:preflightVersion }
    function Add-Error { param([string]$Message); [void]$script:preflightIssues.Add($Message) }
    $config = [pscustomobject]@{ NodeExe = 'fixture-node' }
    foreach ($version in @('v20.11.1', 'v25.0.0', 'v99.0.0', '')) {
      $script:preflightVersion = $version; $script:preflightIssues.Clear()
      Test-MaintainedNodeRuntime $config
      if ($script:preflightIssues.Count -ne 1) { throw "Actual Windows preflight accepted unsupported runtime '$version'." }
    }
    foreach ($version in @('v22.11.1', 'v24.0.0', 'v26.0.0')) {
      $script:preflightVersion = $version; $script:preflightIssues.Clear()
      Test-MaintainedNodeRuntime $config
      if ($script:preflightIssues.Count -ne 0) { throw "Actual Windows preflight rejected maintained runtime '$version'." }
    }
    function Get-Date { [datetime]'2027-04-30T00:00:00Z' }
    $script:preflightVersion = 'v22.11.1'; $script:preflightIssues.Clear()
    Test-MaintainedNodeRuntime $config
    if ($script:preflightIssues.Count -ne 1) { throw 'Actual Windows preflight failed to expire Node22 on its scheduled EOL date.' }
  } (Join-Path $scriptDirectory '../windows/Test-DeploymentPreflight.ps1')
}
Write-Host "Node lifecycle, evidence-validator platform floors and Windows preflight runtime checks OK"
