# ChargeBypassCap RE404

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap-RE404?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-RE404/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-RE404)

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

Userspace 80% charge cap for POCO X3 Pro (vayu). No kernel source needed, no app needed, no settings to flip.

## Why

Stock Battery protection cannot be trusted to hold 80%: on this phone it
blew straight past 80% to 84% still charging at full current. This module
replaces it entirely in userspace: it watches the battery and drives the
kernel's standard suspend switch directly.

## How it works

The kernel exposes bypass control through the standard power_supply node:

- `/sys/class/power_supply/battery/input_suspend`
- Write `1`: input suspended, battery current drops to ~0 mA, phone runs
  off the cable. Write `0`: charging resumes.
- Verified by direct test on RE404: `1` gave 2 mA + `Not charging`,
  `0` ramped back to full -1.57A charging.

A small root daemon (`bypasscap.sh`, started at boot by `service.sh`)
polls the battery every 30 seconds while the cable is plugged in:

| Battery | State | Action |
| --- | --- | --- |
| Reaches 80% while charging | Normal | Write `1`: hold at 80, phone runs off the cable |
| Sinks to 78% while suspended | Holding | Write `0`: charging resumes |
| 79%, or 100% trickle | Either | Left alone (deadband) |
| Fresh plug-in below 80%, stuck suspended | Suspended | Write `0`: plug in means intent to charge |
| Holding, but current flows past grace period | Holding | You released it manually: latch override till unplug |
| Unplugged | Any | Clear session state; next plug starts capped again |

The 2% gap between engage and release stops the switch from flapping.

## Live status

The module description in the KernelSU manager always shows the live state,
rewritten by the daemon every poll:

| Display | Meaning |
| --- | --- |
| 🔋 charging 76% | Filling normally, cap engages at 80% |
| ⛔ bypass ON, holding 88% | Resting at the cap, phone on cable power |
| 🔓 override till unplug (92%) | Heading to 100%, auto-resets on unplug |
| ⏸ idle | Suspended by your own hand, daemon leaving it alone |
| 🔌 unplugged | Daemon idle |

## Installation

**KernelSU manager (recommended):**
Modules > Install from storage > pick the release ZIP from the
[releases page](https://github.com/9M2PJU/ChargeBypassCap-RE404/releases). Reboot.

**Manual (adb, root):**
copy this repository's files to `/data/adb/modules/chargebypasscap-re404/`,
`chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.

Verify: `su -c 'tail /data/adb/chargebypasscap-re404/cap.log'` should show the
daemon starting, and the module description shows live status.

## Usage

Do nothing day to day: plug in, it caps at 80.

**Travel-day full charge:** tap the module **action button** once. It
releases bypass and latches override till unplug. Tap it again to resume the
cap (it re-holds within ~30s if at 80%+). The button also prints battery
state, daemon PID, and recent log.

## Requirements

- Root with boot-script support (KernelSU tested; Magisk/APatch should work
  since `service.sh` is a plain boot script).
- A kernel that honors `input_suspend` (RE404 verified by direct write test;
  stock PMI stack usually works too). Without it, the daemon writes into the
  void: it then sees current still flowing after its own write and latches
  override (fails safe, but the cap will not work).
- The N0Kontzzz Kernel Manager app is OPTIONAL: it writes the same node, so
  its bypass toggle remains usable as a manual backup (last writer wins; the
  daemon leaves manually-suspended states alone, so the two do not fight).
- Wired charging only (the wireless path is untested).

## Files

- `service.sh` - started by KernelSU on boot, launches the daemon detached.
- `bypasscap.sh` - the daemon (self-backgrounds).
- `action.sh` - action button: toggles full-charge override AND prints
  instant status (battery, state, cap mode, daemon PID, recent log).
- `uninstall.sh` - stops the daemon and removes state on module removal.
- `module.prop` - metadata; its description doubles as the live status line.
- `module.yaml` - manifest for the KernelSU Modules listing.

## Logging

- State dir: `/data/adb/chargebypasscap-re404/` (holding, override, last_status, cap.log)
- Log: `/data/adb/chargebypasscap-re404/cap.log` - check what it did overnight.

## Credits

Bypass verified on the RE404 kernel (deutereum). Sibling project for POCO F7:
[ChargeBypassCap](https://github.com/9M2PJU/ChargeBypassCap).

## License

GPL-3.0. See LICENSE.
