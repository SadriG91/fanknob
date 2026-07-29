# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`fanknob` — fan control for Apple Silicon Macs. One SwiftPM package, no external
dependencies, three executables around a shared core library. Talks to the SMC
directly over IOKit. Apple Silicon + macOS 15 only.

## Commands

```sh
swift build -c release        # or: make
swift test                    # unit tests (Swift Testing: @Suite / @Test)
swift test --filter DaemonProtocolTests          # one suite
swift test --filter DaemonProtocolTests/plainSet # one test

make app                      # assemble build/Fanknob.app (stamps the version in)
make run-app                  # build + launch the menu-bar app
make pkg                      # unsigned installer .pkg for local testing
make print-version            # the version, for scripts
sudo make install             # copy artifacts to the system + load the daemon
sudo make uninstall
make test-preinstall          # package/source-install guard fixtures
make test-postinstall         # helper readiness + console-user relaunch fixtures
make ui-test                  # UI acceptance tests (see below)
```

`make install` deliberately never builds — building as root would leave
root-owned files in `.build/`. Run `make app` as your normal user first. It also
refuses to run if the `.pkg`/Homebrew cask is installed, and vice versa; pick one
install method.

Per this user's setup: `sudo` commands run in the user's own terminal, not from
an agent shell.

### `make ui-test`

Two Python acceptance tests (`scripts/toggle-acceptance.py`,
`scripts/badge-acceptance.py`) that drive the real app through the Accessibility
API and synthetic CGEvent clicks. They need: the app running, `fanknobd`
installed and running, and Accessibility permission for the terminal. Not run in
CI. They are regression tests for SMC write-lag flicker — see "SMC staleness"
below. Verify UI behaviour empirically with these rather than by reasoning about
the SwiftUI code.

### Debugging

- `FANKNOB_DEBUG=1` when launching the app → timestamped event log at
  `/tmp/fanknob-ui.log` (`UILog` in `FanModel.swift`).
- `fanknob bench` — hidden command timing the SMC read paths the app's poller uses.
- Daemon log: `/var/log/fanknobd.log`.

## Architecture

```
FanknobCore/   SMC.swift        IOKit/SMC engine: fourCC, codecs, fan + temp reads/writes
               Curve.swift      FanCurve (°C→knob%) + built-in presets
               Config.swift     persisted DaemonConfig, DaemonState wire format
               Daemon.swift     client side: socket, singleton lock, parseDaemonCommand
               DaemonEngine.swift  injected safety/state machine used by fanknobd
               FanController.swift  facade used by the app/CLI (daemon-or-direct writes)
               Version.swift    the version constant
fanknob/       CLI.swift, TUI.swift          unprivileged client
fanknobd/      Main.swift                    root daemon: socket server, curve/watchdog loop
FanknobApp/    FanknobApp.swift, FanModel.swift, PopoverView.swift   SwiftUI menu-bar app
```

**Privilege split.** Reads need nothing; writes need root. Rather than `sudo` per
command, a root daemon under launchd owns all writes and exposes a Unix socket
(`/var/run/fanknobd.sock`, mode 0666) that any local user can connect to. What
keeps that safe is that `parseDaemonCommand` (`Daemon.swift`) is a pure function
that validates and clamps *every* command before anything reaches the SMC — the
daemon accepts nothing else. Mode 0666 is an explicit trust decision, not
per-user authorization: fan control is system-wide, and any local account can
change and persist its settings. Keep the shared-Mac warning in the README and
landing page aligned with this behavior.

**Adding a command means touching four places:**
the `DaemonCommand` enum + parser, `DaemonEngine.handle`,
the `FanController` facade, and the CLI/app callers. Keep validation in the
parser so it stays unit-testable without hardware.

Protocol v2 uses bounded newline framing and structured `DaemonReply` JSON.
Keep the legacy request/reply path working for an already-running app during a
package upgrade. Socket clients may run concurrently, but all `DaemonEngine`
and SMC access must stay serialized on `smcQueue`.

**Why the daemon owns more than one-shot writes.** Curves are re-evaluated every
2 s against a smoothed CPU-cluster temperature, the thermal watchdog needs a
long-running process, and the active mode is persisted to
`/Library/Application Support/fanknob/config.json` and re-applied on boot. So
curves/watchdog are daemon-only: `FanController.setPreset`/`setCurve`/
`setWatchdog` have no root fallback, and the CLI passes `fallback: nil` for them.
`auto()` prefers the daemon even when root, because a direct SMC write wouldn't
stop a curve the daemon is still driving.

