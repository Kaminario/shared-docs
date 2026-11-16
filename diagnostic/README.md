# Windows performance collector

`SilkPerfCollector.ps1` records Windows performance counters while you run a test, then packs the results and a system report into one zip file for you to send us.

It uses the Perfmon tools built into Windows (`logman` and `relog`), so you don't need to install anything.

## Requirements

- Windows Server 2016 or later, with Windows PowerShell 5.1.
- A PowerShell window opened with **Run as Administrator**.
- Free space on `C:` for the output. For a run of several hours, allow at least 1 GB.

## Steps

1. Copy `SilkPerfCollector.ps1` to the host, for example to `C:\Silk`.

2. Open PowerShell as Administrator and go to that folder:

   ```powershell
   cd C:\Silk
   ```

   If the script is blocked by the execution policy, put `powershell -ExecutionPolicy Bypass -File` in front of each command below. For example:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\SilkPerfCollector.ps1 -LoadCounters
   ```

3. Load the counters:

   ```powershell
   .\SilkPerfCollector.ps1 -LoadCounters
   ```

4. Start the collection just before you start your test:

   ```powershell
   .\SilkPerfCollector.ps1 -StartCollection
   ```

   The script prints the folder where the data is being written, for example `C:\PerfLogs\SilkPerf\<host>_<date>_<time>`.

5. Run your test. Collection keeps running if you log off.

6. When the test is finished, stop the collection:

   ```powershell
   .\SilkPerfCollector.ps1 -StopCollection
   ```

   The script prints the path of the zip file, for example:

   ```
   SEND THIS FILE FOR ANALYSIS: C:\PerfLogs\SilkPerf\<host>_<date>_<time>.zip
   ```

7. Send us that zip file.

## Options

| Option | What it does |
|---|---|
| `-LoadCounters` | Creates the counter data set. Run it once per host. |
| `-StartCollection` | Starts collecting and prints the output folder. If the counters aren't loaded yet, it loads them first. |
| `-StopCollection` | Stops collecting, writes the system report and creates the zip. |
| `-Status` | Shows whether collection is running and where the output goes. |
| `-Remove` | Deletes the counter data set. Collected files are kept. |
| `-SampleInterval <seconds>` | Time between samples, used with `-LoadCounters` or `-StartCollection`. The default is 5. |
| `-OutputRoot <folder>` | Where the output goes. The default is `C:\PerfLogs\SilkPerf`. If you change it, use the same value for every command. |

For example, to sample every 2 seconds:

```powershell
.\SilkPerfCollector.ps1 -LoadCounters -SampleInterval 2
```

## What is collected

- **CPU**: utilization per core, privileged and user time, interrupts and DPCs, processor queue length.
- **Memory**: available memory, commit, paging.
- **Disks**: every counter for every physical disk and every volume, including mount points: IOPS, throughput, latency, I/O size, queue length and idle time.
- **Network**: throughput, packets, errors and discards per adapter, plus TCP retransmits.
- **Processes**: CPU and I/O per process.
- **SQL Server**: buffer pool, batch requests, compilations, log flushes, memory grants and waits. These counters are added only if SQL Server is installed. Without SQL Server, the script collects the Windows counters only.

## What is in the zip

| File | Contents |
|---|---|
| `system_report.txt` | CPU model, sockets, cores and logical processors; total memory; OS version, build and patch level, and recent hotfixes; SQL Server instances and versions; disks, volumes and network adapters. |
| `<host>_perf_*.blg` | The raw counter data. It opens in Perfmon. |
| `<host>_perf.csv` | The same data as CSV. |
| `sysinfo\` | Detailed output for disks, partitions, volumes, network, iSCSI sessions, MPIO, power plan and hotfixes. |
| `run_info.txt` | Collection start and stop times. |

The zip doesn't contain passwords or application data.

## Notes

- **Reboots:** collection stops if the server restarts. After the reboot, run `-StartCollection` again. That starts a new folder, so send both zip files.
- **Large runs:** the `.blg` file starts a new part every 1 GB, and `-StopCollection` merges all the parts into one CSV.
- **Cleanup:** to remove the data set when you're done, run `.\SilkPerfCollector.ps1 -Remove`, then delete `C:\PerfLogs\SilkPerf` if you no longer need the files.
