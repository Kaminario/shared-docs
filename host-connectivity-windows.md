# Attach a volume to a Windows host

Silk Data Platform (SDP). Register the host, link your real server to it, and mount a volume. Every step uses the SDP REST API and the server's own iSCSI initiator.

These steps assume iSCSI. If you use Fibre Channel or NVMe, they do not apply. If a step fails, send us the command and its output.

## Replace these before you run anything

| Placeholder | Meaning |
|---|---|
| `<sdp>` | The SDP management address. Run the commands from a machine that is not the host you are attaching, for example the Flex VM, or use the SDP web UI. |
| `admin:<sdp admin password>` | Your SDP username and password. The API uses HTTP basic authentication, so no token is needed. |
| `<SDP data IP>` | The SDP iSCSI data address (port 3260), not the management address. There is one per c-node. Step 3b shows how to read them from Flex. |
| `<flex>` | The address of your Flex. It is only used in step 3b to read the SDP data addresses. |

The `-k` flag skips the certificate check because the SDP uses its own certificate. Drop it if you trust the certificate.

## 1. Register the host in Silk

Create the host.

```bash
curl -sk -u 'admin:<sdp admin password>' -H 'Content-Type: application/json' \
  -X POST https://<sdp>/api/v2/hosts \
  -d '{"name":"<host name>","type":"Windows","connectivity_type":"iSCSI"}'
```

The reply contains the host's `id`. If the host already exists, read its id with `GET https://<sdp>/api/v2/hosts?name=<host name>` using the same `-u` option.

## 2. Match the real server to that host

The SDP host is only a name until you give it the server's iSCSI IQN. The names of the two do not have to match. The IQN is what links them.

### 2a. Read the server's IQN

On a fresh Windows server the IQN is empty until the iSCSI service is running, so start it first (PowerShell, as Administrator).

```powershell
Set-Service MSiSCSI -StartupType Automatic; Start-Service MSiSCSI
(Get-InitiatorPort -ConnectionType iSCSI).NodeAddress
```

### 2b. Link the IQN to the SDP host

```bash
curl -sk -u 'admin:<sdp admin password>' -H 'Content-Type: application/json' \
  -X POST https://<sdp>/api/v2/host_iqns \
  -d '{"host":{"ref":"/hosts/<host id>"},"iqn":"<iqn>"}'
```

### 2c. Check it

```bash
curl -sk -u 'admin:<sdp admin password>' "https://<sdp>/api/v2/host_iqns?iqn=<iqn>"
```

The reply should name your host. The same lookup also tells you which Silk host belongs to a given server.

## 3. Mount the volume on the host

### 3a. Map the volume to the host

First read the host id and the volume id. Each reply has an `id` field.

```bash
curl -sk -u 'admin:<sdp admin password>' "https://<sdp>/api/v2/hosts?name=<host name>"
curl -sk -u 'admin:<sdp admin password>' "https://<sdp>/api/v2/volumes?name=<volume name>"
```

Use the full name. The filter `name` is lowercase and matches the whole name. For part of a name use `name__contains=<part of the name>`. If a command prints nothing, run it again without `-s` to see the error. Then map the volume:

```bash
curl -sk -u 'admin:<sdp admin password>' -H 'Content-Type: application/json' \
  -X POST https://<sdp>/api/v2/mappings \
  -d '{"host":{"ref":"/hosts/<host id>"},"volume":{"ref":"/volumes/<volume id>"}}'
```

The volume reply also shows its `scsi_sn`, which you will use to find the disk.

### 3b. Connect the host to the SDP over iSCSI

If the host is already connected, a newly mapped volume appears by itself. Skip this step and go to 3c.

**Find the SDP data addresses.** Ask Flex for the c-nodes of your SDP. The `external_data1` address of each c-node is the iSCSI data address, so each one is a `<SDP data IP>` below.

```bash
TOKEN=$(curl -sk -X POST https://<flex>/api/v1/auth/local/login \
  -d 'username=<flex user>' --data-urlencode 'password=<flex password>' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -sk -H "Authorization: Bearer $TOKEN" https://<flex>/api/v1/pages/nodes \
  | python3 -c "import sys,json; [print(n['name'], n['network_connectivity']['external_data1']['ip']) for c in json.load(sys.stdin)['clusters'] for n in c['cnodes']]"
```

The output is one line per c-node, for example `c-node1 10.0.1.4` and `c-node2 10.0.1.5`. If your Flex manages more than one SDP, use the c-nodes of yours. Try the Flex password only once: repeated wrong attempts lock the account.

> **Run the SDP commands from a machine that is not the host you are attaching**, for example the Flex VM, or use the SDP web UI. Once the route below exists, the SDP answers the host's subnet through its data port, so API calls made from the host get no reply and hang.

**Route on the SDP.** If the host is in a different subnet from the SDP data network, the SDP needs a route back to the host's subnet. Without it the SDP cannot answer, and port 3260 stays closed from the host even though the SDP management port works. Create the route once for each host subnet. It applies to all c-nodes. First check whether it exists:

