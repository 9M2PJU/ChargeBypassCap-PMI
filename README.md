<p align="center">
  <img src="logo.jpg" alt="ChargeBypassCap PMI logo" width="360">
</p>

# ChargeBypassCap PMI

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap-PMI?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap-PMI)
[![node](https://img.shields.io/badge/node-input_suspend-blue?style=flat-square)](#how-it-works)

Userspace adjustable charge cap via the standard suspend node. No kernel source needed, no app needed - set the cap in the module WebUI (Open button).

> **Two variants exist - pick the one your kernel supports:** this repo drives the standard power_supply `input_suspend`. If your kernel exposes Xiaomi's `smart_night` charger node instead, use [ChargeBypassCap](https://github.com/9M2PJU/ChargeBypassCap). Same daemon logic, different node. See Requirements for the 10-second check.

## Contents

- [Tested on](#tested-on)
- [Why](#why)
- [How it works](#how-it-works)
  - [Reboots (fixed in v1.6)](#reboots-fixed-in-v16)
  - [ROM Battery protection modes](#rom-battery-protection-modes)
  - [MIUI toggles in detail](#miui-toggles-in-detail-verified-on-this-phone)
  - [Chargers](#chargers-5v-holds-pump-fast-charging-leaks-field-evidence-2026-11-05)
  - [Watchdog](#watchdog)
- [Safety](#safety)
- [Live status](#live-status)
- [Installation](#installation)
- [Usage](#usage)
- [Requirements](#requirements)
- [Audit report (2026-10-29)](#audit-report-2026-10-29-v131-on-poco-x3-pro)
- [Audit report (2026-11-04)](#audit-report-2026-11-04-v17-code-on-poco-x3-pro)
- [Files](#files)
- [Logging](#logging)
- [Credits](#credits)
- [License](#license)

## Tested on

- **Device:** POCO X3 Pro (M2102J20SG, codename vayu)
- **SoC:** Qualcomm Snapdragon 860 (SM8150, msmnile platform - read from the
  phone itself, not a spec sheet)
- **ROM:** MIUI 14.0.15.0.TNRCNXM (China ROM), Android 13
- **Kernel:** RE404 vR3 by deutereum (`4.19.404R`, Neutron Clang 24,
  EEVDF/BPF backports, KowSU) - its advertised Bypass Charging was verified
  by direct sysfs test on this exact setup
- **Manager:** KowSU
- **Control node:** `/sys/class/power_supply/battery/input_suspend`
- **ROM setting:** both MIUI toggles off (Battery protection, Smart charging)
- **Cap:** 80% (adjustable 50-100%)
- Anything meeting Requirements works - the above is just the author's setup.

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
  `0` ramped back to full -1.57A charging. (On the 5V path - pump fast
  charging bypasses this node; see the audit report.)

A small root daemon (`bypasscap.sh`, started at boot by `service.sh`)
polls the battery every 60 seconds while the cable is plugged in
(CAP = your WebUI setting, 50-100%, default 80):

| Battery | State | Action |
| --- | --- | --- |
| Reaches CAP while charging | Normal | Write `1`: hold at CAP, phone runs off the cable |
| Sinks to CAP-2 while suspended | Holding | Write `0`: charging resumes |
| Deadband between, or 100% trickle | Either | Left alone (deadband) |
| Fresh plug-in below CAP, stuck suspended | Suspended | Write `0`: plug in means intent to charge |
| Holding, but current flows past grace period | Holding | Nobody asked for release (no OVERRIDE file): re-assert, up to 10 in a row, then yield + override (broken node) |
| Reboot with cable in above CAP | Booting | Hammer node to `1` till it sticks, 5-min grace; re-assert if cleared within 10 min of start (v1.6) |
| Unplugged | Any | Clear session state; next plug starts capped again |

The 2% gap between engage and release stops the switch from flapping.

### Reboots (fixed in v1.6)

The daemon used to trust a stale hold across reboots: a reboot resets
`input_suspend` to 0, and the resumed charge current then looked like a
manual release, latching override and charging past the cap (caught on
the sister onyx build: reboot at 02:00 with cable in, 81% to 100% by
02:35 - same daemon logic). The fix: hammer the write until it reads
back stuck (5-minute grace, because the daemon starts before the
charger stack is up), and re-assert any node clear within 10 minutes of
start instead of yielding. Verified on this phone: reboot with cable in
at 71% adopted the hold, 8+ minutes steady at ~2 mA, zero false
overrides. Since v1.9 the re-assert is unconditional (no more 10-minute
window): any external clear is re-asserted, and only 10 consecutive
failures yield to a node that will not hold.

### ROM Battery protection modes

| ROM mode | With this module |
| --- | --- |
| Both MIUI toggles off | Use this. The module is the sole decider. |
| Stock limiter (any cap/hold mode) | Do not trust it. On this phone stock protection blew past 80% to 84% at full current. A limiter that cannot hold its own cap cannot cooperate with the module. |
| Intelligent / smart top-up | Not recommended. A top-up resume while the module holds is treated as hostile and re-asserted (up to 10 consecutive polls) before the daemon yields - so it still finishes to 100%, minutes later, with the fight in the log. |

None of these matter while the phone is powered off. Offline charging
goes to 100% no matter what, so unplug before a scheduled shutdown if
you want to wake at the cap. Recommended setup: both MIUI toggles off,
module cap at 80%, cable out overnight.

### MIUI toggles in detail (verified on this phone)

MIUI 14 exposes two separate toggles. Both were found enabled (`true`)
in the `com.miui.securitycenter` prefs:

| Toggle | Behavior | With this module |
| --- | --- | --- |
| Battery protection (`cb_always_charge_protect`) | MIUI's own ~80% cap, documented leaky: blew past 80% to 84% at full current on this phone | Redundant at best. The module holds 80% first so stock stays idle - but it leaves a second unobservable voter on the same charger. Turn off. |
| Smart charging (`cb_intellect_charge_protect`) | Night top-up learner: holds ~80%, resumes to 100% before wake | Defeats the cap. Its top-up resume is treated as hostile and re-asserted (up to 10 consecutive polls) before the daemon yields, so the phone still finishes to 100%. Turn off. |

Overnight telltale if you keep smart charging on anyway: check the
module description in the KowSU manager before unplugging in the
morning. `🔓 override` means the top-up disarmed the module overnight;
`⛔ holding` means the cap survived. The daemon log timestamps exactly
when it happened.

### Chargers: 5V holds, pump fast charging leaks (field evidence 2026-11-05)

The node gates the 5V path only (see the 11-04 audit). Full-session
proof: on 2026-11-05 the phone charged from 12% on a QC brick
(`real_type = USB_HVDCP_3`), the daemon engaged correctly at the 80%
cap (`16:34 cap=80 charging -> bypass ON`), but pump current kept
flowing straight through `input_suspend=1` past three re-asserts
(16:38/16:41/16:44) and the battery climbed to 91% before the hold
caught it. Rule of thumb: overnight or capped charging belongs on a
plain 5V source; save the fast brick for travel days (action-button
override).

Diagnostic tip for reading the log: action-button taps leave no daemon
log lines, only the daemon's own polls log. So a fresh
`cap=NN charging -> bypass ON` well above your cap means the hold was
released mid-session (override tap or manual state change) and
re-engaged - not that the engage logic misfired.

### Watchdog

The daemon beats a `heartbeat` file every poll, plugged or not. A
supervisor loop in `service.sh` checks it every 180s and restarts a
stale daemon (TERM, then KILL after 5s), up to 5 times before giving up
till next boot - every step logged. A dead daemon can no longer silently
disarm the cap; the worst case is a logged restart.

## Safety

The module only votes suspend/resume through the standard QTI PMI
property `input_suspend` - the same node kernel-manager apps drive,
same values. It has no path to voltage or current: float voltage,
charge current, JEITA temperature derating, and OVP/OCP/thermal
shutdown stay enforced by the PMIC hardware and lower driver layers no
matter what the module writes, so overvoltage/overcurrent via this
module is not possible. Every stuck state is safe: node stuck at 1 =
phone runs off the cable (a designed mode); stuck at 0 = ordinary
charging; daemon crash = the node just stays put. Sysfs is written only
on state transitions (60s polls, 2% engage/release gap, bounded boot
hammer), a few transitions a day - no relay-chatter on the FETs.
Measured on the author's phone: battery health Good, 32.7C, no charger
fault events in the kernel log. Every bug found so far produced
overcharge to 100% (a longevity nit), never an unsafe electrical state.
One caveat: after a kernel update, glance at the log once - a kernel
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

**KowSU manager (recommended):**
Modules > Install from storage > pick the release ZIP from the
[releases page](https://github.com/9M2PJU/ChargeBypassCap-PMI/releases). Reboot.

**Manual (adb, root):**
copy this repository's files to `/data/adb/modules/chargebypasscap-pmi/`,
`chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.

Verify: `su -c 'tail /data/adb/chargebypasscap-pmi/cap.log'` should show the
daemon starting, and the module description shows live status.

## Usage

**Set your cap:** tap the module **Open** button. A settings page shows live
status plus a slider (50-100%, default 80): pick when bypass triggers on,
tap Save. Charging resumes 2% below the cap. No reboot needed.

Do nothing day to day: plug in, it caps at your setting.

**Travel-day full charge:** tap the module **action button** once. It
releases bypass and latches override till unplug. Tap it again to resume the
cap (it re-holds within ~60s if at cap+ and charging). The button also prints
battery state, daemon PID, and recent log.

## Requirements

**The short version:** this module works on any ROM and any kernel, as
long as three things hold: root with boot scripts, a KernelSU-family
manager, and a kernel that honors `input_suspend`. ROM brand, Android
version, and kernel name do not matter.

- Root with boot-script support (KowSU tested; Magisk/APatch should work
  since `service.sh` is a plain boot script).
- A kernel that honors `/sys/class/power_supply/battery/input_suspend`
  (RE404 verified; most Snapdragon PMI kernels expose it). Check yours in
  two commands (root shell, plugged in below your cap):
  `ls /sys/class/power_supply/battery/input_suspend`
  then `echo 1 > /sys/class/power_supply/battery/input_suspend` and watch
  the battery current fall to ~0 mA (`... && echo 0 > ...` to release).
  Without a working node the daemon writes into the void: it then sees
  current still flowing after its own write and latches override (fails
  safe, but the cap will not work). Measured limit: the node gates 5V
  charging only - pump fast charging flows straight through it.
- For best results, turn the ROM's own limiters off (MIUI: both Battery
  protection and Smart charging off; HyperOS: Charge fully - see ROM
  Battery protection modes). Two drivers voting on one charger can only
  confuse each other; the module is verified as the sole decider.
- The N0Kontzzz Kernel Manager app is NOT a manual override: the daemon owns
  the node and reverts external writes within 1-2 polls. Release bypass
  only via the action button (it signals through OVERRIDE, which is always
  honored).
- Wired charging only (the wireless path is untested).

## Audit report (2026-10-29, v1.3.1 on POCO X3 Pro)

<details>
<summary>Historical audit - all checks passed, one bug fixed (click to expand)</summary>

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
  the PMI rewrite. (Update 2026-11-04: the line now reads `override via
  action button` - fixed at some point since, nit closed.)

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

</details>

## Audit report (2026-11-04, v1.7 code on POCO X3 Pro)

Full re-audit after the v1.6 reboot-fix port, all paths exercised live.
Verdict: healthy on 5V charging, with one measured limitation (below).
No code changes needed.

- **Files:** all four scripts md5-identical to the release. Same
  `644`-installed fix as onyx: `action.sh`, `service.sh`,
  `uninstall.sh` chmodded to `755` on device (repo already ships
  `755`, so future installs are fine).
- **Daemon:** single instance (PID 3213), RSS 1820 KB (matches
  October's 1776 KB). CPU below tick resolution, same class as onyx.
- **Paths verified live:** adopt + hammer across a reboot with cable
  in (71%, temp cap 65): 8+ min steady hold at ~2 mA, zero false
  overrides. Resume on cap restore (75 <= 78 -> release, -1.6 A fill).
  Action-button release (override latched, daemon hands-off) and
  clear (cap armed, outputs accurate). Node driven 1 -> 0 -> 1
  (manual hold pinned 7 mA).
- **Fast chargers (measured limitation):** on a HVDCP/QC pump charger
  the battery kept charging at -2.5 A (74% to 75%) with
  `input_suspend` firmly at 1. The node gates the 5V path only, so the
  module caps standard 5V charging but cannot hold pump fast charging.
  Re-verified on 5V DCP right after: hold at 3 mA. Use a 5V source
  when the cap matters. Related: a very weak source (100 mA
  negotiated) never reaches the -500000 engage threshold, so the
  daemon correctly stays silent in deadband - file that under
  charger, not module.
- **Manager on this phone:** KowSU (F7 uses KernelSU-Next). WebUI and
  action button behave the same through `ksu.exec`.

## Files

- `service.sh` - started by KowSU/KernelSU on boot; launches the daemon detached plus a watchdog that restarts it if its heartbeat goes stale.
- `bypasscap.sh` - the daemon (self-backgrounds).
- `action.sh` - action button: toggles full-charge override AND prints
  instant status (battery, state, cap mode, daemon PID, recent log).
- `uninstall.sh` - stops the daemon and removes state on module removal.
- `module.prop` - metadata; its description doubles as the live status line.
- `module.yaml` - manifest for the KernelSU Modules listing.

## Logging

- State dir: `/data/adb/chargebypasscap-pmi/` (holding, override, last_status, heartbeat, cap.log)
- Log: `/data/adb/chargebypasscap-pmi/cap.log` - check what it did overnight.

## Credits

Bypass verified on the RE404 kernel (deutereum). Sibling project:
[ChargeBypassCap](https://github.com/9M2PJU/ChargeBypassCap).

## Support

If this module holds your battery where you set it, consider buying me a
coffee - it funds test devices and the kernel experiments behind it.

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

## License

GPL-3.0. See LICENSE.
