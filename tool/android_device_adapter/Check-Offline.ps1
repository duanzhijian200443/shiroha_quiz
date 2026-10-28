param(
    [Parameter(Mandatory = $true)][string]$Java,
    [Parameter(Mandatory = $true)][string]$CompilerClasspath,
    [Parameter(Mandatory = $true)][string]$KotlinStdlib,
    [Parameter(Mandatory = $true)][string]$AndroidJar,
    [Parameter(Mandatory = $true)][string]$FlutterEmbeddingJar
)
$ErrorActionPreference = 'Stop'
foreach ($inputFile in @($Java, $KotlinStdlib, $AndroidJar, $FlutterEmbeddingJar)) {
    if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw 'Missing explicit compiler input' }
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $repoRoot 'build/android_device_foundation/classes'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$native = Join-Path $repoRoot 'android/app/src/main/kotlin/com/example/shiroha_quiz/external'
$sources = @(Get-ChildItem -LiteralPath $native -Filter '*.kt' | Sort-Object Name | ForEach-Object FullName)
$sources += Join-Path $PSScriptRoot 'fixtures/FoundationFixture.kt'
$sep = [IO.Path]::PathSeparator
& $Java '-cp' $CompilerClasspath 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler' '-no-stdlib' '-no-reflect' '-jvm-target' '17' '-classpath' "$KotlinStdlib$sep$AndroidJar$sep$FlutterEmbeddingJar" '-d' $output @sources
if ($LASTEXITCODE -ne 0) { throw 'Android foundation Kotlin compilation failed' }
& $Java '-cp' "$output$sep$KotlinStdlib" 'com.example.shiroha_quiz.external.FoundationFixtureKt' (Join-Path $PSScriptRoot 'fixtures/public-certificates.json')
if ($LASTEXITCODE -ne 0) { throw 'Android foundation JVM fixture failed' }
& dotnet build (Join-Path $PSScriptRoot 'AndroidDeviceAdapter.csproj') '--configuration' 'Debug' '--nologo'
if ($LASTEXITCODE -ne 0) { throw 'Desktop adapter compilation failed' }
& dotnet run '--project' (Join-Path $PSScriptRoot 'AndroidDeviceAdapter.csproj') '--no-build' '--' '--self-test'
if ($LASTEXITCODE -ne 0) { throw 'Desktop synthetic fixture failed' }
Write-Output 'PASS: offline foundation checks; no Android/credential/network/model runtime executed'