```bash
curl -sk -u 'admin:<sdp admin password>' "https://<sdp>/api/v2/static_routes"
```

If there is no entry for the host's subnet, create it:

```bash
curl -sk -u 'admin:<sdp admin password>' -H 'Content-Type: application/json' \
  -X POST https://<sdp>/api/v2/static_routes \
  -d '{"destination_subnet_ip":"<host subnet>","destination_subnet_mask":"<host subnet mask>","gateway_ip":"<data gateway>"}'
```

`<host subnet>` and `<host subnet mask>` are the network of the host's IP address, for example `10.0.2.0` and `255.255.255.128` for a host at 10.0.2.6/25. `<data gateway>` is the router of the SDP data network, normally the first address of the subnet that holds the `external_data1` addresses. For 10.0.1.0/25 that is 10.0.1.1. Skip this if the host is in the same subnet as the SDP data addresses.

**Network.** The host must reach the SDP data address on port 3260. If it uses a second network interface for storage, add a route to the SDP data network through that interface, then check the port:

```powershell
Test-NetConnection <SDP data IP> -Port 3260
```

`TcpTestSucceeded` must be `True`. If it says `False`, the server cannot reach the SDP data network. This usually happens when the server has a separate network card for storage. Add a route that sends the SDP data network through that card, then run the check again. `Get-NetAdapter` lists the card names.

```powershell
New-NetRoute -DestinationPrefix <SDP data network>/<prefix> -InterfaceAlias "<storage NIC>" -NextHop <gateway>
```

For example, if the SDP data IPs are 10.0.1.4 and 10.0.1.5 (network 10.0.1.0/25) and the storage card is called "Ethernet 2" with its router at 10.0.0.129: `New-NetRoute -DestinationPrefix 10.0.1.0/25 -InterfaceAlias "Ethernet 2" -NextHop 10.0.0.129`. Skip this if the check already says `True`. If the host has only one network card, this route does not apply. Check the route on the SDP above instead.

**Connect** (PowerShell, as Administrator). Repeat the portal and connect lines for each SDP data address you have.

```powershell
Set-Service MSiSCSI -StartupType Automatic; Start-Service MSiSCSI
New-IscsiTargetPortal -TargetPortalAddress <SDP data IP>
Get-IscsiTarget | Connect-IscsiTarget -IsPersistent $true -IsMultipathEnabled $true
```

For 12 sessions per data address, use this in place of the last line above:

```powershell
$portals = "<SDP data IP 1>","<SDP data IP 2>"
$iqn = (Get-IscsiTarget).NodeAddress
1..12 | ForEach-Object { foreach ($p in $portals) { Connect-IscsiTarget -NodeAddress $iqn -TargetPortalAddress $p -IsMultipathEnabled $true -IsPersistent $true } }
```

**Multipath.** A Windows Server that has the Multipath I/O feature only available, not installed, lists every extra path as a separate disk. With two connections we saw each volume twice.

```powershell
Install-WindowsFeature Multipath-IO
Enable-MSDSMAutomaticClaim -BusType iSCSI
Restart-Computer
```

After the restart, each volume appears once. Reconnect is not needed: the iSCSI sessions and routes persist.

**Tune MPIO.** Run these in an elevated PowerShell after the restart. They set the path timers and the load-balance policy (least queue depth), so a failed path is detected and replaced faster.

```powershell
Set-MPIOSetting -NewPathVerificationState Enabled
Set-MPIOSetting -NewPathVerificationPeriod 1
Set-MPIOSetting -NewPDORemovePeriod 20
Set-MPIOSetting -NewRetryCount 3
Set-MPIOSetting -NewRetryInterval 3
Set-MPIOSetting -CustomPathRecovery Enabled
Set-MPIOSetting -NewDiskTimeout 100
Set-MSDSMGlobalDefaultLoadBalancePolicy LQD
```

**Disk settings.** Turn off delete notifications and the scheduled background defragmentation.

```powershell
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\FileSystem" -Name DisableDeleteNotification -Value 1
Get-ScheduledTask ScheduledDefrag | Disable-ScheduledTask
```

### 3c. Find the disk and prepare it

**Formatting erases the disk. Use these commands only on a new, empty volume.**

```powershell
Update-HostStorageCache
Get-Disk | Where-Object FriendlyName -like 'SILK*' | Format-Table Number,SerialNumber,Size,PartitionStyle,OperationalStatus
```

Silk disks are named `SILK SDP`. You may also see a small 256 KB disk. That is the SDP control device, so leave it alone. Always pick your disk by matching its `SerialNumber` to the volume's `scsi_sn`. Then, with the disk `Number`:

```powershell
Set-Disk -Number <n> -IsOffline $false
Initialize-Disk -Number <n> -PartitionStyle GPT
New-Partition -DiskNumber <n> -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS
```

If the volume already holds data and a partition, skip the last two commands and assign a drive letter or mount point to the existing partition instead.
