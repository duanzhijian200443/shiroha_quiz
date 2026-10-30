param([Parameter(Mandatory = $true)][string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../build/plugin_host_qualification/runs')).ProviderPath
$taskDirectory = (Resolve-Path -LiteralPath $Directory).ProviderPath
if (!$taskDirectory.StartsWith($taskRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture directory must stay inside the qualification workspace.'
}
$taskShellWindows = (New-Object -ComObject Shell.Application).Windows()
$taskDesktopHandle = 0
$taskDesktop = $taskShellWindows.FindWindowSW(0, 0, 8, [ref]$taskDesktopHandle, 1)
$taskShell = if ($null -ne $taskDesktop) { $taskDesktop.Document.Application } else { $null }
if ($null -eq $taskShell) {
    # Some Explorer sessions expose folder windows but no desktop automation
    # object. Use an existing Explorer's shell; never start another explorer.exe.
    # The original native gate still verifies the actual desktop parent PID.
    foreach ($taskWindow in $taskShellWindows) {
        if ($taskWindow.FullName -ieq (Join-Path $env:SystemRoot 'explorer.exe')) {
            $taskShell = $taskWindow.Document.Application
            if ($null -ne $taskShell) { break }
        }
    }
}
if ($null -eq $taskShell) { throw 'An existing desktop Explorer window is required.' }
$taskShell.ShellExecute((Join-Path $taskDirectory 'shiroha_quiz.exe'), '', $taskDirectory, 'open', 0)
