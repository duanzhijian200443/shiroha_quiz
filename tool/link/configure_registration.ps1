param(
  [Parameter(Mandatory=$true)][string]$RuntimeDirectory,
  [Parameter(Mandatory=$true)][string]$SlotDirectory,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SlotRef,
  [Parameter(Mandatory=$true)][string]$PhoneAddress,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$DeviceId,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$CertificateDigest
)
$ErrorActionPreference='Stop'
$taskRuntime=(Resolve-Path -LiteralPath $RuntimeDirectory).ProviderPath
$taskSlot=[IO.Path]::GetFullPath($SlotDirectory)
if ($taskSlot.Equals($taskRuntime,[StringComparison]::OrdinalIgnoreCase) -or $taskSlot.StartsWith($taskRuntime+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Slot must be outside runtime.' }
foreach($taskName in @('shiroha_link.exe','AndroidDeviceAdapter.exe','shiroha_link_native.dll')) {
  if (-not(Test-Path -LiteralPath (Join-Path $taskRuntime $taskName) -PathType Leaf)) { throw 'Incomplete runtime.' }
}
$taskConfig=Join-Path $taskRuntime 'pairing-registration.json'
$taskPending=$taskConfig+'.pending'
$taskHint=[ordered]@{address=$PhoneAddress;deviceId=$DeviceId;certificateDigest=$CertificateDigest}
if (Test-Path -LiteralPath $taskConfig) {
  $taskPrior=Get-Content -LiteralPath $taskConfig -Raw | ConvertFrom-Json
  if ($taskPrior.version -ne 1 -or $taskPrior.slotDirectory -ne $taskSlot -or $taskPrior.slotRef -ne $SlotRef -or
      $taskPrior.adapterExecutable -ne (Join-Path $taskRuntime 'AndroidDeviceAdapter.exe') -or
      ($taskPrior.pairingInput|ConvertTo-Json -Compress) -ne ($taskHint|ConvertTo-Json -Compress) -or (Test-Path -LiteralPath $taskPending)) { throw 'Registration configuration conflict.' }
  Write-Output 'Original registration retained; no pairing or ownership action performed.'; return
}
if (Test-Path -LiteralPath $taskPending) { throw 'Registration configuration pending; retain for diagnosis.' }
if (Test-Path -LiteralPath $taskSlot) { throw 'Choose a new empty registration slot.' }
$taskSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$taskAcl=[Security.AccessControl.DirectorySecurity]::new()
$taskAcl.SetAccessRuleProtection($true,$false); $taskAcl.SetOwner($taskSid)
foreach($taskIdentity in @($taskSid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
  $taskAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($taskIdentity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
if ((Get-Item -LiteralPath $taskRuntime).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse runtime refused.' }
New-Item -ItemType Directory -Path $taskSlot | Out-Null
Set-Acl -LiteralPath $taskSlot -AclObject $taskAcl
$taskLock=[IO.FileStream]::new((Join-Path $taskSlot 'slot-ownership.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
$taskLocked=$false
try {
  $taskLock.Lock(0,[long]::MaxValue); $taskLocked=$true
  if (@(Get-ChildItem -LiteralPath $taskSlot -Force | Where-Object Name -ne 'slot-ownership.lock').Count -ne 0) { throw 'Registration requires an empty slot.' }
  $taskValue=[ordered]@{version=1;slotDirectory=$taskSlot;slotRef=$SlotRef;registrarInstanceId=[guid]::NewGuid().ToString('D');
    registrationOperationId=[guid]::NewGuid().ToString('D');registrationGeneration=[guid]::NewGuid().ToString('D');
    runId=[guid]::NewGuid().ToString('D');resourceId=[guid]::NewGuid().ToString('D');
    adapterExecutable=(Join-Path $taskRuntime 'AndroidDeviceAdapter.exe');pairingInput=$taskHint}
  $taskBytes=[Text.UTF8Encoding]::new($false).GetBytes(($taskValue|ConvertTo-Json -Compress -Depth 4))
  $taskFile=[IO.FileStream]::new($taskPending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try { $taskFile.Write($taskBytes); $taskFile.Flush($true) } finally { $taskFile.Dispose() }
  [IO.File]::Move($taskPending,$taskConfig,$false)
} finally { if($taskLocked) { $taskLock.Unlock(0,[long]::MaxValue) }; $taskLock.Dispose() }
Write-Output 'Registration configured. Launch shiroha_link.exe --register-pairing from the desktop shell and compare its original full client fingerprint on the phone. No Link state or business access is created.'