**Daemon lifecycle invariants.** `DaemonEngine` receives `FanHardware`, a clock,
config path and logger so safety behavior remains testable without an SMC.
Curves use a smoothed CPU average; watchdog decisions use the hottest CPU/GPU
die probe (`Tp*`/`Tg*`) from the same sample — not every `T*` key, because
some SMC "T" keys aren't die thermals and sit above the default limit
chronically (e.g. `Tf06` ≈ 104 °C near idle), which would cancel every
override — and are
debounced to two consecutive over-limit samples so one probe spike can't
cancel the user's mode. Three missing samples, partial
writes, expired persisted holds, or failed restoration all return to Auto —
always via `transitionToAutomatic`, never an inline revert: only the
transition path arms the automatic-retry flag and surfaces a `safetyReason`
when the hand-back write itself fails. `DaemonConfig.load` salvages
field-wise, so one field an older build persisted under looser rules can't
silently reset the others (notably the watchdog).

The SMC holds `FiMd = 1` until something writes
0 back, so a daemon that just exits strands the fans at their last target.
`DaemonEngine.shutdown()` hands them back on SIGTERM/SIGINT — which is why both
signals are `SIG_IGN`'d before the dispatch sources are installed (a dispatch
signal source only observes; the default disposition would kill the process
first). A flock on `/var/run/fanknobd.lock` makes the daemon a system-wide
singleton so two installs can't fight over the socket.

## Things that will bite you

**The 80-byte SMC struct.** `SMCParamStruct` must be exactly 80 bytes to match
the kernel's `SMCKeyData_t`. Swift reuses a nested struct's trailing padding for
the next field where C does not, which silently packs it to 76 and makes every
`IOConnectCallStructMethod` fail with `kIOReturnBadArgument`. `SMCKeyInfoData`
carries explicit `pad0/1/2` fields for this. Don't "clean up" those fields, and
re-check the size if you add anything to the struct.

**SMC staleness.** After a mode write, the SMC keeps reporting the *old*
`FiMd`/`managed` value for tens of milliseconds, and it cannot distinguish a
curve from a fixed speed (both are just "managed"). Both facts shape the app:

- The mode of record is the **daemon's** `state` reply whenever it's reachable;
  the SMC is only the fallback (`FanModel.observedMode`).
- `FanModel` runs a *mode intent guard* (`pendingMode` / `pendingModeUntil`, 1.5 s)
  plus a `writesInFlight` counter; polls that were snapshotted before a user
  action must not publish after it and yank the UI back. The guard clears only
  when both the daemon *and* the per-fan flags agree.
- Per-fan badges come from `FanModel.badge(for:)` (app mode), never from
  `Fan.managed` directly.
- The daemon reads resolved RPM from the write itself, never by reading `FiTg`
  back.

These are exactly the bugs `make ui-test` regression-tests.

**FanModel threading.** `FanModel` is `@MainActor`. All `FanController`/SMC
access is confined to one serial
`workQueue` — the controller is even constructed there, since sensor discovery
takes ~0.4 s. All published state is main-queue only. Polls coalesce (never more
than one in flight, never dropped). `publish()` assigns only when a value
actually changed, because `@Observable` notifies on every set and spurious sets
re-render controls mid-click. `PopoverView` is split into small child views for
the same reason.

**Version.** `Sources/FanknobCore/Version.swift` is the single source of truth.
The Makefile `sed`s it out, `make app` stamps `CFBundleShortVersionString` into
the bundle (so the value checked into `app/Info.plist` is stale and ignored), and
the release workflow refuses a `vX.Y.Z` tag that disagrees with it.
`CFBundleVersion` is the git commit count — it must increase monotonically, and
macOS compares `13` as newer than `1.4.0`.

**Package.swift uses `swiftLanguageModes: [.v6]`.** Keep shared value types
`Sendable`, UI state main-actor isolated, and mutable SMC/daemon state confined
to its documented serial queue when extending the project.

## Release + packaging

Bump `Version.swift`, commit, push a matching `vX.Y.Z` tag. `.github/workflows/
release.yml` builds, signs (Developer ID), notarizes, publishes the `.pkg`, and
bumps the Homebrew cask in `SadriG91/homebrew-tap`. CI (`ci.yml`) builds and
tests on both `macos-15` (deployment floor) and `macos-26` (release SDK).

Three packaging details are load-bearing and easy to undo:

- `packaging/component.plist` sets `BundleIsRelocatable=false`. Without it,
  pkgbuild marks the `.app` relocatable and Installer asks LaunchServices where
  `com.fanknob.app` already lives — installing over a stray copy and leaving
  `/Applications` empty. CI greps `PackageInfo` for `relocatable="false"`.
- `packaging/scripts/preinstall` refuses to put the package over a source-built
  copy with no receipt; the Makefile guards the opposite direction. Keep
  `make test-preinstall` covering clean installs, conflicts and upgrades.
- `packaging/scripts/postinstall` is why this ships as a `.pkg` at all: Installer
  is already root, so it loads the daemon and waits for the socket to appear.
  Its app restart is scoped to the console UID (`pkill -U "$uid"`); keep
  `make test-postinstall` covering root, console-user, and no-console sessions.

Signing note: `codesign` failing with "unable to build chain to self-signed root"
(and `find-identity` showing 0 valid identities) means the Developer ID G2
intermediate is missing from the keychain, not that the key is bad — the release
workflow imports it explicitly from Apple.
