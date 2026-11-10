# shared-docs

Shared documentation for working with Silk products. The guides are written to be followed step by step, with commands you can copy and run.

Each file covers one task. Pick the one that matches your system and follow it from the top.

## Files

| File | Description |
|---|---|
| [host-connectivity-windows.md](host-connectivity-windows.md) | Connect a Windows host to a Silk Data Platform (SDP) over iSCSI using the SDP REST API: register the host, link its IQN, map a volume, connect, set up multipath, and bring the disk online. |
| [host-connectivity-linux.md](host-connectivity-linux.md) | Connect a Linux host to a Silk Data Platform (SDP) over iSCSI using the SDP REST API: register the host, link its IQN, map a volume, connect, set up multipath, then format and mount the volume. |

## Using the guides

- Replace every `<placeholder>` in a command with your own value before you run it. Each guide lists them at the top.
- Run the SDP API commands from a machine that is not the host you are attaching.
- If a step fails, send us the command and its output.
