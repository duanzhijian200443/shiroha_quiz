param(
  [Parameter(Mandatory=$true)][string]$RuntimeDirectory,
  [Parameter(Mandatory=$true)][string]$StateDirectory,
  [Parameter(Mandatory=$true)][string]$SlotDirectory,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SlotRef,
  [string]$PhoneAddress,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$DeviceId,
  [ValidatePattern('^[a-f0-9]{64}$')][string]$CertificateDigest
)
$ErrorActionPreference = 'Stop'
$taskRuntime = (Resolve-Path -LiteralPath $RuntimeDirectory).ProviderPath
$taskState = [IO.Path]::GetFullPath($StateDirectory)
$taskSlot = [IO.Path]::GetFullPath($SlotDirectory)
$taskConfig = Join-Path $taskRuntime 'link-installation.json'
$taskPending = Join-Path $taskRuntime 'link-installation.pending'
foreach ($taskName in @('shiroha_link.exe','shiroha.exe','shiroha_link_control.exe','AndroidDeviceAdapter.exe','shiroha_link_native.dll','shiroha_link_control_native.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $taskRuntime $taskName) -PathType Leaf)) { throw 'Incomplete runtime package.' }
}
foreach ($taskPrivate in @($taskState,$taskSlot)) {
  if ($taskPrivate.Equals($taskRuntime,[StringComparison]::OrdinalIgnoreCase) -or
      $taskPrivate.StartsWith($taskRuntime + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Mutable state must be outside the runtime package.'
  }
}
if ($taskState.Equals($taskSlot,[StringComparison]::OrdinalIgnoreCase)) { throw 'State and credential slot must be distinct.' }
$taskHint = $null
if ($PhoneAddress -or $DeviceId -or $CertificateDigest) {
  if (-not ($PhoneAddress -and $DeviceId -and $CertificateDigest)) { throw 'All public pairing inputs are required together.' }
  $taskHint = [ordered]@{address=$PhoneAddress;deviceId=$DeviceId;certificateDigest=$CertificateDigest}
}
# A complete prior installer journal preserves the operation identity. An
# unreadable/partial journal is retained for diagnosis, never replaced.
$taskExisting = if (Test-Path -LiteralPath $taskConfig) { $taskConfig } elseif (Test-Path -LiteralPath $taskPending) { $taskPending } else { $null }
if ($taskExisting) {
  $taskValue = Get-Content -LiteralPath $taskExisting -Raw | ConvertFrom-Json
  if ($taskValue.version -ne 2 -or $taskValue.stateDirectory -ne $taskState -or
      $taskValue.slotDirectory -ne $taskSlot -or $taskValue.slotRef -ne $SlotRef -or
      $taskValue.adapterExecutable -ne (Join-Path $taskRuntime 'AndroidDeviceAdapter.exe') -or
      -not $taskValue.operationId -or -not $taskValue.connectorInstanceId -or
      ($taskValue.pairingInput | ConvertTo-Json -Compress) -ne ($taskHint | ConvertTo-Json -Compress)) {
    throw 'Existing installation identity/configuration differs; retain it for diagnosis.'
  }
  if ($taskExisting -eq $taskPending) { [IO.File]::Move($taskPending,$taskConfig,$false) }
  Write-Output 'Existing initialization operation retained.'
  return
}
if (Test-Path -LiteralPath $taskState) { throw 'Existing state directory requires its original installation configuration.' }
$taskSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$taskAcl = [Security.AccessControl.DirectorySecurity]::new()
$taskAcl.SetAccessRuleProtection($true,$false)
$taskAcl.SetOwner($taskSid)
foreach ($taskIdentity in @($taskSid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
  $taskAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($taskIdentity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
foreach ($taskDirectory in @($taskRuntime,$taskSlot)) {
  if ((Test-Path -LiteralPath $taskDirectory) -and ((Get-Item -LiteralPath $taskDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse directories are unsupported.' }
}
New-Item -ItemType Directory -Path $taskState | Out-Null
Set-Acl -LiteralPath $taskState -AclObject $taskAcl
if (-not (Test-Path -LiteralPath $taskSlot)) {
  New-Item -ItemType Directory -Path $taskSlot | Out-Null
  Set-Acl -LiteralPath $taskSlot -AclObject $taskAcl
}
# Existing slots are inspected by the original adapter. Do not modify their
# records or ACLs, infer clean, or assert historical provenance here.
Set-Acl -LiteralPath $taskRuntime -AclObject $taskAcl
$taskValue = [ordered]@{version=2;stateDirectory=$taskState;slotDirectory=$taskSlot;slotRef=$SlotRef;
  connectorInstanceId=[guid]::NewGuid().ToString('D');operationId=[guid]::NewGuid().ToString('D');
  adapterExecutable=(Join-Path $taskRuntime 'AndroidDeviceAdapter.exe');pairingInput=$taskHint}
$taskBytes = [Text.UTF8Encoding]::new($false).GetBytes(($taskValue | ConvertTo-Json -Compress))
$taskFile = [IO.FileStream]::new($taskPending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $taskFile.Write($taskBytes); $taskFile.Flush($true) } finally { $taskFile.Dispose() }
[IO.File]::Move($taskPending,$taskConfig,$false)
Write-Output 'Configuration recorded. Explicitly launch shiroha_link.exe --initialize from the desktop shell; then use the local initialize control. No pairing, ownership or access has been granted.'
