# Explicit isolated-client validation only. Never installs or replaces Codex.
param([switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$revision = '44918ea10c0f99151c6710411b4322c2f5c96bea'
$archiveHash = 'DDB3795E3683943AC342F071661F91FA44881CC2BB19C4227FE573BDDCCC14A5'
$scratch = Join-Path $repo '.dart_tool/ar-r6b-isolated-codex'
$source = Join-Path $scratch "codex-$revision"
$archive = Join-Path $scratch 'source.zip'
$patch = Join-Path $PSScriptRoot 'windows-eof.patch'
$null = New-Item -ItemType Directory -Force -Path $scratch
if (!(Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://codeload.github.com/openai/codex/zip/$revision" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) {
    throw 'Pinned public source archive mismatch'
}
if (!(Test-Path -LiteralPath $source)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $scratch
}
Push-Location $repo
try {
    $prefix = ".dart_tool/ar-r6b-isolated-codex/codex-$revision"
    git apply --unidiff-zero --reverse --check "--directory=$prefix" $patch 2>$null
    if ($LASTEXITCODE -ne 0) {
        git apply --unidiff-zero --check "--directory=$prefix" $patch
        if ($LASTEXITCODE -ne 0) { throw 'Isolated patch does not match original source' }
        git apply --unidiff-zero "--directory=$prefix" $patch
        if ($LASTEXITCODE -ne 0) { throw 'Isolated patch failed' }
    }
} finally { Pop-Location }

# The official release archive updates workspace.version but leaves local
# package versions in Cargo.lock at 0.0.0. Normalize only those 132 entries;
# every external package source, version and checksum remains byte-identical.
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $reader = [IO.StreamReader]::new($zip.GetEntry("codex-$revision/codex-rs/Cargo.lock").Open())
    try { $original = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
$count = 0
$expected = [regex]::Replace($original, '(?ms)^\[\[package\]\]\n(?:(?!^\[\[package\]\]).)*', {
    param($entry)
    $block = $entry.Value
    if ($block -notmatch '(?m)^source =' -and $block -match '(?m)^version = "0\.0\.0"$') {
        $script:count++
        return $block.Replace('version = "0.0.0"', 'version = "0.144.1"')
    }
    return $block
})
if ($count -ne 132) { throw 'Unexpected release workspace lock normalization' }
$lock = Join-Path $source 'codex-rs/Cargo.lock'
$current = [IO.File]::ReadAllText($lock)
if ($current -ne $original -and $current -ne $expected) { throw 'Isolated lock drift' }
[IO.File]::WriteAllText($lock, $expected, [Text.UTF8Encoding]::new($false))
if ($PrepareOnly) { Write-Output 'Pinned isolated client source prepared'; return }

$names = @('RUSTUP_HOME', 'CARGO_HOME', 'CARGO_TARGET_DIR', 'RUSTUP_TOOLCHAIN', 'CARGO_BUILD_JOBS', 'PATH')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $source
try {
    $env:RUSTUP_HOME = Join-Path $scratch 'rustup'
    $env:CARGO_HOME = Join-Path $repo '.dart_tool/cg'
    $env:CARGO_TARGET_DIR = Join-Path $repo '.dart_tool/ct'
    $env:RUSTUP_TOOLCHAIN = '1.95.0-x86_64-pc-windows-msvc'
    $env:CARGO_BUILD_JOBS = '2'
    $cmake = 'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin'
    $env:PATH = "$env:CARGO_HOME/bin;$scratch/bin;$cmake;" + $env:PATH
    foreach ($command in @('cargo.exe', 'just.exe', 'cargo-nextest.exe')) {
        if (!(Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing isolated build tool: $command" }
    }
    just.exe test -p codex-rmcp-client --lib -E 'test(graceful_stdio)' --cargo-profile dev-small --locked --test-threads 1
    if ($LASTEXITCODE -ne 0) { throw 'Isolated client lifecycle tests failed' }
    Set-Location (Join-Path $source 'codex-rs')
    cargo.exe build --locked --profile dev-small -p codex-cli --bin codex
    if ($LASTEXITCODE -ne 0) { throw 'Isolated client build failed' }
    Write-Output "Isolated client: $env:CARGO_TARGET_DIR/dev-small/codex.exe"
} finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
