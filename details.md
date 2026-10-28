The script was a temporary fixed-purpose CIMC deployment helper. It is not currently runnable because both it and `/tmp/CIMCown-audited` were removed from the host.

```text
usage: m5_fan_deploy.py [-h] --target TARGET
                        [--username USERNAME]
                        [--payload-dir PAYLOAD_DIR]
                        [--inspect-init-only]
                        [--inspect-fan-only]
                        [--arm-only]
                        [--update-support-only]
```

The CIMC password must be supplied as the first line on standard input; it is not accepted as an argument.

### Arguments

| Argument | Default | Purpose |
|---|---|---|
| `--target` | Required | CIMC address, previously `192.168.1.105` |
| `--username` | `admin` | CIMC username |
| `--payload-dir` | `/tmp/fan-controller` | Directory containing reviewed deployment payloads |
| `--inspect-init-only` | Off | Exports `/etc/init.d/nihuu-update` to `/tmp/cimc-nihuu-update` |
| `--inspect-fan-only` | Off | Reads back fan log, active service target/run script, and persistence flags |
| `--arm-only` | Off | Uploads the one-shot HUU trigger and `host_reboot_flag` |
| `--update-support-only` | Off | Uploads only the rollback script and rollback trigger |

With no mode flag, it performs a complete deployment:

1. Uploads the fan curve, HUU trampoline, rollback script, installer script and installer library.
2. Restricts destinations to `/mnt/jffs2/`.
3. Invokes `/mnt/jffs2/fan-installer.so`.
4. Logs out of CIMC.

### Historical invocation pattern

It needed root privileges because its callback HTTP server binds to port 80:

```bash
read -rsp 'CIMC password: ' cimc_password
printf '%s\n' "$cimc_password" |
  sudo /tmp/CIMCown-audited/.venv/bin/python \
    /tmp/m5_fan_deploy.py \
    --target 192.168.1.105 \
    --username admin
unset cimc_password
```

For readback only:

```bash
printf '%s\n' "$cimc_password" |
  sudo /tmp/CIMCown-audited/.venv/bin/python \
    /tmp/m5_fan_deploy.py \
    --target 192.168.1.105 \
    --inspect-fan-only
```

The mode flags are not formally mutually exclusive. If multiple are provided, precedence is:

```text
inspect-init → inspect-fan → arm → update-support → full deployment
```

The reconstructed source is at [m5_fan_deploy.recovered.py](/tmp/m5_fan_deploy.recovered.py). It should remain an archival reference rather than the normal operational interface.
