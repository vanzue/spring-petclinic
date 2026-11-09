param([ValidateSet('NTFS', 'DevDrive')][string]$Storage = 'NTFS')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw ' ERROR - Storage setup is restricted to GitHub-hosted Windows runners.'
}
$results = Join-Path $env:GITHUB_WORKSPACE '.benchmark/results'
New-Item -ItemType Directory -Path $results -Force | Out-Null
Start-Transcript -Path (Join-Path $results 'storage-setup.log') | Out-Null
try {
    $project = Join-Path $env:GITHUB_WORKSPACE 'workload'
    $base = Join-Path $env:GITHUB_WORKSPACE '.benchmark'
    $vhd = $null
    if ($Storage -eq 'DevDrive') {
        if (-not (Get-Command Format-Volume).Parameters.ContainsKey('DevDrive')) {
            throw ' ERROR - This runner does not support Format-Volume -DevDrive.'
        }
        $vhd = Join-Path $env:RUNNER_TEMP 'hobl-devdrive.vhdx'
        if (Test-Path -LiteralPath $vhd) {
            throw " ERROR - Refusing to reuse an existing disk image: $vhd"
        }
        Get-Volume -FilePath $env:RUNNER_TEMP | Format-List DriveLetter, FileSystemType, Size, SizeRemaining
        $diskpartScript = Join-Path $env:RUNNER_TEMP 'hobl-devdrive-diskpart.txt'
        @(
            "create vdisk file=`"$vhd`" maximum=65536 type=expandable"
            "select vdisk file=`"$vhd`""
            'attach vdisk'
        ) | Set-Content -LiteralPath $diskpartScript -Encoding ascii
        & diskpart /s $diskpartScript
        if ($LASTEXITCODE -ne 0) { throw ' ERROR - Dev Drive disk image creation failed.' }
        $disks = @(Get-DiskImage -ImagePath $vhd | Get-Disk)
        if ($disks.Count -ne 1 -or $disks[0].IsBoot -or $disks[0].IsSystem -or
            $disks[0].PartitionStyle -ne 'RAW') {
            throw ' ERROR - Refusing to format anything other than the new, empty VHDX.'
        }
        $partition = $disks[0] | Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -UseMaximumSize -AssignDriveLetter
        $volume = Format-Volume -Partition $partition -FileSystem ReFS -DevDrive `
            -AllocationUnitSize 4096 -NewFileSystemLabel 'HOBL-DevDrive' -Confirm:$false
        if ($volume.FileSystemType -ne 'ReFS') { throw ' ERROR - Expected a ReFS Dev Drive.' }
        $root = "$($volume.DriveLetter):\"
        $query = & fsutil devdrv query $root 2>&1
        $queryExit = $LASTEXITCODE
        $query | Tee-Object -FilePath (Join-Path $results 'devdrive.log') | Write-Host
        if ($queryExit -ne 0 -or ($query | Out-String) -notmatch 'This is a trusted developer volume') {
            throw ' ERROR - The new volume is not a trusted Dev Drive; refusing to benchmark a fallback.'
        }
        $destination = Join-Path $root 'hobl/workload'
        & robocopy $project $destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { throw ' ERROR - Could not copy the pinned workload onto Dev Drive.' }
        $global:LASTEXITCODE = 0
        $project = $destination
        $base = Join-Path $root 'hobl/benchmark'
    }
    $volume = Get-Volume -FilePath $project
    if ($Storage -eq 'NTFS' -and $volume.FileSystemType -ne 'NTFS') {
        throw ' ERROR - The default workspace is not NTFS.'
    }
    $volume | Format-List * | Out-File (Join-Path $results 'storage.log')
    try {
        Get-MpComputerStatus | Select-Object AMRunningMode, AMProductVersion, AntivirusEnabled, RealTimeProtectionEnabled |
            Format-List | Out-File (Join-Path $results 'defender-status.log')
        Get-MpPreference | Select-Object PerformanceModeStatus, DisableRealtimeMonitoring |
            Format-List | Out-File (Join-Path $results 'defender-preferences.log')
    } catch {
        $_ | Out-String | Set-Content (Join-Path $results 'defender-query-error.log')
        Write-Warning 'Defender status is unavailable; no security settings were changed.'
    }
    [ordered]@{
        requested_storage = $Storage
        filesystem = [string]$volume.FileSystemType
        workload_path = $project
        cache_path = Join-Path $base 'm2'
        maven_user_home = Join-Path $base 'maven-user'
        temporary_path = Join-Path $base 'tmp'
        vhdx_path = $vhd
        layout = if ($vhd) { '64 GiB dynamically expanding VHDX on the runner default volume' } else { 'runner default volume' }
        jdk_and_logs = 'remain on the runner default volume'
        security_changes = 'none; Dev Drive uses the default format-time trust and existing antivirus policy'
    } | ConvertTo-Json | Set-Content (Join-Path $results 'storage-layout.json')
    @(
        "HOBL_WORKLOAD_PATH=$project"
        "HOBL_BENCHMARK_BASE=$base"
    ) | Add-Content $env:GITHUB_ENV
    Write-Host "Using $Storage workload: $project"
    Write-Host "Using $Storage benchmark cache and temp root: $base"
} finally {
    Stop-Transcript | Out-Null
}
