param([ValidateRange(1, 20)][int]$Loops = 5)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$pins = Get-Content (Join-Path $PSScriptRoot 'pins.json') -Raw | ConvertFrom-Json
$project = Join-Path $env:GITHUB_WORKSPACE 'workload'
$base = Join-Path $env:GITHUB_WORKSPACE '.benchmark'
$results = Join-Path $base 'results'
$cache = Join-Path $base 'm2'
foreach ($variable in @('JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS', 'MAVEN_OPTS', 'MAVEN_ARGS')) {
    if ([Environment]::GetEnvironmentVariable($variable)) {
        throw " ERROR - Unexpected inherited JVM/Maven configuration: $variable"
    }
}
Set-Location $project
$revision = & git rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $pins.workload_commit) {
    throw ' ERROR - Workload commit mismatch.'
}
$sourceHashes = [ordered]@{}
$files = & git ls-files
if ($LASTEXITCODE -ne 0) { throw ' ERROR - Cannot enumerate workload sources.' }
foreach ($file in $files) {
    $sourceHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $project $file) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$sourceHashes | ConvertTo-Json | Set-Content (Join-Path $results 'source-sha256.json')
$wrapper = if ($IsWindows) { Join-Path $project 'mvnw.cmd' } else { Join-Path $project 'mvnw' }
if (-not $IsWindows) {
    & chmod +x $wrapper
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Could not make Maven wrapper executable.' }
}
$version = (& $wrapper --version 2>&1 | Out-String)
$version | Set-Content (Join-Path $results 'maven-environment.log')
if ($LASTEXITCODE -ne 0 -or $version -notmatch ('Apache Maven ' + [regex]::Escape($pins.maven_version) + '\b')) {
    throw ' ERROR - Maven version mismatch.'
}
$environment = [ordered]@{
    workload_commit = $revision
    automation_commit = $env:GITHUB_SHA
    runner_os = $env:RUNNER_OS
    runner_arch = $env:RUNNER_ARCH
    image_os = $env:ImageOS
    image_version = $env:ImageVersion
    os_description = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    logical_processors = [Environment]::ProcessorCount
    java_home = $env:JAVA_HOME
    jdk_runtime = $pins.java_runtime_version
    maven_version = $pins.maven_version
    jvm_config = Get-Content (Join-Path $project '.mvn/jvm.config') -Raw
    loops = $Loops
    timing = 'clean excluded; offline package -DskipTests plus offline test; wall-clock seconds'
}
$environment | ConvertTo-Json | Set-Content (Join-Path $results 'environment.json')
if ($IsWindows) {
    Get-Volume -FilePath $project | Format-List * | Out-File (Join-Path $results 'storage.log')
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors |
        Format-List | Out-File (Join-Path $results 'hardware.log')
} else {
    $volumes = @(& df -P $project)
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Cannot identify the workload volume.' }
    $volumes | Out-File (Join-Path $results 'storage.log')
    $device = ($volumes[-1].Trim() -split '\s+')[0]
    & diskutil info $device | Out-File (Join-Path $results 'storage-details.log')
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Cannot inspect the workload volume.' }
    & sysctl hw.model hw.memsize hw.ncpu machdep.cpu.brand_string | Out-File (Join-Path $results 'hardware.log')
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Cannot inspect the runner hardware.' }
}

function Invoke-MavenPhase {
    param([string]$LogName, [string[]]$Arguments)
    $log = Join-Path $results $LogName
    $elapsed = Measure-Command {
        & $wrapper "-Dmaven.repo.local=$cache" @Arguments *> $log
    }
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log -Tail 60 | Write-Host
        throw " ERROR - Maven failed. See $LogName"
    }
    return [math]::Round($elapsed.TotalSeconds, 2)
}

# Preparation is online and excluded from measured results, matching HOBL.
Invoke-MavenPhase 'prep-dependencies.log' @('-DskipTests', 'dependency:go-offline') | Out-Null
Invoke-MavenPhase 'prep-verify.log' @('clean', 'verify') | Out-Null
$rows = @()
for ($loop = 1; $loop -le $Loops; $loop++) {
    Invoke-MavenPhase "loop-$loop-clean.log" @('clean') | Out-Null
    $build = Invoke-MavenPhase "loop-$loop-build.log" @('-o', '-DskipTests', 'package')
    $test = Invoke-MavenPhase "loop-$loop-test.log" @('-o', 'test')
    $reports = @(Get-ChildItem (Join-Path $project 'target/surefire-reports') -Filter 'TEST-*.xml')
    if ($reports.Count -eq 0) { throw ' ERROR - No test reports produced.' }
    $outcomes = @(
        foreach ($report in $reports) {
            $xml = [xml](Get-Content $report.FullName -Raw)
            foreach ($case in $xml.SelectNodes('/testsuite/testcase')) {
                $status = if ($case.SelectSingleNode('failure')) { 'failure' }
                    elseif ($case.SelectSingleNode('error')) { 'error' }
                    elseif ($case.SelectSingleNode('skipped')) { 'skipped' }
                    else { 'passed' }
                [pscustomobject]@{ class = $case.GetAttribute('classname'); name = $case.GetAttribute('name'); status = $status }
            }
        }
    )
    $outcomes | Sort-Object class, name | ConvertTo-Json |
        Set-Content (Join-Path $results "loop-$loop-test-outcomes.json")
    if ($outcomes.Count -ne 56 -or @($outcomes | Where-Object status -eq 'passed').Count -ne 54 -or
        @($outcomes | Where-Object status -eq 'skipped').Count -ne 2) {
        throw ' ERROR - Expected 54 passed and 2 skipped tests; workload is not comparable.'
    }
    $total = [math]::Round($build + $test, 2)
    $rows += [pscustomobject]@{
        loop = $loop; build_time = $build; test_time = $test; scenario_runtime = $total; architecture = 'ARM64'
    }
    $rows | Export-Csv (Join-Path $results 'results.csv') -NoTypeInformation
    Write-Host "Loop $loop/$Loops : build=${build}s test=${test}s scenario_runtime=${total}s"
}
@(
    "## HOBL-style PetClinic: $env:RUNNER_OS ARM64"
    ''
    'Pinned Microsoft JDK 25+36-LTS; Maven 3.9.11. Prep and clean excluded from timing.'
    ''
    '| Loop | Build (s) | Test (s) | Total (s) |'
    '|---|---:|---:|---:|'
    $rows | ForEach-Object { "| $($_.loop) | $($_.build_time) | $($_.test_time) | $($_.scenario_runtime) |" }
    ''
    '**Different hosted runners have different hardware. These results are not an isolated OS/filesystem comparison.**'
) | Add-Content $env:GITHUB_STEP_SUMMARY
