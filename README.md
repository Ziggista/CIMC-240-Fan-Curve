# Cisco UCS C240 M5 custom fan controller

A conservative, temperature-responsive fan controller for a Cisco UCS C240 M5
whose two passive NVIDIA V100 PCIe GPUs force CIMC into a High Power fan policy.
Stock, all six fan modules ran at ~13,400–14,700 RPM while the machine was idle.
This controller holds a quiet 10% floor and ramps on real sensor data, dropping
idle fans to ~3,200–3,500 RPM.

> **Unsupported CIMC modification.** Disable it and restore Cisco's native fan
> service before applying any CIMC, BIOS, HUU, or other Cisco firmware update.
> See the rollback section of the runbook.

Full runbook, fan curves, and commissioning results:
[docs/cisco-c240-m5-fan-controller.md](docs/cisco-c240-m5-fan-controller.md).

## How it works

Two cooperating parts:

1. **On the CIMC** (`cimc/`) — `custom-fan-curve.sh` replaces Cisco's supervised
   `rack_fan_control` service. Every 2 seconds it reads both CPU sockets via
   PECI and the board sensors via `ipmi-sensor`, computes a duty from its CPU
   and board-sensor curves, takes the maximum of that and the GPU demand fetched
   over HTTP, and drives PWM controllers `0 1 4 5 6 7` with `pwmtest`. Any
   missing/invalid mandatory sensor or failed PWM write immediately requests
   100%. It raises duty instantly and lowers it in 5-point steps.

2. **On the Ubuntu GPU host** (`host/`) — `gpu-fan-demand.py` is a small HTTP
   server that runs `nvidia-smi` on the two V100s and serves a single duty
   number (10–100) at `GET /duty`, based on the hottest GPU's temperature,
   utilisation, and power, with 2°C release hysteresis. The passive cards are
   invisible to CIMC, so this feeds their thermal demand back in. An unreachable
   or malformed response makes the CIMC fall back to 30% rather than the quiet
   floor.

## Installation and persistence (`cimc/`)

The controller files live on the CIMC's persistent JFFS2 flash (`/mnt/jffs2`).

- `fixed-purpose-installer.c` — compiled to a one-shot ARM library whose
  constructor only `execl`s the installer. It offers no shell, listener, or
  command channel. Used once during initial deployment via an authenticated
  argument-injection path on an owner-authorised server (CVE-2026-20288).
- `install-fan-controller.sh` — writes the scripts into place, saves the native
  service's run target, swaps `rack_fan_control/run` to exec the custom
  controller, and stops the native daemon.
- `nihuu-trampoline.sh` — hooks Cisco's late HUU boot init so it re-arms the
  one-shot trigger and re-applies the service swap on every CIMC reboot. This is
  what makes the modification persist.
- `rollback-fan-controller.sh` / `rollback-trigger.sh` — drive all fans to 100%,
  remove the persistence hooks, stop the controller, and restore Cisco's native
  supervised fan service.

## The GPU demand endpoint (`host/`)

- `gpu-fan-demand.py` — the HTTP server. Bind address and port are read from
  `GPU_FAN_DEMAND_ADDR` (default `0.0.0.0`) and `GPU_FAN_DEMAND_PORT`
  (default `80`). Install it where the unit expects it, e.g.
  `/usr/local/libexec/cisco-v100-gpu-fan-demand`.
- `gpu-fan-demand.service` — a hardened systemd unit (`NoNewPrivileges`,
  `ProtectSystem=strict`) that keeps the endpoint running.

Point the CIMC controller at this host by setting `GPU_DEMAND_URL` at the top of
`cimc/custom-fan-curve.sh` to `http://<host-ip>/duty`.

## Safety notes

- Never commit the CIMC password or session material.
- Patching CIMC firmware is the correct security posture, but it may remove the
  file-write method this controller relies on. Roll back first, verify Cisco's
  native fan service is active, then update.
