param(
  [Parameter(Mandatory=$true)][string]$RuntimeDirectory,
  [Parameter(Mandatory=$true)][string]$StateDirectory,
  [Parameter(Mandatory=$true)][string]$PairedSlotDirectory,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SlotRef,
  [string]$WindowsClientExecutable
)
$ErrorActionPreference = 'Stop'
$taskRuntime = (Resolve-Path -LiteralPath $RuntimeDirectory).ProviderPath
$taskSlot = (Resolve-Path -LiteralPath $PairedSlotDirectory).ProviderPath
$taskState = [IO.Path]::GetFullPath($StateDirectory)
$taskConfig = Join-Path $taskRuntime 'link-installation.json'
if (Test-Path -LiteralPath $taskConfig) { throw 'Existing installation configuration must not be overwritten.' }
if (Test-Path -LiteralPath $taskState) { throw 'Existing state must not be reinitialized or replaced.' }
foreach ($taskName in @('shiroha_link.exe','shiroha.exe','shiroha_link_control.exe','shiroha_link_initialize.exe','AndroidDeviceAdapter.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $taskRuntime $taskName) -PathType Leaf)) { throw 'Incomplete runtime package.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $taskSlot 'device.dpapi') -PathType Leaf)) { throw 'An existing explicitly paired slot is required.' }
# Installer-scoped ACL, no inherited public writers. This is not a promise to
# resist an arbitrary malicious process acting as the same Windows user.
New-Item -ItemType Directory -Path $taskState | Out-Null
$taskSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$taskAcl = [Security.AccessControl.DirectorySecurity]::new()
$taskAcl.SetAccessRuleProtection($true,$false)
$taskAcl.SetOwner($taskSid)
foreach ($taskIdentity in @($taskSid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
  $taskAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($taskIdentity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $taskState -AclObject $taskAcl
foreach ($taskPrivateDirectory in @($taskRuntime, $taskSlot)) {
  if (((Get-Item -LiteralPath $taskPrivateDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse directories are not supported.' }
  Set-Acl -LiteralPath $taskPrivateDirectory -AclObject $taskAcl
}
$taskInstance = [guid]::NewGuid().ToString('D')
& (Join-Path $taskRuntime 'shiroha_link_initialize.exe') $taskState $taskInstance
if ($LASTEXITCODE -ne 0) { throw 'State initialization refused; retain its files for diagnosis.' }
$taskWindows = if ($WindowsClientExecutable) { (Resolve-Path -LiteralPath $WindowsClientExecutable).ProviderPath } else { $null }
$taskValue = [ordered]@{version=1;stateDirectory=$taskState;slotDirectory=$taskSlot;slotRef=$SlotRef;connectorInstanceId=$taskInstance;adapterExecutable=(Join-Path $taskRuntime 'AndroidDeviceAdapter.exe');windowsClientExecutable=$taskWindows}
[IO.File]::WriteAllText($taskConfig,($taskValue | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Write-Output 'Installation configured. Existing slots require their old-owner handoff; no claim or device access was performed.'
