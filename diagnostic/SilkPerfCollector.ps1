<#
.SYNOPSIS
    Windows performance collector (Perfmon Data Collector Set wrapper).

.DESCRIPTION
    Workflow:
      1. .\SilkPerfCollector.ps1 -LoadCounters      # create the data collector set (counter data set)
      2. .\SilkPerfCollector.ps1 -StartCollection   # start collecting, prints where output is written
         ... run your test / workload ...
      3. .\SilkPerfCollector.ps1 -StopCollection    # stop, convert to CSV, generate system_report.txt
                                                     # (CPU/cores, memory, OS build + patches, SQL, disks), zip
         -> send the printed .zip file for analysis.

    Other actions:
      -Status   show collector state and output location
      -Remove   delete the data collector set (collected files are kept)

    Counters: CPU, memory, ALL PhysicalDisk and LogicalDisk counters (every disk),
    network, per-process CPU/IO, and SQL Server (all instances, auto-detected).
    Must be run from an elevated (Administrator) PowerShell.

.EXAMPLE
    .\SilkPerfCollector.ps1 -LoadCounters -SampleInterval 5
.EXAMPLE
    .\SilkPerfCollector.ps1 -StartCollection
.EXAMPLE
    .\SilkPerfCollector.ps1 -StopCollection
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
    [Parameter(ParameterSetName = 'Load', Mandatory)]  [switch]$LoadCounters,
    [Parameter(ParameterSetName = 'Start', Mandatory)] [switch]$StartCollection,
    [Parameter(ParameterSetName = 'Stop', Mandatory)]  [switch]$StopCollection,
    [Parameter(ParameterSetName = 'Status', Mandatory)][switch]$Status,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,

    # Seconds between samples
    [Parameter(ParameterSetName = 'Load')]
    [Parameter(ParameterSetName = 'Start')]
    [ValidateRange(1, 3600)] [int]$SampleInterval = 5,

    # Root folder for all collector output
    [string]$OutputRoot = 'C:\PerfLogs\SilkPerf',

    # Max size of a single .blg file before rolling to a new one
    [Parameter(ParameterSetName = 'Load')]
    [Parameter(ParameterSetName = 'Start')]
    [ValidateRange(64, 65536)] [int]$MaxFileSizeMB = 1024
)

$ErrorActionPreference = 'Stop'
$CollectorName = 'SilkPerfCollector'
$HostName      = $env:COMPUTERNAME
$CounterFile   = Join-Path $OutputRoot 'counters.txt'
$StateFile     = Join-Path $OutputRoot 'current_run.txt'

function Write-Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

function Assert-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Run as Administrator) PowerShell.'
    }
}

function Invoke-Logman {
    param([string[]]$Arguments, [switch]$IgnoreError)
    $out = & logman.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreError) {
        throw "logman $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$out"
    }
    return $out
}

function Test-CollectorExists {
    & logman.exe query $CollectorName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-CollectorState {
    $q = & logman.exe query $CollectorName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return 'NotLoaded' }
    if ($q -match '(?m)^Status:\s+(\S+)') { return $Matches[1] }
    return 'Unknown'
}

