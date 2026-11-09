$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$pins = Get-Content (Join-Path $PSScriptRoot 'pins.json') -Raw | ConvertFrom-Json
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw ' ERROR - A native ARM64 runner is required.'
}
$platform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else {
    throw ' ERROR - This benchmark supports Windows and macOS only.'
}
$package = $pins.jdks.$platform
$install = Join-Path $env:RUNNER_TEMP 'hobl-jdk-25'
New-Item -ItemType Directory -Path $install | Out-Null
$archive = Join-Path $install ([System.IO.Path]::GetFileName(([uri]$package.url).AbsolutePath))
Invoke-WebRequest -Uri $package.url -OutFile $archive -MaximumRetryCount 3 -RetryIntervalSec 5
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $package.sha256) {
    throw ' ERROR - JDK archive checksum mismatch.'
}
$unpacked = Join-Path $install 'unpacked'
New-Item -ItemType Directory -Path $unpacked | Out-Null
if ($IsWindows) {
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
} else {
    & tar -xzf $archive -C $unpacked
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - JDK extraction failed.' }
}
$exe = if ($IsWindows) { 'java.exe' } else { 'java' }
$homes = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File -Filter release |
    Where-Object { Test-Path (Join-Path $_.DirectoryName "bin/$exe") })
if ($homes.Count -ne 1) { throw ' ERROR - Expected exactly one extracted JDK.' }
$env:JAVA_HOME = $homes[0].DirectoryName
$java = Join-Path $env:JAVA_HOME "bin/$exe"
$settings = (& $java -XshowSettings:properties -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw ' ERROR - JDK validation failed.' }
foreach ($property in @(
    @('java.runtime.version', $pins.java_runtime_version),
    @('java.vendor', $pins.java_vendor),
    @('os.arch', $pins.java_architecture)
)) {
    $pattern = '(?m)^\s*' + [regex]::Escape($property[0]) + '\s*=\s*' + [regex]::Escape($property[1]) + '\s*$'
    if ($settings -notmatch $pattern) {
        throw " ERROR - Unexpected $($property[0]); refusing a mismatched JDK.`n$settings"
    }
}
$base = Join-Path $env:GITHUB_WORKSPACE '.benchmark'
foreach ($directory in @('m2', 'maven-user', 'tmp', 'results')) {
    New-Item -ItemType Directory -Path (Join-Path $base $directory) -Force | Out-Null
}
$settings | Set-Content (Join-Path $base 'results/java-environment.log')
Copy-Item (Join-Path $PSScriptRoot 'pins.json') (Join-Path $base 'results/pins.json')
@(
    "JAVA_HOME=$env:JAVA_HOME"
    "MAVEN_USER_HOME=$(Join-Path $base 'maven-user')"
    "TEMP=$(Join-Path $base 'tmp')"
    "TMP=$(Join-Path $base 'tmp')"
    "TMPDIR=$(Join-Path $base 'tmp')"
) | Add-Content $env:GITHUB_ENV
Join-Path $env:JAVA_HOME 'bin' | Add-Content $env:GITHUB_PATH
Write-Host "Using pinned $platform ARM64 JDK: $env:JAVA_HOME"
