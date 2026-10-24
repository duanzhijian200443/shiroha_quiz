# Read-only query for holders of one task-owned test executable.
# No Restart Manager shutdown/restart operation is declared or called.
param([Parameter(Mandatory = $true)][string]$TargetFile)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FixtureSharingObserver {
  [StructLayout(LayoutKind.Sequential)] public struct Identity {
    public uint pid;
    public System.Runtime.InteropServices.ComTypes.FILETIME started;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Info {
    public Identity process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string app;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string service;
    public uint type, status, session;
    [MarshalAs(UnmanagedType.Bool)] public bool restartable;
  }
  [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
  [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmRegisterResources(uint session, uint count, string[] files, uint apps, IntPtr appList, uint services, IntPtr serviceList);
  [DllImport("rstrtmgr.dll")] public static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] Info[] info, ref uint reasons);
  [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint session);
}
'@
$taskSession = [uint32]0
$taskKey = [Text.StringBuilder]::new(33)
$taskCode = [FixtureSharingObserver]::RmStartSession([ref]$taskSession, 0, $taskKey)
if ($taskCode -ne 0) { throw 'Sharing observer session unavailable' }
try {
    $taskCode = [FixtureSharingObserver]::RmRegisterResources($taskSession, 1, @($TargetFile), 0, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    if ($taskCode -ne 0) { throw 'Sharing observer registration unavailable' }
    $taskNeeded = [uint32]0; $taskCount = [uint32]32; $taskReasons = [uint32]0
    $taskInfos = [FixtureSharingObserver+Info[]]::new(32)
    $taskCode = [FixtureSharingObserver]::RmGetList($taskSession, [ref]$taskNeeded, [ref]$taskCount, $taskInfos, [ref]$taskReasons)
    $taskHolders = @()
    if ($taskCode -eq 0) {
        for ($taskIndex=0; $taskIndex -lt $taskCount; $taskIndex++) {
            $taskHolders += @{ pid = $taskInfos[$taskIndex].process.pid; name = $taskInfos[$taskIndex].app }
        }
    }
    @{ result = $taskCode; holders = $taskHolders } | ConvertTo-Json -Depth 3 -Compress
} finally {
    $null = [FixtureSharingObserver]::RmEndSession($taskSession)
}
