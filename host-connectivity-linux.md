# Attach a volume to a Linux host

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
  -d '{"name":"<host name>","type":"Linux","connectivity_type":"iSCSI"}'
```

The reply contains the host's `id`. If the host already exists, read its id with `GET https://<sdp>/api/v2/hosts?name=<host name>` using the same `-u` option.

## 2. Match the real server to that host

The SDP host is only a name until you give it the server's iSCSI IQN. The names of the two do not have to match. The IQN is what links them.

### 2a. Read the server's IQN

```bash
grep InitiatorName /etc/iscsi/initiatorname.iscsi
```

If the file is missing, install the iSCSI tools first (see step 3b).

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

**Network.** The host must reach the SDP data address on port 3260. Check it:

```bash
timeout 4 bash -c '</dev/tcp/<SDP data IP>/3260' && echo open || echo closed
```

If it says `closed`, the host cannot reach the SDP data network. This usually happens when the host has a separate network card for storage. Add a route through that card. This one is saved, so it survives a reboot. `nmcli con show` lists the connection names.

```bash
sudo nmcli con mod "<storage connection>" +ipv4.routes "<SDP data network>/<prefix> <gateway>"
sudo nmcli con up "<storage connection>"
```

For example, for the SDP data network 10.0.1.0/25 through a router at 10.0.0.129: `sudo nmcli con mod "System eth1" +ipv4.routes "10.0.1.0/25 10.0.0.129"`. Run the check again. Skip this if it already says `open`. If the host has only one network card, this route does not apply. Check the route on the SDP above instead.

**Install the tools and set up multipath for the SDP.**

```bash
sudo dnf install -y iscsi-initiator-utils device-mapper-multipath
```

`/etc/multipath.conf` for the SDP (save a copy of any existing file first):

```
defaults {
    find_multipaths no
    user_friendly_names yes
    polling_interval 1
    verbosity 2
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^sda$"
    device {
        vendor "NVME"
        product "Microsoft NVMe Direct Disk"
    }
    device {
        vendor "Msft"
        product "Virtual Disk"
    }
}
devices {
    device {
        vendor "SILK"
        product "SDP"
        path_grouping_policy multibus
        path_checker tur
        path_selector "queue-length 0"
        no_path_retry fail
        hardware_handler "0"
        failback immediate
        fast_io_fail_tmo 2
        dev_loss_tmo 3
        max_sectors_kb 1024
    }
    device {
        vendor "SILK"
        product "KDP"
        path_grouping_policy multibus
        path_checker tur
        path_selector "queue-length 0"
        no_path_retry fail
        hardware_handler "0"
        failback immediate
        fast_io_fail_tmo 2
        dev_loss_tmo 3
        max_sectors_kb 1024
    }
    device {
        vendor "KMNRIO"
        product "KDP"
        path_grouping_policy multibus
        path_checker tur
        path_selector "queue-length 0"
        no_path_retry fail
        hardware_handler "0"
        failback immediate
        fast_io_fail_tmo 2
        dev_loss_tmo 3
        max_sectors_kb 1024
    }
}
blacklist_exceptions {
    property "(ID_SCSI_VPD|ID_WWN|ID_SERIAL)"
}
```

The blacklist keeps multipath away from local disks. The device entries tell it to use all paths to the SDP at once and to fail over quickly when a path drops.

`/usr/lib/udev/rules.d/98-sdp-io.rules` (I/O timeout and scheduler for SDP disks):

```
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL}=="2002*", ATTR{device/timeout}="300"
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL}=="2002*", ATTR{queue/scheduler}="none"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DM_UUID}=="mpath-2002*", ATTR{queue/scheduler}="none"
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL}=="280b*", ATTR{device/timeout}="300"
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL}=="280b*", ATTR{queue/scheduler}="none"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DM_UUID}=="mpath-280b*", ATTR{queue/scheduler}="none"
```

**Start the services, then discover and log in.**

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo systemctl enable --now multipathd iscsid
sudo systemctl restart multipathd
sudo iscsiadm -m discovery -t sendtargets -p <SDP data IP>:3260
sudo iscsiadm -m node -o update -n node.session.nr_sessions -v 12
sudo iscsiadm -m node -o update -n node.startup -v automatic
sudo iscsiadm -m node -L all
sudo multipath -ll
```

Set this up once per host, before you map volumes to it.

### 3c. Find the disk and prepare it

**Formatting erases the disk. Use these commands only on a new, empty volume.**

```bash
sudo iscsiadm -m session --rescan
sudo multipath -ll
```

The volume appears as `/dev/mapper/mpathX`. Check that its serial matches the volume's `scsi_sn`. You may also see a small 256 KB device. That is the SDP control device, so leave it alone. Then format and mount your volume:

```bash
sudo mkfs.xfs /dev/mapper/<mpathX>
sudo mkdir -p /mnt/<dir>
sudo mount /dev/mapper/<mpathX> /mnt/<dir>
```

For a mount that survives a reboot, add the volume's UUID (`blkid`) to `/etc/fstab` with the `_netdev` option.

**If you use ext4 instead of XFS**, format and mount with these options:

```bash
sudo mkfs.ext4 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 /dev/mapper/<mpathX>
sudo mkdir -p /mnt/<dir>
sudo mount -o sync,noatime,barrier=0 /dev/mapper/<mpathX> /mnt/<dir>
```
