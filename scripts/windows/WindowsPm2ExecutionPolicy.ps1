Set-StrictMode -Version Latest

function Initialize-WindowsProcessTokenReader {
    if ('NodeEnterpriseDeployKit.Security.ProcessTokenReader' -as [type]) { return }
    # Query only: PROCESS_QUERY_LIMITED_INFORMATION + TOKEN_QUERY, without debug
    # privilege or token modification. TokenUser=1; TokenElevation=20.
    # https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
    # https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-token_elevation
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace NodeEnterpriseDeployKit.Security {
    public sealed class ProcessTokenState {
        public int ProcessId;
        public string OwnerSid;
        public bool Elevated;
    }
    public static class ProcessTokenReader {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool GetTokenInformation(IntPtr token, int tokenClass, IntPtr data, int size, out int required);
        private static IntPtr Query(IntPtr token, int tokenClass) {
            int size;
            // TOKEN_ELEVATION is a fixed DWORD; Windows can return BAD_LENGTH
            // for a zero-size elevation probe. TokenUser remains variable-size.
            if (tokenClass == 20) { size = 4; }
            else {
                GetTokenInformation(token, tokenClass, IntPtr.Zero, 0, out size);
                int queryError = Marshal.GetLastWin32Error();
                if (queryError != 122 || size <= 0 || size > 65536) throw new Win32Exception(queryError, "Cannot size token class " + tokenClass);
            }
            IntPtr data = Marshal.AllocHGlobal(size);
            if (!GetTokenInformation(token, tokenClass, data, size, out size)) {
                int error = Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(data); throw new Win32Exception(error, "Cannot read token class " + tokenClass + "; bytes=" + size);
            }
            return data;
        }
        public static ProcessTokenState Read(int pid) {
            IntPtr process = OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr token = IntPtr.Zero, user = IntPtr.Zero, elevation = IntPtr.Zero;
            try {
                if (!OpenProcessToken(process, 0x8, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                user = Query(token, 1); elevation = Query(token, 20);
                return new ProcessTokenState { ProcessId=pid,
                    OwnerSid=new SecurityIdentifier(Marshal.ReadIntPtr(user)).Value,
                    Elevated=Marshal.ReadInt32(elevation) != 0 };
            } finally {
                if (user != IntPtr.Zero) Marshal.FreeHGlobal(user);
                if (elevation != IntPtr.Zero) Marshal.FreeHGlobal(elevation);
                if (token != IntPtr.Zero) CloseHandle(token);
                CloseHandle(process);
            }
        }
    }
}
'@
}

function Get-WindowsNativeProcessToken {
    param([int]$ProcessId = $PID)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows PM2 process token validation requires native Windows.' }
    Initialize-WindowsProcessTokenReader
    return [NodeEnterpriseDeployKit.Security.ProcessTokenReader]::Read($ProcessId)
}

function Assert-WindowsPm2PolicyPathNoReparse {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $item = $null } else { throw "PM2 control path cannot be inspected: $current" } }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "PM2 control path contains a reparse point: $current" }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-WindowsPm2ExecutionAllowed {
    param([string]$Pm2HomePath = '', [string]$ExpectedOwnerSid = '')
    $guidance = 'Run PM2 from its dedicated unelevated owner account, or use WinSW/NSSM for an elevated managed deployment. Stop and migrate an elevated PM2 daemon before retrying.'
    try { $caller = Get-WindowsNativeProcessToken -ProcessId $PID }
    catch { throw "Cannot verify the Windows PM2 caller token. $guidance" }
    if (-not $caller -or $caller.Elevated -isnot [bool] -or $caller.Elevated -or $caller.OwnerSid -eq 'S-1-5-18') { throw "Elevated administrator/SYSTEM PM2 execution is prohibited. $guidance" }
    if (-not $ExpectedOwnerSid) { $ExpectedOwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    if (-not $caller.OwnerSid -or $caller.OwnerSid -ne $ExpectedOwnerSid) { throw "PM2 caller does not match its configured owner. $guidance" }
    if (-not $Pm2HomePath) { $Pm2HomePath = if ($env:PM2_HOME) { $env:PM2_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pm2' } }
    if ($Pm2HomePath -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+[\\/])' -or $Pm2HomePath -match '[*?]|(?<!^[A-Za-z]):') { throw 'PM2_HOME must be an absolute directory below a drive/share root.' }
    $homePath = [IO.Path]::GetFullPath($Pm2HomePath).TrimEnd('\', '/')
    if ($homePath -eq [IO.Path]::GetPathRoot($homePath).TrimEnd('\', '/')) { throw 'PM2_HOME cannot be a filesystem root.' }
    Assert-WindowsPm2PolicyPathNoReparse $homePath
    $pidPath = Join-Path $homePath 'pm2.pid'
    Assert-WindowsPm2PolicyPathNoReparse $pidPath
    try { $pidFile = Get-Item -LiteralPath $pidPath -Force -ErrorAction Stop }
    catch { if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return } else { throw "Cannot inspect the existing PM2 daemon PID file. $guidance" } }
    if ($pidFile.PSIsContainer -or $pidFile.Length -gt 64) { throw "Invalid existing PM2 daemon PID file. $guidance" }
    try { $pidText = [IO.File]::ReadAllText($pidPath).Trim() } catch { throw "Cannot read the existing PM2 daemon PID file. $guidance" }
    $daemonProcessId = 0
    if ($pidText -notmatch '^[1-9][0-9]{0,9}$' -or -not [int]::TryParse($pidText, [ref]$daemonProcessId) -or $daemonProcessId -le 0) { throw "Invalid existing PM2 daemon PID. $guidance" }
    try { $daemon = Get-WindowsNativeProcessToken -ProcessId $daemonProcessId }
    catch { throw "Cannot verify the existing PM2 daemon token (stale PID or inaccessible process). $guidance" }
    if (-not $daemon -or $daemon.Elevated -isnot [bool] -or $daemon.Elevated -or $daemon.OwnerSid -eq 'S-1-5-18' -or $daemon.OwnerSid -ne $ExpectedOwnerSid) { throw "Existing PM2 daemon must belong to the configured owner and have an unelevated token. $guidance" }
}
