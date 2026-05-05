param(
  [switch]$SkipShellRenderedSyntax,
  [switch]$SkipAnsibleSyntax
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Get-RelativePath {
  param([string]$Path)
  return $Path.Substring($RepoRoot.Length + 1).Replace("\", "/")
}

function Assert-RequiredValue {
  param(
    [hashtable]$Values,
    [string[]]$Keys,
    [string]$Source
  )

  foreach ($key in $Keys) {
    if (-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
      throw "$Source is missing required value: $key"
    }
  }
}

function ConvertTo-StringMap {
  param([object]$Object)

  $map = @{}
  foreach ($property in $Object.PSObject.Properties) {
    $map[$property.Name] = [string]$property.Value
  }
  return $map
}

function Read-EnvExample {
  param([string]$Path)

  $values = @{}
  $lineNumber = 0
  foreach ($line in Get-Content -Path $Path) {
    $lineNumber++
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
    if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      throw "$(Get-RelativePath $Path):$lineNumber is not KEY=value syntax."
    }

    $key = $Matches[1]
    $value = $Matches[2].Trim()
    if ($values.ContainsKey($key)) {
      throw "$(Get-RelativePath $Path):$lineNumber duplicates $key."
    }

    if (
      ($value.StartsWith('"') -and $value.EndsWith('"')) -or
      ($value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $values[$key] = $value
  }

  return $values
}

function Assert-Port {
  param(
    [string]$Value,
    [string]$Name
  )

  $port = 0
  if (-not [int]::TryParse($Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    throw "$Name must be an integer between 1 and 65535."
  }
}

function Assert-IntegerAtLeast {
  param(
    [string]$Value,
    [string]$Name,
    [int]$Minimum = 1
  )

  $number = 0
  if (-not [int]::TryParse($Value, [ref]$number) -or $number -lt $Minimum) {
    throw "$Name must be an integer >= $Minimum."
  }
}

function Assert-BoolString {
  param(
    [string]$Value,
    [string]$Name
  )

  if ($Value -notin @("true", "false")) {
    throw "$Name must be true or false."
  }
}

function Test-WindowsExampleConfig {
  Write-Step "Windows example config"
  $path = Join-Path $RepoRoot "config/windows/app.config.example.json"
  $config = Get-Content -Path $path -Raw | ConvertFrom-Json
  $values = ConvertTo-StringMap $config

  Assert-RequiredValue $values @(
    "AppName",
    "DisplayName",
    "Description",
    "DeploymentMode",
    "ServiceManager",
    "ReverseProxy",
    "AppDirectory",
    "StartCommand",
    "NodeExe",
    "Port",
    "BindAddress",
    "HealthUrl",
    "ServiceDirectory",
    "LogDirectory",
    "BackupDirectory",
    "IisEnableArrProxy",
    "IisSetForwardedHeaders",
    "IisHealthProxyPath",
    "IisWebSocketSupport",
    "IisProxyTimeoutSeconds",
    "ServiceAccount"
  ) "config/windows/app.config.example.json"
  if (-not $config.PSObject.Properties["ServiceAccountPassword"]) {
    throw "config/windows/app.config.example.json is missing ServiceAccountPassword."
  }

  Assert-Port ([string]$config.Port) "Windows Port"
  Assert-Port ([string]$config.PublicPort) "Windows PublicPort"
  Assert-IntegerAtLeast ([string]$config.HealthCheckIntervalMinutes) "HealthCheckIntervalMinutes"
  Assert-IntegerAtLeast ([string]$config.FailureRestartDelaySeconds) "FailureRestartDelaySeconds"
  Assert-IntegerAtLeast ([string]$config.HealthCheckFailureThreshold) "HealthCheckFailureThreshold"
  Assert-IntegerAtLeast ([string]$config.HealthCheckRestartCooldownMinutes) "HealthCheckRestartCooldownMinutes"
  Assert-IntegerAtLeast ([string]$config.HealthCheckTimeoutSeconds) "HealthCheckTimeoutSeconds"
  Assert-IntegerAtLeast ([string]$config.LogRetentionDays) "LogRetentionDays"
  Assert-IntegerAtLeast ([string]$config.BackupRetentionDays) "BackupRetentionDays"
  Assert-IntegerAtLeast ([string]$config.DiagnosticRetentionDays) "DiagnosticRetentionDays"
  Assert-IntegerAtLeast ([string]$config.IisProxyTimeoutSeconds) "IisProxyTimeoutSeconds"
  foreach ($name in @("TlsEnabled", "IisEnableArrProxy", "IisSetForwardedHeaders", "IisWebSocketSupport")) {
    Assert-BoolString ([string]$config.$name) $name
  }
  $iisHealthProxyPath = ([string]$config.IisHealthProxyPath).Trim() -replace "\\", "/"
  $iisHealthProxyPath = $iisHealthProxyPath.Trim("/")
  if ([string]::IsNullOrWhiteSpace($iisHealthProxyPath) -or $iisHealthProxyPath -match '(^|/)\.\.($|/)' -or $iisHealthProxyPath -notmatch '^[A-Za-z0-9._~/-]+$') {
    throw "Windows IisHealthProxyPath must be a safe relative URL path."
  }

  $healthUri = [Uri][string]$config.HealthUrl
  if ($healthUri.Scheme -notin @("http", "https")) {
    throw "Windows HealthUrl must use http or https."
  }
  if ($healthUri.Host -notin @("127.0.0.1", "localhost")) {
    throw "Windows HealthUrl should default to localhost/127.0.0.1."
  }
  if ($config.Environment -and $config.Environment.PSObject.Properties["PORT"]) {
    if ([string]$config.Environment.PORT -ne [string]$config.Port) {
      throw "Windows Environment.PORT must match Port in the example config."
    }
  }
  foreach ($name in @("APP_PORT", "APP_NAME", "BIND_ADDRESS", "HOST", "HOSTNAME")) {
    if (-not $config.Environment.PSObject.Properties[$name]) {
      throw "Windows example Environment is missing $name."
    }
  }
  if ([string]$config.Environment.APP_PORT -ne [string]$config.Port) {
    throw "Windows Environment.APP_PORT must match Port in the example config."
  }
  if ([string]$config.BindAddress -ne "127.0.0.1") {
    throw "Windows BindAddress should default to 127.0.0.1."
  }
  if ([string]$config.ServiceAccount -eq "LocalSystem") {
    throw "Windows ServiceAccount example should not default to LocalSystem."
  }
  foreach ($name in @("BIND_ADDRESS", "HOST", "HOSTNAME")) {
    if ([string]$config.Environment.$name -ne [string]$config.BindAddress) {
      throw "Windows Environment.$name must match BindAddress in the example config."
    }
  }

  Write-Host "Windows example config OK"
  return $config
}

function Test-LinuxExampleConfig {
  Write-Step "Linux example env"
  $path = Join-Path $RepoRoot "config/linux/app.env.example"
  $env = Read-EnvExample $path

  Assert-RequiredValue $env @(
    "APP_NAME",
    "APP_DISPLAY_NAME",
    "APP_DESCRIPTION",
    "DEPLOYMENT_MODE",
    "APP_RUNTIME",
    "SERVICE_MANAGER",
    "REVERSE_PROXY",
    "APP_DIR",
    "NODE_BIN",
    "START_SCRIPT",
    "APP_PORT",
    "BIND_ADDRESS",
    "HEALTH_URL",
    "SERVICE_USER",
    "SERVICE_GROUP",
    "LOG_DIR",
    "ENV_FILE",
    "BACKUP_DIR",
    "HEALTHCHECK_STATE_DIR"
  ) "config/linux/app.env.example"

  Assert-Port $env.APP_PORT "Linux APP_PORT"
  Assert-Port $env.PUBLIC_PORT "Linux PUBLIC_PORT"
  foreach ($name in @("HEALTHCHECK_INTERVAL", "HEALTHCHECK_FAILURE_THRESHOLD", "HEALTHCHECK_RESTART_COOLDOWN", "HEALTHCHECK_TIMEOUT", "FAILURE_RESTART_DELAY", "LOG_RETENTION_DAYS", "BACKUP_RETENTION_DAYS", "DIAGNOSTIC_RETENTION_DAYS")) {
    Assert-IntegerAtLeast $env[$name] $name
  }
  foreach ($name in @("SKIP_PREFLIGHT", "ALLOW_PORT_IN_USE", "SKIP_REVERSE_PROXY", "SKIP_HEALTH_CHECK", "SKIP_INSTALL", "SKIP_BUILD", "TLS_ENABLED", "TOMCAT_RESTART")) {
    Assert-BoolString $env[$name] $name
  }
  if ($env.APP_RUNTIME -notin @("node", "tomcat")) {
    throw "Linux APP_RUNTIME must be node or tomcat."
  }
  if ($env.SERVICE_MANAGER -notin @("systemd", "systemv", "openrc", "launchd", "bsdrc")) {
    throw "Linux SERVICE_MANAGER must be systemd, systemv, openrc, launchd, or bsdrc."
  }
  if ($env.REVERSE_PROXY -notin @("nginx", "apache", "haproxy", "traefik", "none")) {
    throw "Linux REVERSE_PROXY must be nginx, apache, haproxy, traefik, or none."
  }

  $healthUri = [Uri]$env.HEALTH_URL
  if ($healthUri.Scheme -notin @("http", "https")) {
    throw "Linux HEALTH_URL must use http or https."
  }
  if ($healthUri.Host -notin @("127.0.0.1", "localhost")) {
    throw "Linux HEALTH_URL should default to localhost/127.0.0.1."
  }
  if ($healthUri.Port -ne [int]$env.APP_PORT) {
    throw "Linux HEALTH_URL port must match APP_PORT in the example env."
  }
  if ($env.BIND_ADDRESS -ne "127.0.0.1") {
    throw "Linux BIND_ADDRESS should default to 127.0.0.1."
  }
  if ($env.SERVICE_USER -eq "root" -or $env.SERVICE_GROUP -eq "root") {
    throw "Linux SERVICE_USER/SERVICE_GROUP examples should not default to root."
  }
  if (-not $env.HEALTHCHECK_STATE_DIR.StartsWith("/")) {
    throw "Linux HEALTHCHECK_STATE_DIR should be an absolute root-owned state path."
  }
  if ($env.HEALTHCHECK_STATE_DIR.TrimEnd("/") -eq $env.LOG_DIR.TrimEnd("/") -or $env.HEALTHCHECK_STATE_DIR.StartsWith($env.LOG_DIR.TrimEnd("/") + "/")) {
    throw "Linux HEALTHCHECK_STATE_DIR must not be inside LOG_DIR."
  }
  if ($env.TLS_ENABLED -ne "true") {
    throw "Linux TLS_ENABLED should default to true."
  }

  Write-Host "Linux example env OK"
  return $env
}

function Test-AnsibleDefaults {
  Write-Step "Ansible example variables"
  $path = Join-Path $RepoRoot "config/ansible/group_vars_all.example.yml"
  $text = Get-Content -Path $path -Raw
  $requiredNames = @(
    "node_deploy_project_name",
    "node_deploy_display_name",
    "node_deploy_description",
    "node_deploy_mode",
    "node_deploy_app_runtime",
    "node_deploy_skip_preflight",
    "node_deploy_allow_port_in_use",
    "node_deploy_skip_install",
    "node_deploy_skip_build",
    "node_deploy_skip_reverse_proxy",
    "node_deploy_skip_health_check",
    "node_deploy_windows_winsw_source",
    "node_deploy_windows_iis_enable_arr_proxy",
    "node_deploy_windows_iis_set_forwarded_headers",
    "node_deploy_windows_iis_health_proxy_path",
    "node_deploy_windows_iis_websocket_support",
    "node_deploy_windows_iis_proxy_timeout_seconds",
    "node_deploy_windows_service_account_password",
    "node_deploy_windows_backup_dir",
    "node_deploy_linux_deploy_dir",
    "node_deploy_linux_config_path",
    "node_deploy_linux_env_file",
    "node_deploy_linux_backup_dir",
    "node_deploy_linux_nginx_config_dir",
    "node_deploy_linux_nginx_service",
    "node_deploy_linux_apache_config_dir",
    "node_deploy_linux_apache_service",
    "node_deploy_linux_haproxy_config_file",
    "node_deploy_linux_haproxy_bind",
    "node_deploy_linux_haproxy_frontend_name",
    "node_deploy_linux_haproxy_backend_name",
    "node_deploy_linux_haproxy_service",
    "node_deploy_linux_traefik_dynamic_dir",
    "node_deploy_linux_traefik_dynamic_file",
    "node_deploy_linux_traefik_entrypoint",
    "node_deploy_linux_traefik_router_name",
    "node_deploy_linux_traefik_service_name",
    "node_deploy_linux_traefik_service",
    "node_deploy_linux_healthcheck_path",
    "node_deploy_linux_healthcheck_state_dir",
    "node_deploy_tomcat_package",
    "node_deploy_tomcat_service",
    "node_deploy_tomcat_webapps_dir",
    "node_deploy_tomcat_war_file",
    "node_deploy_tomcat_context_path",
    "node_deploy_tomcat_restart",
    "node_deploy_linux_nginx_package",
    "node_deploy_linux_apache_package",
    "node_deploy_linux_haproxy_package",
    "node_deploy_linux_traefik_package",
    "node_deploy_healthcheck_failure_threshold",
    "node_deploy_healthcheck_restart_cooldown_seconds",
    "node_deploy_healthcheck_timeout_seconds",
    "node_deploy_log_retention_days",
    "node_deploy_backup_retention_days",
    "node_deploy_diagnostic_retention_days"
  )

  foreach ($name in $requiredNames) {
    if ($text -notmatch "(?m)^$([regex]::Escape($name))\s*:") {
      throw "config/ansible/group_vars_all.example.yml is missing $name."
    }
  }

  Write-Host "Ansible example variables OK"
}

function Get-TemplateTokens {
  param([string]$Text)

  $tokens = New-Object System.Collections.Generic.HashSet[string]
  foreach ($match in [regex]::Matches($Text, '\{\{([A-Z][A-Z0-9_]*)\}\}')) {
    [void]$tokens.Add($match.Groups[1].Value)
  }
  return @($tokens | Sort-Object)
}

function Render-TokenTemplate {
  param(
    [string]$Text,
    [hashtable]$Values,
    [string]$Source
  )

  foreach ($token in Get-TemplateTokens $Text) {
    if (-not $Values.ContainsKey($token)) {
      throw "$Source references unknown template token: $token"
    }
    $escapedToken = [regex]::Escape("{{$token}}")
    $Text = [regex]::Replace($Text, $escapedToken, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) [string]$Values[$token] })
  }

  if ($Text -match '\{\{[A-Z][A-Z0-9_]*\}\}') {
    throw "$Source still contains unresolved template tokens."
  }
  return $Text
}

function Test-JinjaDelimiters {
  Write-Step "Ansible template delimiters"
  $files = Get-ChildItem -Path (Join-Path $RepoRoot "ansible/roles") -Recurse -File -Filter "*.j2"
  foreach ($file in $files) {
    $text = Get-Content -Path $file.FullName -Raw
    foreach ($pair in @(
      @{ Open = "{{"; Close = "}}" },
      @{ Open = "{%"; Close = "%}" },
      @{ Open = "{#"; Close = "#}" }
    )) {
      $openCount = [regex]::Matches($text, [regex]::Escape($pair.Open)).Count
      $closeCount = [regex]::Matches($text, [regex]::Escape($pair.Close)).Count
      if ($openCount -ne $closeCount) {
        throw "$(Get-RelativePath $file.FullName) has mismatched $($pair.Open) / $($pair.Close) delimiters."
      }
    }
  }
  Write-Host "Ansible template delimiters OK"
}

function Convert-ToBashPath {
  param([string]$Path)

  $resolved = (Resolve-Path $Path).Path
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    return ("/" + $Matches[1].ToLowerInvariant() + "/" + ($Matches[2] -replace '\\', '/'))
  }
  return ($resolved -replace '\\', '/')
}

function Test-RenderedTemplates {
  param(
    [object]$WindowsConfig,
    [hashtable]$LinuxEnv
  )

  Write-Step "Rendered token templates"
  $values = @{
    APP_NAME = $LinuxEnv.APP_NAME
    APP_DISPLAY_NAME = $LinuxEnv.APP_DISPLAY_NAME
    APP_DESCRIPTION = $LinuxEnv.APP_DESCRIPTION
    SERVICE_USER = $LinuxEnv.SERVICE_USER
    SERVICE_GROUP = $LinuxEnv.SERVICE_GROUP
    APP_DIR = $LinuxEnv.APP_DIR
    ENV_FILE = $LinuxEnv.ENV_FILE
    NODE_BIN = $LinuxEnv.NODE_BIN
    START_SCRIPT = $LinuxEnv.START_SCRIPT
    NODE_ARGUMENTS = $LinuxEnv.NODE_ARGUMENTS
    FAILURE_RESTART_DELAY = $LinuxEnv.FAILURE_RESTART_DELAY
    LOG_DIR = $LinuxEnv.LOG_DIR
    BACKUP_DIR = $LinuxEnv.BACKUP_DIR
    APP_PORT = $LinuxEnv.APP_PORT
    PUBLIC_HOSTNAME = $LinuxEnv.PUBLIC_HOSTNAME
    HEALTH_URL = $LinuxEnv.HEALTH_URL
    HEALTHCHECK_INTERVAL = $LinuxEnv.HEALTHCHECK_INTERVAL
    HEALTHCHECK_COMMAND = "/usr/local/sbin/$($LinuxEnv.APP_NAME)-healthcheck.sh /etc/node-enterprise-deploy-kit/$($LinuxEnv.APP_NAME).env"
    RUNNER_SCRIPT = "/usr/local/sbin/$($LinuxEnv.APP_NAME)-runner.sh"
    HAPROXY_BIND = $LinuxEnv.HAPROXY_BIND
    HAPROXY_FRONTEND_NAME = $LinuxEnv.HAPROXY_FRONTEND_NAME
    HAPROXY_BACKEND_NAME = $LinuxEnv.HAPROXY_BACKEND_NAME
    HEALTHCHECK_PATH = $LinuxEnv.HEALTHCHECK_PATH
    HEALTHCHECK_STATE_DIR = $LinuxEnv.HEALTHCHECK_STATE_DIR
    TRAEFIK_ENTRYPOINT = $LinuxEnv.TRAEFIK_ENTRYPOINT
    TRAEFIK_ROUTER_NAME = $LinuxEnv.TRAEFIK_ROUTER_NAME
    TRAEFIK_SERVICE_NAME = $LinuxEnv.TRAEFIK_SERVICE_NAME
    HEALTH_PROXY_PATH = [string]$WindowsConfig.IisHealthProxyPath
    FORWARDED_SERVER_VARIABLES = @"
          <serverVariables>
            <set name="HTTP_X_FORWARDED_HOST" value="{HTTP_HOST}" />
            <set name="HTTP_X_FORWARDED_PROTO" value="https" />
            <set name="HTTP_X_FORWARDED_PORT" value="443" />
            <set name="HTTP_X_FORWARDED_FOR" value="{REMOTE_ADDR}" />
          </serverVariables>
"@
    DISPLAY_NAME = [string]$WindowsConfig.DisplayName
    DESCRIPTION = [string]$WindowsConfig.Description
    NODE_EXE = [string]$WindowsConfig.NodeExe
    START_COMMAND = [string]$WindowsConfig.StartCommand
    APP_DIRECTORY = [string]$WindowsConfig.AppDirectory
    LOG_DIRECTORY = [string]$WindowsConfig.LogDirectory
    ENVIRONMENT_BLOCK = '<env name="NODE_ENV" value="production" />'
  }

  $tempDir = Join-Path $RepoRoot (".tmp/template-validation-" + [guid]::NewGuid().ToString("N"))
  New-Item -Path $tempDir -ItemType Directory | Out-Null

  try {
    $templateFiles = Get-ChildItem -Path (Join-Path $RepoRoot "templates") -Recurse -File -Filter "*.tpl"
    foreach ($file in $templateFiles) {
      $source = Get-RelativePath $file.FullName
      $rendered = Render-TokenTemplate (Get-Content -Path $file.FullName -Raw) $values $source

      if ($source -like "templates/windows/*.tpl") {
        try {
          [xml]$null = $rendered
        }
        catch {
          throw "$source did not render as valid XML. $($_.Exception.Message)"
        }
      }

      if ($source -match 'sysv-node-app\.init\.tpl$|openrc-node-app\.init\.tpl$|bsdrc-node-app\.init\.tpl$|launchd-runner\.sh\.tpl$') {
        if (-not $SkipShellRenderedSyntax) {
          $bash = Get-Command bash -ErrorAction SilentlyContinue
          if ($bash) {
            $renderedPath = Join-Path $tempDir ([System.IO.Path]::GetFileName($file.FullName))
            [System.IO.File]::WriteAllText($renderedPath, $rendered, [System.Text.UTF8Encoding]::new($false))
            Push-Location $RepoRoot
            try {
              & $bash.Source -n (Get-RelativePath $renderedPath)
              if ($LASTEXITCODE -ne 0) {
                throw "$source rendered shell syntax check failed."
              }
            }
            finally {
              Pop-Location
            }
          }
        }
      }
    }
  }
  finally {
    if (Test-Path $tempDir) {
      Remove-Item -Path $tempDir -Recurse -Force
    }
  }

  Write-Host "Rendered token templates OK"
}

function Test-AnsibleCollectionAvailable {
  param([string]$Name)

  $galaxy = Get-Command ansible-galaxy -ErrorAction SilentlyContinue
  if (-not $galaxy) {
    return $false
  }

  $previousAnsibleConfig = $env:ANSIBLE_CONFIG
  $previousAnsibleRolesPath = $env:ANSIBLE_ROLES_PATH
  Push-Location $RepoRoot
  try {
    $env:ANSIBLE_CONFIG = Join-Path $RepoRoot "ansible.cfg"
    $env:ANSIBLE_ROLES_PATH = Join-Path $RepoRoot "ansible/roles"
    $output = @(& $galaxy.Source collection list $Name 2>$null)
    return ($LASTEXITCODE -eq 0 -and ($output -match [regex]::Escape($Name)))
  }
  finally {
    $env:ANSIBLE_CONFIG = $previousAnsibleConfig
    $env:ANSIBLE_ROLES_PATH = $previousAnsibleRolesPath
    Pop-Location
  }
}

function Test-AnsibleSyntaxIfAvailable {
  if ($SkipAnsibleSyntax) {
    Write-Host "Skipping Ansible syntax check."
    return
  }

  Write-Step "Ansible syntax"
  $ansible = Get-Command ansible-playbook -ErrorAction SilentlyContinue
  if (-not $ansible) {
    Write-Host "ansible-playbook was not found; skipping optional Ansible syntax check."
    return
  }

  if (-not (Test-AnsibleCollectionAvailable "ansible.windows")) {
    Write-Host "ansible.windows collection was not found; skipping optional Ansible syntax check. Install it with: ansible-galaxy collection install -r ansible/requirements.yml"
    return
  }

  $previousAnsibleConfig = $env:ANSIBLE_CONFIG
  $previousAnsibleRolesPath = $env:ANSIBLE_ROLES_PATH
  Push-Location $RepoRoot
  try {
    $env:ANSIBLE_CONFIG = Join-Path $RepoRoot "ansible.cfg"
    $env:ANSIBLE_ROLES_PATH = Join-Path $RepoRoot "ansible/roles"
    & $ansible.Source --syntax-check -i "ansible/inventory.example.yml" "ansible/playbooks/site.yml"
    if ($LASTEXITCODE -ne 0) {
      throw "Ansible syntax check failed."
    }
  }
  finally {
    $env:ANSIBLE_CONFIG = $previousAnsibleConfig
    $env:ANSIBLE_ROLES_PATH = $previousAnsibleRolesPath
    Pop-Location
  }
}

$windowsConfig = Test-WindowsExampleConfig
$linuxEnv = Test-LinuxExampleConfig
Test-AnsibleDefaults
Test-JinjaDelimiters
Test-RenderedTemplates -WindowsConfig $windowsConfig -LinuxEnv $linuxEnv
Test-AnsibleSyntaxIfAvailable

Write-Host ""
Write-Host "Sample config and template validation OK"
