# fanknob — knob-style fan control for Apple Silicon Macs

A small CLI that controls your Mac's fans through a **0–100 knob** instead of raw
RPM, and reports temperatures. It talks to the SMC (System Management Controller)
directly over IOKit — the same mechanism apps like Macs Fan Control use.

`0` = each fan's reported minimum, `100` = its maximum. The knob maps onto each
fan's own min→max range, so you never type an RPM.

Tested on a MacBook Pro 14" (M2 Pro, macOS 26).

## Layout

| File                       | What it is                                        |
|----------------------------|---------------------------------------------------|
| `SMC.swift`                | Shared SMC engine: read/write keys, fans, temps   |
| `fanknob.swift`            | Client CLI (reads directly; sends writes to daemon)|
| `fanknobd.swift`           | Root daemon that performs the privileged writes   |
| `com.fanknob.daemon.plist` | LaunchDaemon that runs the daemon at boot         |
| `Makefile`                 | build / install / uninstall                       |

## Build

```sh
make            # builds ./fanknob and ./fanknobd
```

## Run from anywhere, without sudo

```sh
sudo make install
```

This installs both binaries to `/usr/local/bin` (on your `PATH`) and loads the
daemon via `launchctl`. After that, from any directory:

```sh
fanknob status          # fans + CPU/GPU temperature   (no sudo)
fanknob temp            # every temperature sensor      (no sudo)
fanknob set 40          # all fans to 40% of range      (no sudo — via daemon)
fanknob set 60 --for 120  # hold 60% for 120s, then auto-revert (safety)
fanknob auto            # back to automatic control      (no sudo — via daemon)
fanknob keys [prefix]   # dump SMC keys (default 'F')
```

### Safety auto-revert

`fanknob set 60 --for 120` holds 60% for 120 seconds, then returns the fans to
automatic control. The timer lives in the **root daemon**, not the client, so the
revert still fires even if you close the terminal or the client exits — you can't
accidentally leave the fans pinned. Any later `set`/`auto` cancels a pending
revert. (Without the daemon, i.e. `sudo fanknob set 60 --for 120`, the client
holds the duration in the foreground and reverts on exit — so keep it running.)

The one-time `sudo` on install is unavoidable — granting future passwordless
root access requires proving you're root once. After that the daemon (running as
root) does the writes; the `fanknob` client stays unprivileged and just sends it
`set`/`auto` over a Unix socket.

### Without installing

Reads work with no privileges. For writes without the daemon, use sudo:

```sh
./fanknob status
sudo ./fanknob set 40
sudo ./fanknob auto
```

## Uninstall

```sh
sudo make uninstall
```

## Important

- **Run `fanknob auto` when you're done.** In manual mode the firmware is *not*
  managing fans for thermal safety — you are. Don't leave them pinned low under
  load.
- MacBook Air is fanless; nothing to control there.

## How it works

Per fan `i`, the SMC exposes:

| Key    | Type | Meaning                     |
|--------|------|-----------------------------|
| `FNum` | ui8  | number of fans              |
| `FiAc` | flt  | actual RPM                  |
| `FiMn` | flt  | minimum RPM                 |
| `FiMx` | flt  | maximum RPM                 |
| `FiTg` | flt  | target RPM (write to set)   |
| `FiMd` | ui8  | mode: 0 = auto, 1 = manual  |

Force a speed: write `1` to `FiMd`, then the target RPM (little-endian `Float32`)
to `FiTg`. Release: write `0` to `FiMd`.

**Temperature:** Apple Silicon has no single documented "CPU temp" key. fanknob
scans all `T…` sensors of type `flt` in a plausible range (~1–130 °C) and reports
the average of the CPU-core (`Tp*`) and GPU (`Tg*`) clusters. Individual sensors
spike momentarily, so the cluster average is the meaningful number.

### The 80-byte struct gotcha

The kernel's `SMCKeyData_t` is exactly 80 bytes. Swift reuses a nested struct's
trailing padding for the next field (C does not), which silently packs the param
struct to 76 bytes and makes every `IOConnectCallStructMethod` fail with
`kIOReturnBadArgument`. `SMCKeyInfoData` is padded to a full 12 bytes to prevent
this — see the comment in `SMC.swift`.

### Daemon security

The root daemon accepts only two commands (`set <0-100> [seconds]`, `auto`) over
its socket, so even though any local user can connect, it can't be driven to do
anything but move the fans.
