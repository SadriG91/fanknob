<p align="center">
  <img src="assets/AppIcon-1024.png" width="128" alt="fanknob icon">
</p>

# fanknob — fan control for Apple Silicon Macs

[![CI](https://github.com/SadriG91/fanknob/actions/workflows/ci.yml/badge.svg)](https://github.com/SadriG91/fanknob/actions/workflows/ci.yml)

Control your Mac's fans with a **0–100 knob** (mapped onto each fan's own
min→max RPM range) and monitor CPU/GPU temperatures. Three faces on one engine:

- **`fanknob`** — CLI (`status`, `set`, `preset`, `curve`, `auto`, …)
- **`fanknob tui`** — live interactive terminal dashboard
- **Fanknob.app** — a native SwiftUI **menu-bar app**

It talks to the SMC directly over IOKit — the same mechanism apps like Macs Fan
Control use. Tested on a MacBook Pro 14" (M2 Pro, macOS 26).

<p align="center">
  <img src="assets/screenshots/popover-auto.png" width="300" alt="Popover in automatic mode">
  &nbsp;&nbsp;
  <img src="assets/screenshots/popover-curve.png" width="300" alt="Popover in curve mode with the Balanced preset">
</p>
<p align="center">
  <img src="assets/screenshots/menubar.png" alt="Menu bar: fan icon with live CPU temperature">
  <br>
  <em>Live CPU temperature in the menu bar; the fan turns accent-colored whenever you are overriding the firmware.</em>
</p>

## Layout

```
Package.swift
Sources/
  FanknobCore/   shared engine: SMC access, fan/temp model, daemon client
  fanknob/       CLI + TUI
  fanknobd/      root daemon (privileged writes)
  FanknobApp/    SwiftUI menu-bar app
app/Info.plist   app bundle metadata
com.fanknob.daemon.plist
```

## Install with Homebrew (recommended)

```sh
brew install SadriG91/tap/fanknob

# fan control needs the root helper daemon (one time):
sudo brew services start fanknob

# optional: put the menu-bar app in /Applications
cp -R "$(brew --prefix)/opt/fanknob/Fanknob.app" /Applications/
```

Installs a prebuilt bottle in seconds — **no Xcode required**. If no bottle
matches your system, Homebrew falls back to building from source (which needs
Xcode 16+).

### Updating

```sh
brew update && brew upgrade fanknob
sudo brew services restart fanknob
```

## Build from source

```sh
git clone https://github.com/SadriG91/fanknob.git
cd fanknob
make app             # build everything + assemble Fanknob.app
sudo make install    # install CLI + daemon + app, load the daemon
```

> Use ONE install method — Homebrew or `make install`, not both.

All targets:

```sh
make                 # build everything (release)
make app             # assemble build/Fanknob.app
make run-app         # build + launch the menu-bar app
sudo make install    # install CLI + daemon + app to the system, load the daemon
sudo make uninstall
```

> If you hit an Xcode license error building the app:
> `sudo xcodebuild -license accept`

The one-time `sudo` on install is unavoidable: granting future passwordless root
access requires proving you're root once. After that the root daemon performs
the writes, and the CLI/app stay unprivileged — no `sudo` per command.

## Temperature curves

Instead of pinning a fixed speed, hand the fans to a curve and the daemon
tracks CPU temperature for you — quiet when idle, ramping as it heats:

```sh
fanknob preset quiet          # silent until ~72 °C, full by 94 °C
fanknob preset balanced       # default: responsive without being loud
fanknob preset turbo          # keeps things cold, audibly
fanknob curve 55:0,72:20,85:60,93:100     # or roll your own °C:% points
```

The curve is evaluated every 2 s against a smoothed CPU-cluster average, with
a small deadband so fans don't hunt. Between points the speed is interpolated
linearly; outside the endpoints it's held flat.

### Thermal watchdog

While any override is active, the daemon watches the temperature and hands the
fans back to the firmware if it crosses a limit (default 95 °C):

```sh
fanknob watchdog 90           # stricter
fanknob watchdog off          # you're on your own
```

It's deliberately sticky: once tripped it stays in automatic until you ask for
something new, rather than flapping in and out of an override that isn't
keeping up. `fanknob status` and the app both report a trip.

### Persistence

The active mode and watchdog threshold live in
`/Library/Application Support/fanknob/config.json` and are restored when the
daemon starts, so a curve survives reboots.

## Per-fan control

```sh
fanknob set 60 --fan 1        # just fan 1; the others keep their setpoints
```

In the app, switch the speed row from **Linked** to **Individual** for a
slider per fan.

## The menu-bar app

`make run-app` (or `open -a Fanknob` after install) puts a fan icon + live CPU
temperature in your menu bar. Click it for:

- CPU / GPU temperature gauges and per-fan RPM gauges
- an **Auto / Manual / Curve** mode picker
- a **Fan speed** slider that applies live (or one slider per fan — switch the
  row from *Linked* to *Individual*)
- **Quiet / Balanced / Turbo** curve presets, and in manual mode a **Hold**
  picker (Off / 30s / 1m / 2m / 5m) with a live countdown
- a gear menu with **Open at login** and the watchdog threshold
- a status light (hover it) and a header warning if the watchdog trips

It runs as a menu-bar agent (no Dock icon). Writes go through the daemon, so the
app never needs elevated privileges.

> Toggle **Open at login** from the installed copy (`/Applications/Fanknob.app`)
> — login items register whichever bundle is running.

## CLI

```sh
fanknob status              # fans, temps, and what the daemon is driving
fanknob tui                 # live interactive dashboard
fanknob temp                # every temperature sensor
fanknob set 40              # all fans to 40% of range      (no sudo — via daemon)
fanknob set 60 --for 120    # hold 60% for 120s, then auto-revert
fanknob set 60 --fan 1      # just one fan
fanknob preset balanced     # temperature curve
fanknob curve 55:0,90:100   # custom curve
fanknob watchdog 90         # thermal safety limit
fanknob auto                # back to automatic control
fanknob keys [prefix]       # dump SMC keys (default 'F')
```

Reads need no privileges. `set`/`auto` go through the root daemon if installed,
otherwise run them with `sudo`.

## TUI

`fanknob tui` opens a full-screen dashboard with live gauges and a keyboard knob:

```
 fanknob   Apple M2 Pro
 ──────────────────────────────────────────────
 Fan 0  4790 rpm  █████████████▏░░░░░░░░░░  MANUAL
 Fan 1  4778 rpm  █████████████▏░░░░░░░░░░  MANUAL
 ──────────────────────────────────────────────
 CPU   78°C  ██████████████████▊░░░░░
 GPU   69°C  ████████████████▌░░░░░░░
 ──────────────────────────────────────────────
 KNOB  55%  █████████████▎░░░░░░░░░░  MANUAL
 HOLD off
 MODE curve balanced 45:5,65:25,80:60,90:100 → 56%
 ──────────────────────────────────────────────
 ←/→ ±5  ↑/↓ ±1  0-9 speed  c curve  t hold  a auto  q quit
```

`←/→` ±5, `↑/↓` ±1, `0`–`9` jump to a speed, `c` cycles curves, `t` the hold,
`a` auto, `q` quit.

## Testing

```sh
make test      # unit tests: SMC codecs, knob math, temp clustering, daemon protocol
make ui-test   # UI acceptance: real synthetic clicks on the app's Auto/Manual toggle
```

`ui-test` is a regression test for the "sticky toggle" bug (the SMC reports the
old fan mode for tens of ms after a write; the app must not let a stale poll
yank the toggle back). It drives real CGEvent clicks, so it needs the app
running, the daemon installed, and Accessibility permission for the terminal.

## Important

- A **fixed** speed means you own thermal management, not the firmware. The
  thermal watchdog is the backstop (default 95 °C), but prefer a **curve** if
  you're leaving an override on — it responds to heat, a fixed speed doesn't.
- Return to auto when done: `fanknob auto`, the app's Auto button, or let a
  hold expire.
- MacBook Air is fanless; nothing to control there.

## How it works

Per fan `i`, the SMC exposes `FNum` (count), `FiAc` (actual RPM), `FiMn`/`FiMx`
(min/max), `FiTg` (target RPM, `flt`), `FiMd` (mode: 0 = auto, 1 = manual). To
force a speed: write `1` to `FiMd`, then the target RPM to `FiTg`. To release:
write `0` to `FiMd`.

**Temperature:** Apple Silicon has no single documented "CPU temp" key. fanknob
scans all `T…` sensors of type `flt` in a plausible range and reports the average
of the CPU-core (`Tp*`) and GPU (`Tg*`) clusters.

### The 80-byte struct gotcha

The kernel's `SMCKeyData_t` is exactly 80 bytes. Swift reuses a nested struct's
trailing padding for the next field (C does not), which silently packs the param
struct to 76 bytes and makes every `IOConnectCallStructMethod` fail with
`kIOReturnBadArgument`. `SMCKeyInfoData` is padded to a full 12 bytes to prevent
this — see the comment in `Sources/FanknobCore/SMC.swift`.

### Daemon security

The root daemon accepts only a fixed set of commands over its socket (`set`,
`setfan`, `curve`, `preset`, `watchdog`, `auto`, `state`), each parsed and
range-checked by one pure function before anything reaches the SMC. So even
though any local user can connect, it can't be driven to do anything but move
the fans.

The daemon is also a system-wide singleton (flock on `/var/run/fanknobd.lock`):
if a second instance starts — say a Homebrew-managed daemon next to a
`make install` one — it refuses to run instead of stealing the socket, and its
launchd keep-alive retries mean it takes over automatically if the first one is
ever stopped.

## License

[MIT](LICENSE)
