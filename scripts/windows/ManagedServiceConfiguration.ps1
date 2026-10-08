function Initialize-ManagedServiceConfigurationApi {
    if ("NodeDeployKit.ServiceConfiguration" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace NodeDeployKit {
    public sealed class FailureAction {
        public int Type;
        public uint Delay;
    }
    public sealed class RecoveryConfiguration {
        public uint ResetPeriod;
        public string RebootMessage;
        public string Command;
        public FailureAction[] Actions;
        public bool NonCrashFailures;
        public bool DelayedAutoStart;
        public string Description;
    }
    public static class ServiceConfiguration {
        [StructLayout(LayoutKind.Sequential)] private struct FailureActions {
            public uint ResetPeriod;
            public IntPtr RebootMessage;
            public IntPtr Command;
            public uint Count;
            public IntPtr Actions;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Action {
            public int Type;
            public uint Delay;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint Count; public Luid Id; public uint Attributes; }
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValue(string system, string name, out Luid id);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, out TokenPrivileges previous, out uint needed);
        [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] private static extern bool ResetTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr needed);
        private static IntPtr EnableShutdownPrivilege(out TokenPrivileges previous) {
            previous = new TokenPrivileges(); IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x20 | 8, out token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
            try {
                Luid id;
                if (!LookupPrivilegeValue(null, "SeShutdownPrivilege", out id)) throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed");
                var state = new TokenPrivileges { Count = 1, Id = id, Attributes = 2 }; uint needed;
                if (!AdjustTokenPrivileges(token, false, ref state, (uint)Marshal.SizeOf(typeof(TokenPrivileges)), out previous, out needed) || Marshal.GetLastWin32Error() != 0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not enable privilege needed to restore reboot recovery actions");
                return token;
            } catch { CloseHandle(token); throw; }
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryServiceConfig2(IntPtr service, uint level, IntPtr buffer, uint size, out uint needed);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ChangeServiceConfig2(IntPtr service, uint level, IntPtr buffer);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CloseServiceHandle(IntPtr handle);
        private static IntPtr Open(string name, uint access) {
            IntPtr manager = OpenSCManager(null, null, 1);
            if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");
            try {
                IntPtr service = OpenService(manager, name, access);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService failed");
                return service;
            } finally { CloseServiceHandle(manager); }
        }
        private static IntPtr Query(IntPtr service, uint level) {
            uint needed;
            QueryServiceConfig2(service, level, IntPtr.Zero, 0, out needed);
            int error = Marshal.GetLastWin32Error();
            if (needed == 0 || error != 122) throw new Win32Exception(error, "QueryServiceConfig2 sizing failed");
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            if (!QueryServiceConfig2(service, level, buffer, needed, out needed)) {
                error = Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(buffer);
                throw new Win32Exception(error, "QueryServiceConfig2 failed");
            }
            return buffer;
        }
        private static void Change(IntPtr service, uint level, IntPtr buffer) {
            if (!ChangeServiceConfig2(service, level, buffer)) throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig2 failed");
        }
        public static RecoveryConfiguration Read(string name) {
            IntPtr service = Open(name, 1);
            try {
                var result = new RecoveryConfiguration();
                IntPtr buffer = Query(service, 2);
                try {
                    var value = (FailureActions)Marshal.PtrToStructure(buffer, typeof(FailureActions));
                    result.ResetPeriod = value.ResetPeriod;
                    result.RebootMessage = Marshal.PtrToStringUni(value.RebootMessage);
                    result.Command = Marshal.PtrToStringUni(value.Command);
                    result.Actions = new FailureAction[value.Count];
                    int size = Marshal.SizeOf(typeof(Action));
                    for (int i = 0; i < value.Count; i++) {
                        var action = (Action)Marshal.PtrToStructure(IntPtr.Add(value.Actions, i * size), typeof(Action));
                        result.Actions[i] = new FailureAction { Type = action.Type, Delay = action.Delay };
                    }
                } finally { Marshal.FreeHGlobal(buffer); }
                buffer = Query(service, 4);
                try { result.NonCrashFailures = Marshal.ReadInt32(buffer) != 0; } finally { Marshal.FreeHGlobal(buffer); }
                buffer = Query(service, 3);
                try { result.DelayedAutoStart = Marshal.ReadInt32(buffer) != 0; } finally { Marshal.FreeHGlobal(buffer); }
                buffer = Query(service, 1);
                try { result.Description = Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer)); } finally { Marshal.FreeHGlobal(buffer); }
                return result;
            } finally { CloseServiceHandle(service); }
        }
        public static void Restore(string name, RecoveryConfiguration configuration) {
            IntPtr service = Open(name, 2 | 16); // Restart failure actions require SERVICE_START.
            IntPtr reboot = IntPtr.Zero, command = IntPtr.Zero, actions = IntPtr.Zero, buffer = IntPtr.Zero;
            IntPtr token = IntPtr.Zero; TokenPrivileges previousPrivilege = new TokenPrivileges();
            try {
                reboot = Marshal.StringToHGlobalUni(configuration.RebootMessage ?? "");
                command = Marshal.StringToHGlobalUni(configuration.Command ?? "");
                var entries = configuration.Actions ?? new FailureAction[0];
                foreach (var entry in entries) { if (entry.Type == 2) { token = EnableShutdownPrivilege(out previousPrivilege); break; } }
                int size = Marshal.SizeOf(typeof(Action));
                // A non-null array with zero actions clears a previously configured policy.
                actions = Marshal.AllocHGlobal(Math.Max(1, entries.Length) * size);
                for (int i = 0; i < entries.Length; i++) {
                    Marshal.StructureToPtr(new Action { Type = entries[i].Type, Delay = entries[i].Delay }, IntPtr.Add(actions, i * size), false);
                }
                var value = new FailureActions { ResetPeriod = configuration.ResetPeriod, RebootMessage = reboot, Command = command, Count = (uint)entries.Length, Actions = actions };
                buffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FailureActions)));
                Marshal.StructureToPtr(value, buffer, false);
                Change(service, 2, buffer);
                Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; buffer = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(buffer, configuration.NonCrashFailures ? 1 : 0); Change(service, 4, buffer);
                Marshal.WriteInt32(buffer, configuration.DelayedAutoStart ? 1 : 0); Change(service, 3, buffer);
                Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; buffer = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.FreeHGlobal(command); command = IntPtr.Zero; command = Marshal.StringToHGlobalUni(configuration.Description ?? "");
                Marshal.WriteIntPtr(buffer, command); Change(service, 1, buffer);
            } finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (actions != IntPtr.Zero) Marshal.FreeHGlobal(actions);
                if (command != IntPtr.Zero) Marshal.FreeHGlobal(command);
                if (reboot != IntPtr.Zero) Marshal.FreeHGlobal(reboot);
                if (token != IntPtr.Zero) { ResetTokenPrivileges(token, false, ref previousPrivilege, 0, IntPtr.Zero, IntPtr.Zero); CloseHandle(token); }
                CloseServiceHandle(service);
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Get-ManagedServiceRecoveryConfiguration {
    param([string]$Name)
    Initialize-ManagedServiceConfigurationApi
    return [NodeDeployKit.ServiceConfiguration]::Read($Name)
}

function Restore-ManagedServiceRecoveryConfiguration {
    param([string]$Name, $Configuration)
    Initialize-ManagedServiceConfigurationApi
    $snapshot = New-Object NodeDeployKit.RecoveryConfiguration
    foreach ($field in @("ResetPeriod", "RebootMessage", "Command", "NonCrashFailures", "DelayedAutoStart", "Description")) {
        $snapshot.$field = $Configuration.$field
    }
    $actions = [System.Collections.Generic.List[NodeDeployKit.FailureAction]]::new()
    foreach ($entry in @($Configuration.Actions)) {
        if ($null -eq $entry) { continue }
        $action = New-Object NodeDeployKit.FailureAction
        $action.Type = [int]$entry.Type; $action.Delay = [uint32]$entry.Delay
        $actions.Add($action)
    }
    $snapshot.Actions = $actions.ToArray()
    [NodeDeployKit.ServiceConfiguration]::Restore($Name, $snapshot)
}
