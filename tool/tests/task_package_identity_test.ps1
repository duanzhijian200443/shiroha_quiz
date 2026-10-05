[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $root 'tool/task_package_identity.ps1'
. $helper
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
    $script:assertions++
}
function Expect-Rejected([string]$Body) {
    $rejected = $false
    try { Get-TaskPackageIdentity -Body $Body | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'ambiguous or malformed identity must fail closed'
}
$zeros = '0' * 64
$package = @"
## Task package
Task-package revision: 1
Task-package digest: $zeros
Task: synthetic acceptance.
Acceptance: frozen.
"@.Replace("`r`n", "`n")
$expected = '89f7848d364b57276eb2103bd816da97ae12e3d219b5298cac5e1083d974f455'
$identity = Get-TaskPackageIdentity -Body $package
Assert-True ($identity.TaskPackageDigest -ceq $expected) 'independent SHA256 known vector'
Assert-True (!$identity.DigestMatches) 'placeholder does not pass verification'
$valid = $package.Replace($zeros, $expected)
Assert-True (Get-TaskPackageIdentity -Body $valid).DigestMatches 'filled digest verifies without self-reference'
foreach ($body in @($valid.Replace("`n", "`r`n"), $valid.Replace("`n", "`r"),
        ($valid + "`n`n"), ([string][char]0xfeff + $valid))) {
    Assert-True ((Get-TaskPackageIdentity -Body $body).TaskPackageDigest -ceq $expected) 'line ending/BOM/final blank normalization'
}
$outside = "# Summary`nUnrelated summary.`n`n" + $valid + "`n`n## Evidence`nCI: pending.`n"
Assert-True ((Get-TaskPackageIdentity -Body $outside).TaskPackageDigest -ceq $expected) 'unrelated PR-body sections excluded'
Assert-True ((Get-TaskPackageIdentity -Body ($valid + "`n# Evidence`nhead X")).TaskPackageDigest -ceq $expected) 'level-one boundary'
$fencedExample = '```text' + "`n## Task package`n" + '```' + "`n" + $valid
Assert-True ((Get-TaskPackageIdentity -Body $fencedExample).TaskPackageDigest -ceq $expected) 'fenced heading is not a second package'
$embedded = $valid + "`n" + '~~~text' + "`n## Evidence`nTask-package digest: $zeros`n" + '~~~'
Assert-True (!(Get-TaskPackageIdentity -Body $embedded).DigestMatches) 'fenced content remains covered by the digest'
foreach ($changed in @($valid.Replace('Acceptance: frozen.', 'Acceptance: reduced.'),
        $valid.Replace('revision: 1', 'revision: 2'), $valid.Replace('Task:', 'Task: '),
        ($valid + "`nGit: merge yes"))) {
    Assert-True (!(Get-TaskPackageIdentity -Body $changed).DigestMatches) 'acceptance/revision/whitespace/authority drift invalidates identity'
}
Expect-Rejected '## Summary'
Expect-Rejected ($valid + "`n" + $valid)
Expect-Rejected ($valid.Replace('## Task package', '## Task package '))
Expect-Rejected ($valid.Replace('Task-package revision: 1', ''))
Expect-Rejected ($valid.Replace('revision: 1', 'revision: 0'))
Expect-Rejected ($valid.Replace('revision: 1', 'revision: 01'))
Expect-Rejected ($valid.Replace('revision: 1', 'revision: 9223372036854775808'))
Expect-Rejected ($valid + "`nTask-package revision: 1")
Expect-Rejected ($valid + "`nTask-package digest: $expected")
Expect-Rejected ($valid.Replace($expected, $expected.ToUpperInvariant()))
Expect-Rejected ($valid.Replace($expected, 'missing'))
Expect-Rejected ($valid.Replace("Task-package digest: $expected", ''))
Expect-Rejected ($valid + "`n" + '```text')

$fixture = Join-Path $root ('.dart_tool/task-package-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$bodyPath = Join-Path $fixture 'body.md'
[IO.File]::WriteAllText($bodyPath, $valid, [Text.UTF8Encoding]::new($false))
$before = [IO.File]::ReadAllBytes($bodyPath)
$result = & $helper -BodyPath $bodyPath | ConvertFrom-Json
Assert-True $result.DigestMatches 'CLI verification succeeds'
Assert-True ([Convert]::ToHexString($before) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($bodyPath))) 'successful helper leaves input untouched'
[IO.File]::WriteAllText($bodyPath, $package, [Text.UTF8Encoding]::new($false))
$rejected = $false
try { & $helper -BodyPath $bodyPath | Out-Null } catch { $rejected = $true }
Assert-True $rejected 'CLI rejects a stale or forged digest by default'
Assert-True ([IO.File]::ReadAllText($bodyPath) -ceq $package) 'failed helper leaves input untouched'
$computed = & $helper -BodyPath $bodyPath -Compute | ConvertFrom-Json
Assert-True ($computed.TaskPackageDigest -ceq $expected -and !$computed.DigestMatches) 'Compute assists the writer without granting verification'
[IO.File]::WriteAllBytes($bodyPath, [byte[]]@(0xff, 0xfe, 0x00))
$rejected = $false
try { & $helper -BodyPath $bodyPath | Out-Null } catch { $rejected = $true }
Assert-True $rejected 'non-UTF8 input is rejected'
Write-Output "PASS: $assertions task-package identity, drift, ambiguity and read-only assertions"
