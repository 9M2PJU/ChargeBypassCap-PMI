<p align="center">
  <img src="logo.jpg" alt="ChargeBypassCap PMI logo" width="360">
</p>

# ChargeBypassCap PMI

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap-PMI?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI)

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

Userspace adjustable charge cap for POCO X3 Pro (vayu). No kernel source needed, no app needed — set the cap in the module WebUI (Open button).

> **Two variants exist — pick yours:** this repo is for **POCO X3 Pro (vayu)** on RE404 (drives `input_suspend`). For **POCO F7 (onyx)** on Sakata(X) kernels (drives `smart_night`), use [ChargeBypassCap](https://github.com/9M2PJU/ChargeBypassCap). Same daemon logic, different node.

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
polls the battery every 60 seconds while the cable is plugged in
(CAP = your WebUI setting, 50-100%, default 80):

| Battery | State | Action |
| --- | --- | --- |
| Reaches CAP while charging | Normal | Write `1`: hold at CAP, phone runs off the cable |
| Sinks to CAP-2 while suspended | Holding | Write `0`: charging resumes |
| Deadband between, or 100% trickle | Either | Left alone (deadband) |
| Fresh plug-in below CAP, stuck suspended | Suspended | Write `0`: plug in means intent to charge |
| Holding, but current flows past grace period | Holding | You released it manually: latch override till unplug (but see Reboots: external clears within 10 min of start are re-asserted) |
| Reboot with cable in above CAP | Booting | Hammer node to `1` till it sticks, 5-min grace; re-assert if cleared within 10 min of start (v1.6) |
| Unplugged | Any | Clear session state; next plug starts capped again |

The 2% gap between engage and release stops the switch from flapping.

### Reboots (fixed in v1.6, ported from ChargeBypassCap v1.10)

2026-11-04, POCO F7: kernel-flash reboots overnight exposed an adopt bug
that applies equally here (same daemon logic, different node). A reboot
resets `input_suspend` to 0, but the daemon trusted the stale hold and
never re-wrote it. One poll later the resumed charge current looked like
a manual release, latched override, and the battery charged to 100%.
The fix, ported verbatim: hammer the write until it reads back stuck
(5-minute grace, because the daemon starts before the charger stack is
up), and re-assert any node clear within 10 minutes of start instead of
yielding. Fixed and verified across three reboot cycles on onyx; the
vayu reboot test is still pending.

### ROM Battery protection modes

| ROM mode | With this module |
| --- | --- |
| Charge fully | Use this. The module is the sole decider. |
| Stock limiter (any cap/hold mode) | Do not trust it. On vayu the stock protection blew past 80% to 84% at full current; on onyx the 80% limit freezes all charging at any level. Either failure defeats the module. |
| Intelligent / smart top-up | Not recommended. A top-up resume while the module holds reads as a manual release and latches override till unplug (only re-asserted within 10 min of boot). |

None of these matter while the phone is powered off. Offline charging
goes to 100% no matter what, so unplug before a scheduled shutdown if
you want to wake at the cap. Recommended setup: ROM on Charge fully,
module cap at 80%, cable out overnight.

### MIUI toggles in detail (verified on this phone)

MIUI 14 exposes two separate toggles. Both were found enabled (`true`)
in the `com.miui.securitycenter` prefs:

| Toggle | Behavior | With this module |
| --- | --- | --- |
| Battery protection (`cb_always_charge_protect`) | MIUI's own ~80% cap, documented leaky: blew past 80% to 84% at full current on this phone | Redundant at best. The module holds 80% first so stock stays idle — but it leaves a second unobservable voter on the same charger. Turn off. |
| Smart charging (`cb_intellect_charge_protect`) | Night top-up learner: holds ~80%, resumes to 100% before wake | Defeats the cap. Its top-up resume reads to the module as a manual release, latching override till unplug (only re-asserted within 10 min of boot), so the phone finishes to 100%. Turn off. |

Overnight telltale if you keep smart charging on anyway: check the
module description in the KernelSU manager before unplugging in the
morning. `🔓 override` means the top-up disarmed the module overnight;
`⛔ holding` means the cap survived. The daemon log timestamps exactly
when it happened.

## Safety

The module only votes suspend/resume through the standard QTI PMI
property `input_suspend` — the same node kernel-manager apps drive,
same values. It has no path to voltage or current: float voltage,
charge current, JEITA temperature derating, and OVP/OCP/thermal
shutdown stay enforced by the PMIC hardware and lower driver layers no
matter what the module writes, so overvoltage/overcurrent via this
module is not possible. Every stuck state is safe: node stuck at 1 =
phone runs off the cable (a designed mode); stuck at 0 = ordinary
charging; daemon crash = the node just stays put. Sysfs is written only
on state transitions (60s polls, 2% engage/release gap, bounded boot
hammer), a few transitions a day — no relay-chatter on the FETs.
Measured on the author's phone: battery health Good, 32.7C, no charger
fault events in the kernel log. Every bug found so far produced
overcharge to 100% (a longevity nit), never an unsafe electrical state.
One caveat: after a kernel update, glance at the log once — a kernel
that ignores the node would silently neuter the cap, not damage
anything.

## Live status

The module description in the KernelSU manager always shows the live state,
rewritten by the daemon every poll:

| Display | Meaning |
| --- | --- |
| 🔋 charging 76% | Filling normally, cap engages at your setting |
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

**Set your cap:** tap the module **Open** button. A settings page shows live
status plus a slider (50–100%, default 80): pick when bypass triggers on,
tap Save. Charging resumes 2% below the cap. No reboot needed.

Do nothing day to day: plug in, it caps at your setting.

**Travel-day full charge:** tap the module **action button** once. It
releases bypass and latches override till unplug. Tap it again to resume the
cap (it re-holds within ~60s if at cap+ and charging). The button also prints battery
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
scripts. First pass ran at 03:19 local, full re-verification at 04:20
after the phone slept and woke. Every check below was run, not inferred.

Live checks, all passed:

- Single daemon: one `sh .../bypasscap.sh` process (PID 32445, RSS
  ~1.8 MB), alive across 10 h uptime including sleep/wake. No twins,
  `service.d` holds no legacy scripts, exactly one state dir.
- Installed files match the repo: all four scripts md5-identical to
  v1.3.1, `module.prop` at v1.3.1/code 5 (differs only in the live
  `description=` status line, by design). `POLL=60` confirmed in the
  installed file, `sh -n` clean, all scripts `755`.
- Node control: `/sys/class/power_supply/battery/input_suspend` written
  `1 -> 0 -> 1` directly with cable unplugged, each read back correctly,
  left at its original value.
- Action button: tapped ON then OFF. Override latched and cleared
  correctly, status output accurate (battery, daemon PID, cap mode), no
  leftover state files.
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

### Resource usage (measured 2026-10-29, unplugged)

- Memory: one process, VmRSS 1776 KB (~1.7 MB), alive across 10 h
  uptime including sleep/wake. State dir 6 KB total (`cap.log` 202 B,
  capped at 200 lines).
- CPU: 0.11 s (self plus forked helpers) over an 83.9 s window covering
  ~1.4 polls, i.e. about 0.08 s per 60 s poll, 0.13% of one core,
  matching the sibling module's 0.1 s/poll. 14 voluntary context
  switches in the window (~10 per poll: the `cat`/`rm`/`grep`/`sed`
  helpers). No forced preemptions.
- Sleep state: `sleep 60` between polls. Holds no wakelocks, registers
  no alarms, writes nothing while unplugged.
- Bottom line: below anything the battery stats can attribute.

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
