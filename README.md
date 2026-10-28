<p align="center">
  <img src="logo.jpg" alt="ChargeBypassCap PMI logo" width="360">
</p>

# ChargeBypassCap PMI

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap-PMI?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI)

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

Userspace 80% charge cap for POCO X3 Pro (vayu). No kernel source needed, no app needed, no settings to flip.

## Tested on

- **Device:** POCO X3 Pro (M2102J20SG, codename vayu)
- **SoC:** Qualcomm Snapdragon 860 (SM8150, msmnile platform - read from the
  phone itself, not a spec sheet)
- **ROM:** MIUI 14.0.15.0.TNRCNXM (China ROM), Android 13
- **Kernel:** RE404 vR3 by deutereum (`4.19.404R`, Neutron Clang 24,
  EEVDF/BPF backports, KowSU) - its advertised Bypass Charging was verified
  by direct sysfs test on this exact setup

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
[releases page](https://github.com/9M2PJU/ChargeBypassCap-PMI/releases). Reboot.

**Manual (adb, root):**
copy this repository's files to `/data/adb/modules/chargebypasscap-pmi/`,
`chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.

Verify: `su -c 'tail /data/adb/chargebypasscap-pmi/cap.log'` should show the
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

## Audit report (2026-10-29, v1.3.1 on POCO X3 Pro)

Method: live checks on the author's phone (POCO X3 Pro, RE404 kernel,
module installed from the v1.3.1 release ZIP) plus a full read of all four
scripts. Live checks ran at 03:19 local; the phone was asleep when this
was written, so no new live probing after that hour.

Live checks, all passed:

- Single daemon: one `sh .../bypasscap.sh` process, alive across the
  phone sleeping and waking. No twins, `service.d` holds no legacy
  scripts, exactly one state dir.
- Installed files match the repo: `bypasscap.sh` md5-identical to
  v1.3.1, `module.prop` at v1.3.1/code 5. `POLL=60` confirmed in the
  installed file, `sh -n` clean.
- Permissions: `action.sh` and `service.sh` `755`. `uninstall.sh` was
  `644`, fixed to `755` on device.
- Node control: `/sys/class/power_supply/battery/input_suspend` present
  and writable. Direct write verified on this exact setup during
  development: `1` pins the battery near 0 mA, `0` resumes full charging.
- Action button: executes, prints accurate battery/state/daemon/log
  status. (Its one test run set an override flag while unplugged; the
  daemon's unplug branch clears such flags every poll, and any plug-in
  clears them too.)
- Idle footprint: same design as its sibling module, wakes every 60 s,
  reads three sysfs files, sleeps. No writes while unplugged.
- Log (`cap.log`): only start lines. No errors.
- `uninstall.sh`: kills the daemon by its exact module path and removes
  only `/data/adb/chargebypasscap-pmi`. Verified by reading, not
  executed.

Bugs found and fixed during this audit:

- `uninstall.sh` shipped `644` (the manager's exec-bit handling proved
  inconsistent across installs). Fixed on device, then fixed in git:
  all scripts are `755` from v1.3.1 on.

Minor nits (cosmetic, no behavior change, left as-is):

- The normal-start log line still says `override via manual tile tap`,
  wording from the tile era. Control has been direct node writes since
  the PMI rewrite.

Verdict: healthy. One resident process, bounded writes (one sysfs node
plus its own state dir), fails safe (a kernel that ignores the node lands
in override, never in a bootloop), clean uninstall.

## Files

- `service.sh` - started by KernelSU on boot, launches the daemon detached.
- `bypasscap.sh` - the daemon (self-backgrounds).
- `action.sh` - action button: toggles full-charge override AND prints
  instant status (battery, state, cap mode, daemon PID, recent log).
- `uninstall.sh` - stops the daemon and removes state on module removal.
- `module.prop` - metadata; its description doubles as the live status line.
- `module.yaml` - manifest for the KernelSU Modules listing.

## Logging

- State dir: `/data/adb/chargebypasscap-pmi/` (holding, override, last_status, cap.log)
- Log: `/data/adb/chargebypasscap-pmi/cap.log` - check what it did overnight.

## Credits

Bypass verified on the RE404 kernel (deutereum). Sibling project for POCO F7:
[ChargeBypassCap](https://github.com/9M2PJU/ChargeBypassCap).

## License

GPL-3.0. See LICENSE.