function Get-CounterList {
    # Base OS counters
    $paths = @(
        '\Processor(*)\% Processor Time'
        '\Processor(*)\% Privileged Time'
        '\Processor(*)\% User Time'
        '\Processor(*)\% Interrupt Time'
        '\Processor(*)\% DPC Time'
        '\Processor Information(_Total)\% Processor Utility'
        '\Processor Information(_Total)\Processor Frequency'
        '\System\Processor Queue Length'
        '\System\Context Switches/sec'
        '\Memory\Available MBytes'
        '\Memory\Committed Bytes'
        '\Memory\% Committed Bytes In Use'
        '\Memory\Pages/sec'
        '\Memory\Page Faults/sec'
        '\Memory\Pool Nonpaged Bytes'
        '\Memory\Cache Bytes'
        '\Paging File(_Total)\% Usage'
        '\PhysicalDisk(*)\*'
        '\LogicalDisk(*)\*'
        '\Network Interface(*)\Bytes Received/sec'
        '\Network Interface(*)\Bytes Sent/sec'
        '\Network Interface(*)\Bytes Total/sec'
        '\Network Interface(*)\Packets Received/sec'
        '\Network Interface(*)\Packets Sent/sec'
        '\Network Interface(*)\Packets Received Errors'
        '\Network Interface(*)\Packets Outbound Errors'
        '\Network Interface(*)\Packets Received Discarded'
        '\Network Interface(*)\Output Queue Length'
        '\Network Interface(*)\Current Bandwidth'
        '\TCPv4\Segments Retransmitted/sec'
        '\TCPv4\Connections Established'
        '\Process(*)\% Processor Time'
        '\Process(*)\IO Read Operations/sec'
        '\Process(*)\IO Write Operations/sec'
        '\Process(*)\IO Read Bytes/sec'
        '\Process(*)\IO Write Bytes/sec'
        '\Process(*)\Working Set'
        '\Process(*)\Private Bytes'
    )

    # SQL Server counters - one block per detected instance
    # Default instance = "SQLServer:", named instance = "MSSQL$NAME:"
    $sqlSuffixes = @(
        'Buffer Manager\Page life expectancy'
        'Buffer Manager\Page reads/sec'
        'Buffer Manager\Page writes/sec'
        'Buffer Manager\Lazy writes/sec'
        'Buffer Manager\Checkpoint pages/sec'
        'Buffer Manager\Readahead pages/sec'
        'SQL Statistics\Batch Requests/sec'
        'SQL Statistics\SQL Compilations/sec'
        'SQL Statistics\SQL Re-Compilations/sec'
        'General Statistics\User Connections'
        'General Statistics\Processes blocked'
        'Memory Manager\Total Server Memory (KB)'
        'Memory Manager\Target Server Memory (KB)'
        'Memory Manager\Memory Grants Pending'
        'Access Methods\Full Scans/sec'
        'Access Methods\Page Splits/sec'
        'Locks(_Total)\Lock Waits/sec'
        'Locks(_Total)\Number of Deadlocks/sec'
        'Databases(*)\Transactions/sec'
        'Databases(*)\Write Transactions/sec'
        'Databases(*)\Log Flushes/sec'
        'Databases(*)\Log Bytes Flushed/sec'
        'Databases(*)\Log Flush Wait Time'
        'Databases(*)\Log Flush Waits/sec'
        'Wait Statistics(*)\Page IO latches'
        'Wait Statistics(*)\Log write waits'
        'Wait Statistics(*)\Network IO waits'
    )
    $sqlPrefixes = @(
        Get-Counter -ListSet 'SQLServer:Buffer Manager', 'MSSQL$*:Buffer Manager' -ErrorAction SilentlyContinue |
            ForEach-Object { ($_.CounterSetName -split ':')[0] } | Sort-Object -Unique
    )
    foreach ($p in $sqlPrefixes) {
        Write-Info "Detected SQL Server counters: $p"
        foreach ($s in $sqlSuffixes) { $paths += "\$($p):$s" }
    }
    if (-not $sqlPrefixes) { Write-Info 'No SQL Server performance counters detected - collecting OS counters only.' }

    # Keep only counters whose counter set exists on this machine
    $setNames = @{}
    Get-Counter -ListSet * -ErrorAction SilentlyContinue | ForEach-Object { $setNames[$_.CounterSetName] = $true }
    $valid = foreach ($c in $paths) {
        $set = ($c.TrimStart('\') -split '\\')[0] -replace '\(.*\)$', ''
        if ($setNames.ContainsKey($set)) { $c } else { Write-Warn2 "Skipping (counter set not present): $c" }
    }
    return $valid
}

function Invoke-Load {
    Assert-Admin
    if (Test-CollectorExists) {
        if ((Get-CollectorState) -eq 'Running') {
            throw "Collector '$CollectorName' is currently running. Run with -StopCollection first."
        }
        Write-Info "Collector '$CollectorName' already exists - recreating it."
        Invoke-Logman @('delete', $CollectorName) | Out-Null
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

    $counters = Get-CounterList
    # logman reads the counter file as ANSI/UTF-16; write as Unicode to be safe with SQL '$' instance names
    $counters | Set-Content -Path $CounterFile -Encoding Unicode
    Write-Info "Counter list ($($counters.Count) entries) written to $CounterFile"

    # Placeholder output path; replaced with a per-run folder on -StartCollection
    $outBase = Join-Path $OutputRoot "${HostName}_perf"
    Invoke-Logman @(
        'create', 'counter', $CollectorName,
        '-cf', $CounterFile,
        '-si', $SampleInterval,
        '-f', 'bin',
        '-max', $MaxFileSizeMB, '-cnf', '0',
        '-o', $outBase,
        '-ow'
    ) | Out-Null

    Write-Ok "Counter data set '$CollectorName' loaded (sample interval: ${SampleInterval}s)."
    Write-Host  "    Next step:  .\$(Split-Path -Leaf $PSCommandPath) -StartCollection"
}

function Invoke-Start {
    Assert-Admin
    if (-not (Test-CollectorExists)) {
        Write-Info 'Counter data set not loaded yet - loading it now.'
        Invoke-Load
    }
    if ((Get-CollectorState) -eq 'Running') {
        $runDir = if (Test-Path $StateFile) { Get-Content $StateFile -Raw } else { $OutputRoot }
        Write-Warn2 "Collection is already running. Output folder: $($runDir.Trim())"
        return
    }

    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runDir = Join-Path $OutputRoot "${HostName}_$stamp"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    # Point the collector at this run's folder; also apply interval if user overrode it
    $updateArgs = @('update', 'counter', $CollectorName, '-o', (Join-Path $runDir "${HostName}_perf"))
    if ($PSBoundParameters.ContainsKey('SampleInterval')) { $updateArgs += @('-si', $SampleInterval) }
    if ($PSBoundParameters.ContainsKey('MaxFileSizeMB'))  { $updateArgs += @('-max', $MaxFileSizeMB) }
    Invoke-Logman $updateArgs | Out-Null

    Invoke-Logman @('start', $CollectorName) | Out-Null
    Set-Content -Path $StateFile -Value $runDir -Encoding ASCII
    "Collection started: $(Get-Date -Format o)" | Set-Content (Join-Path $runDir 'run_info.txt')

    Write-Ok 'Performance collection STARTED.'
    Write-Host ''
    Write-Host '    Output folder : ' -NoNewline; Write-Host $runDir -ForegroundColor Yellow
    Write-Host "    Collector     : $CollectorName (visible in Perfmon > Data Collector Sets > User Defined)"
    Write-Host ''
    Write-Host '    Collection runs in the background and continues after you log off.'
    Write-Host '    It does NOT survive a reboot - re-run -StartCollection after a restart.'
    Write-Host ''
    Write-Host "    When testing is finished run:  .\$(Split-Path -Leaf $PSCommandPath) -StopCollection"
}

function Save-SystemInfo([string]$Dir) {
    $si = Join-Path $Dir 'sysinfo'
    New-Item -ItemType Directory -Path $si -Force | Out-Null
    $jobs = [ordered]@{
        'os.txt'            = { Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory }
        'computer.txt'      = { Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, NumberOfProcessors, NumberOfLogicalProcessors, TotalPhysicalMemory }
        'cpu.txt'           = { Get-CimInstance Win32_Processor | Format-List Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed }
        'disks.txt'         = { Get-Disk | Format-Table Number, FriendlyName, SerialNumber, BusType, Size, PartitionStyle, OperationalStatus -AutoSize | Out-String -Width 300 }
        'physicaldisks.txt' = { Get-PhysicalDisk | Format-Table DeviceId, FriendlyName, MediaType, BusType, Size, LogicalSectorSize, PhysicalSectorSize -AutoSize | Out-String -Width 300 }
        'volumes.txt'       = { Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, AllocationUnitSize, Size, SizeRemaining -AutoSize | Out-String -Width 300 }
        'partitions.txt'    = { Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter, Offset, Size, Type -AutoSize | Out-String -Width 300 }
        'network.txt'       = { Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MtuSize -AutoSize | Out-String -Width 300 }
        'ipconfig.txt'      = { ipconfig /all }
        'iscsi.txt'         = { Get-IscsiSession -ErrorAction SilentlyContinue | Format-List *; Get-IscsiConnection -ErrorAction SilentlyContinue | Format-List * }
        'mpio.txt'          = { mpclaim.exe -s -d 2>&1 }
        'powerplan.txt'     = { powercfg /getactivescheme }
        'hotfixes.txt'      = { Get-HotFix | Sort-Object InstalledOn | Format-Table HotFixID, Description, InstalledOn -AutoSize }
        'counters.txt'      = { Get-Content $CounterFile }
        'collector.txt'     = { logman.exe query $CollectorName }
    }
    foreach ($k in $jobs.Keys) {
        try { & $jobs[$k] 2>&1 | Out-File (Join-Path $si $k) -Width 300 -Encoding UTF8 }
        catch { "ERROR: $_" | Out-File (Join-Path $si $k) -Encoding UTF8 }
    }
}

function New-SystemReport([string]$Dir) {
    $sb = New-Object System.Text.StringBuilder
    function Add-Line([string]$s = '') { [void]$sb.AppendLine($s) }
    function Add-Kv([string]$k, $v)    { if ($null -eq $v -or "$v".Trim() -eq '') { $v = 'n/a' }; [void]$sb.AppendLine(('  {0,-28}: {1}' -f $k, $v)) }
    function Add-Section([string]$t)   { Add-Line; Add-Line ('=' * 78); Add-Line " $t"; Add-Line ('=' * 78) }
    function Invoke-Safe([scriptblock]$b) { try { & $b } catch { Add-Line "  ERROR collecting section: $($_.Exception.Message)" } }
    function GB($bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

    $runInfo = Get-Content (Join-Path $Dir 'run_info.txt') -ErrorAction SilentlyContinue
    Add-Line 'SYSTEM REPORT - SilkPerfCollector'
    Add-Kv 'Host' $HostName
    Add-Kv 'Report generated' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    Add-Kv 'Time zone' ([TimeZoneInfo]::Local.DisplayName)
    foreach ($l in $runInfo) { $k, $v = $l -split ':\s', 2; Add-Kv $k $v }

    Add-Section 'COMPUTER'
    Invoke-Safe {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        Add-Kv 'Manufacturer' $cs.Manufacturer
        Add-Kv 'Model' $cs.Model
        Add-Kv 'Hypervisor present (VM)' $cs.HypervisorPresent
        Add-Kv 'Domain / Workgroup' $cs.Domain
        Add-Kv 'BIOS' "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"
        Add-Kv 'Serial number' $bios.SerialNumber
    }

    Add-Section 'OPERATING SYSTEM / PATCH LEVEL'
    Invoke-Safe {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Add-Kv 'OS' $os.Caption
        Add-Kv 'Edition' $cv.EditionID
        Add-Kv 'Display version' $cv.DisplayVersion
        Add-Kv 'Version' $os.Version
        Add-Kv 'Build (incl. patch / UBR)' "$($cv.CurrentBuild).$($cv.UBR)"
        Add-Kv 'Architecture' $os.OSArchitecture
        Add-Kv 'Install date' $os.InstallDate
        Add-Kv 'Last boot' $os.LastBootUpTime
        $up = (Get-Date) - $os.LastBootUpTime
        Add-Kv 'Uptime' ('{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes)
        $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending)
        Add-Kv 'Installed hotfixes' $hf.Count
        if ($hf) {
            Add-Kv 'Latest hotfix' "$($hf[0].HotFixID) ($($hf[0].Description), installed $($hf[0].InstalledOn.ToString('yyyy-MM-dd')))"
            Add-Line '  Last 10 hotfixes:'
            $hf | Select-Object -First 10 | ForEach-Object {
                Add-Line ('    {0,-12} {1,-18} {2}' -f $_.HotFixID, $_.Description, $_.InstalledOn.ToString('yyyy-MM-dd'))
            }
        }
    }

    Add-Section 'CPU'
    Invoke-Safe {
        $cpus = @(Get-CimInstance Win32_Processor)
        $cores = ($cpus | Measure-Object NumberOfCores -Sum).Sum
        $lps   = ($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum
        Add-Kv 'Model' (($cpus | Select-Object -ExpandProperty Name -Unique) -join '; ').Trim()
        Add-Kv 'Sockets' $cpus.Count
        Add-Kv 'Physical cores (total)' $cores
        Add-Kv 'Logical processors (total)' $lps
        Add-Kv 'Hyper-threading / SMT' $(if ($lps -gt $cores) { 'Enabled' } else { 'Disabled / not reported' })
        Add-Kv 'Max clock speed' "$($cpus[0].MaxClockSpeed) MHz"
        if ($cpus[0].L3CacheSize) { Add-Kv 'L2 / L3 cache per socket' "$($cpus[0].L2CacheSize) KB / $($cpus[0].L3CacheSize) KB" }
        $numa = @(Get-Counter -ListSet 'NUMA Node Memory' -ErrorAction SilentlyContinue).PathsWithInstances |
                ForEach-Object { if ($_ -match '\((\d+)\)') { $Matches[1] } } | Sort-Object -Unique
        if ($numa) { Add-Kv 'NUMA nodes' @($numa).Count }
        Add-Kv 'Power plan' ((powercfg /getactivescheme) -replace '^.*\((.*)\).*$', '$1')
    }

    Add-Section 'MEMORY'
    Invoke-Safe {
        $cs = Get-CimInstance Win32_ComputerSystem
        $os = Get-CimInstance Win32_OperatingSystem
        Add-Kv 'Total physical memory' (GB $cs.TotalPhysicalMemory)
        Add-Kv 'Free at report time' (GB ($os.FreePhysicalMemory * 1KB))
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($dimms) {
            Add-Kv 'Memory modules' $dimms.Count
            $dimms | Group-Object Capacity, Speed | ForEach-Object {
                $d = $_.Group[0]; $spd = if ($d.Speed) { " @ $($d.Speed) MHz" } else { '' }; Add-Line ('    {0} x {1}{2}' -f $_.Count, (GB $d.Capacity), $spd)
            }
        }
        Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Kv 'Page file' "$($_.Name) allocated $($_.AllocatedBaseSize) MB, peak use $($_.PeakUsage) MB"
        }
    }

    Add-Section 'SQL SERVER'
    Invoke-Safe {
        $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
        if (-not $inst) { Add-Line '  No SQL Server instances found.'; return }
        foreach ($p in $inst.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($p.Value)\Setup" -ErrorAction SilentlyContinue
            $svc = if ($p.Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$($p.Name)" }
            $state = (Get-Service $svc -ErrorAction SilentlyContinue).Status
            Add-Kv "Instance $($p.Name)" "$($setup.Edition), version $($setup.PatchLevel), service $state"
        }
    }

    Add-Section 'DISKS'
    Invoke-Safe {
        Add-Line ((Get-Disk | Sort-Object Number | Format-Table Number, FriendlyName, BusType,
            @{n='Size(GB)';e={[math]::Round($_.Size/1GB,1)}}, PartitionStyle, OperationalStatus -AutoSize |
            Out-String -Width 200).TrimEnd())
        Add-Line
        Add-Line ((Get-Volume | Where-Object Size | Sort-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, FileSystem,
            @{n='AllocUnit';e={$_.AllocationUnitSize}}, @{n='Size(GB)';e={[math]::Round($_.Size/1GB,1)}},
            @{n='Free(GB)';e={[math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize | Out-String -Width 200).TrimEnd())
    }

    Add-Section 'NETWORK'
    Invoke-Safe {
        Add-Line ((Get-NetAdapter | Sort-Object Name | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MtuSize -AutoSize |
            Out-String -Width 200).TrimEnd())
    }

    $path = Join-Path $Dir 'system_report.txt'
    $sb.ToString() | Out-File $path -Encoding UTF8 -Width 300
    return $path
}

function Invoke-Stop {
    Assert-Admin
    if (-not (Test-CollectorExists)) { throw "Collector '$CollectorName' is not loaded - nothing to stop." }
    if (-not (Test-Path $StateFile)) { throw "No active run found ($StateFile missing). Was -StartCollection used?" }
    $runDir = (Get-Content $StateFile -Raw).Trim()

    if ((Get-CollectorState) -eq 'Running') {
        Invoke-Logman @('stop', $CollectorName) | Out-Null
        Write-Ok 'Performance collection STOPPED.'
        Start-Sleep -Seconds 2   # let logman flush/close the .blg
    } else {
        Write-Warn2 'Collector was not running; packaging the last run anyway.'
    }
    "Collection stopped: $(Get-Date -Format o)" | Add-Content (Join-Path $runDir 'run_info.txt')

    $blgs = @(Get-ChildItem -Path $runDir -Filter *.blg -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $blgs) { throw "No .blg files found in $runDir - collection produced no data." }

    Write-Info 'Converting to CSV...'
    $csv = Join-Path $runDir "${HostName}_perf.csv"
    $relogArgs = @($blgs.FullName) + @('-f', 'csv', '-o', $csv, '-y')
    $r = & relog.exe @relogArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "relog to CSV failed (BLG files still included):`n$r" }

    Write-Info 'Collecting system configuration...'
    Save-SystemInfo $runDir
    Write-Info 'Generating system report...'
    $report = New-SystemReport $runDir

    $zip = "$runDir.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item $StateFile -Force

    $sizeMB = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Write-Host ''
    Write-Ok 'Results packaged.'
    Write-Host '    SEND THIS FILE FOR ANALYSIS: ' -NoNewline; Write-Host $zip -ForegroundColor Yellow
    Write-Host "    Size: $sizeMB MB   (raw data also left in $runDir)"
}

function Invoke-Status {
    $state = Get-CollectorState
    Write-Host "Collector : $CollectorName"
    Write-Host "State     : $state"
    if (Test-Path $StateFile) { Write-Host "Output    : $((Get-Content $StateFile -Raw).Trim())" }
    if ($state -ne 'NotLoaded') { Invoke-Logman @('query', $CollectorName) | Write-Host }
}

function Invoke-Remove {
    Assert-Admin
    if (-not (Test-CollectorExists)) { Write-Info 'Collector not loaded - nothing to remove.'; return }
    if ((Get-CollectorState) -eq 'Running') { throw 'Collector is running. Run -StopCollection first.' }
    Invoke-Logman @('delete', $CollectorName) | Out-Null
    Write-Ok "Collector '$CollectorName' removed. Output files under $OutputRoot were kept."
}

switch ($PSCmdlet.ParameterSetName) {
    'Load'   { Invoke-Load }
    'Start'  { Invoke-Start }
    'Stop'   { Invoke-Stop }
    'Status' { Invoke-Status }
    'Remove' { Invoke-Remove }
    default  { Get-Help $PSCommandPath -Detailed }
}
