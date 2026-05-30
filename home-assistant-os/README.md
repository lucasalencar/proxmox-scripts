# Home Assistant OS

Smart home platform running as a Proxmox VM.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the VM using the community HAOS script. |
| `update.sh` | Checks VM status and attempts `ha core update` / `ha supervisor update` via guest agent. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
