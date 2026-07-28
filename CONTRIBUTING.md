# Contributing to fanknob

Bug reports, fixes and ideas are welcome. This file covers building, testing,
releasing, and the parts of the implementation that are surprising enough to be
worth writing down.

For what fanknob does and how to use it, see the [README](README.md).

## Layout

One SwiftPM package, no external dependencies. Three executables around a shared
core library:

```
Package.swift
Sources/
  FanknobCore/   shared engine: SMC access, fan/temp model, curves, daemon client
  fanknob/       the CLI and the TUI
  fanknobd/      the root daemon that performs privileged writes
  FanknobApp/    the SwiftUI menu-bar app
Tests/           unit tests for the pure logic in FanknobCore
app/Info.plist   app bundle metadata
packaging/       installer package definition + postinstall script
scripts/         icon generation and the UI acceptance harness
com.fanknob.daemon.plist
```

Building the SwiftUI app needs the macOS SDK from Xcode or the Command Line
Tools. If you hit an Xcode license error: `sudo xcodebuild -license accept`.

## Build from source

```sh
git clone https://github.com/SadriG91/fanknob.git
cd fanknob
make app             # build everything + assemble build/Fanknob.app
sudo make install    # install CLI + daemon + app, and load the daemon
```

> Use ONE install method — the package (or the Homebrew cask) or `make install`,
> not both. Each target refuses to run when the other is already in place, because
> two daemons would fight over the same socket and the stale package receipt would
> claim files the other target owns.

All targets:

```sh
make                 # build everything (release)
make app             # assemble build/Fanknob.app
make run-app         # build + launch the menu-bar app
make pkg             # unsigned installer .pkg, for local testing
make pkg-signed      # Developer ID signed .pkg (needs certs; CI does this)
make notarize        # notarize + staple the signed .pkg
make print-version   # the version, for scripts
make clean
sudo make install    # install CLI + daemon + app, load the daemon
sudo make uninstall
```

`make install` deliberately only *copies* — it never builds. Building as root
would leave root-owned files in `.build/` and `build/` that break your later
builds as a normal user. Run `make app` first as yourself.

The one-time `sudo` on install is unavoidable: granting future passwordless root
access requires proving you're root once. After that the daemon performs the
writes and the CLI and app stay unprivileged.

For local notarization, store credentials once:

```sh
xcrun notarytool store-credentials fanknob-notary \
      --key <p8> --key-id <id> --issuer <uuid>
```

CI passes `--key`/`--key-id`/`--issuer` directly instead.

## Testing

```sh
make test    # or: swift test
```

Unit tests cover the pure logic in `FanknobCore` — SMC codecs, knob math,
temperature clustering, curve evaluation, config round-trips and the daemon
protocol parser. They need no hardware, no root and no daemon, so they run in CI
on every push.

They use [Swift Testing](https://developer.apple.com/documentation/testing)
(`@Suite` / `@Test`), so a single suite or test is:

```sh
swift test --filter DaemonProtocolTests
swift test --filter DaemonProtocolTests/plainSet
```

### UI acceptance tests

```sh
make ui-test
```

Two Python harnesses (`scripts/toggle-acceptance.py`, `scripts/badge-acceptance.py`)
that drive the real app through the Accessibility API and post real CGEvent
clicks — indistinguishable from a physical mouse. They need:

- Fanknob.app running (`make run-app`)
- the `fanknobd` daemon installed and running
- Accessibility permission for your terminal (System Settings → Privacy & Security)

They can't run in CI (no live SMC, no Accessibility grant), so they're a
dev-machine gate. They exist because the toggle and the per-fan badges are the
two things that broke in ways unit tests can't see — see *SMC write lag* below.
If you change anything in `FanModel` or the popover's control block, run them.

## Releasing

The version lives in exactly one place, `Sources/FanknobCore/Version.swift`.
Bump it, commit, then push a matching `vX.Y.Z` tag:

```sh
git tag v1.4.2 && git push origin v1.4.2
```

The release workflow refuses to build a tag that disagrees with `Version.swift`.
From there it's automatic: build, sign with Developer ID, notarize, staple,
publish the `.pkg` and its checksum to the release, then repoint the Homebrew
cask in `SadriG91/homebrew-tap`.

`CFBundleVersion` is the commit count rather than the marketing version, because
it has to increase monotonically and macOS reads `13` as newer than `1.4.0`. The
`CFBundleShortVersionString` checked into `app/Info.plist` is a placeholder —
`make app` stamps the real one in.

CI builds and tests on both `macos-15` (the deployment floor) and `macos-26` (the
SDK releases are built with; an app linked against an older SDK gets the legacy
compatibility appearance).

## How it works

### Fans

Per fan `i`, the SMC exposes `FNum` (count), `FiAc` (actual RPM), `FiMn`/`FiMx`
(min/max), `FiTg` (target RPM, `flt`), and `FiMd` (mode: 0 = auto, 1 = manual).
To force a speed: write `1` to `FiMd`, then the target RPM to `FiTg`. To release:
write `0` to `FiMd`. The 0–100 knob is just a position in the `FiMn`→`FiMx` range.

### Temperature

Apple Silicon has no single documented "CPU temp" key. fanknob scans all `T…`
sensors of type `flt` in a plausible range and averages the CPU-core (`Tp*`) and
GPU (`Tg*`) clusters. On an M2 Pro that's ~54 CPU probes. The keys are
enumerated once and re-read directly afterwards, so a live view doesn't rescan
all ~1500 SMC keys per frame.

### The 80-byte struct gotcha

The kernel's `SMCKeyData_t` is exactly 80 bytes. Swift reuses a nested struct's
trailing padding for the next field (C does not), which silently packs the param
struct to 76 bytes and makes every `IOConnectCallStructMethod` fail with
`kIOReturnBadArgument`. `SMCKeyInfoData` is padded to a full 12 bytes to prevent
this — see the comment in `Sources/FanknobCore/SMC.swift`. Don't tidy those
padding fields away, and re-check the size if you add a field.

### SMC write lag

After a mode write the SMC keeps reporting the **old** `FiMd` for tens of
milliseconds, and it can't distinguish a curve from a fixed speed — both are just
"managed". Two consequences, both load-bearing in the app:

- The mode of record is the **daemon's** reported state whenever it's reachable;
  the SMC is only the fallback. Only the daemon knows a curve is driving.
- `FanModel` runs a mode intent guard plus an in-flight write counter, so a poll
  taken *before* a user action can't publish *after* it and yank the UI back.
  Per-fan badges come from the app's mode, never from `Fan.managed` directly.

This is what `make ui-test` regression-tests: the "sticky toggle" bug and badge
flicker on mode changes.

### Daemon security

The root daemon accepts only a fixed set of commands over its socket (`set`,
`setfan`, `curve`, `preset`, `watchdog`, `auto`, `state`), each parsed and
range-checked by one pure function — `parseDaemonCommand` in `Daemon.swift` —
before anything reaches the SMC. So even though any local user can connect, it
can't be driven to do anything but move the fans. **Adding a command means
touching four places:** the `DaemonCommand` enum and its parser, `Controller.handle`
in `Sources/fanknobd/Main.swift`, the `FanController` facade, and the callers.
Keep the validation in the parser so it stays testable without hardware.

The daemon is also a system-wide singleton (flock on `/var/run/fanknobd.lock`):
if a second instance starts — say a Homebrew-managed daemon next to a
`make install` one — it refuses to run instead of stealing the socket, and its
launchd keep-alive retries mean it takes over automatically if the first one is
ever stopped.

It hands the fans back to the firmware on SIGTERM/SIGINT. That matters: the SMC
holds `FiMd = 1` until something writes 0 back, so a daemon that simply exited
would leave the fans pinned with nothing running to move them.

## Packaging

Two details in `packaging/` are load-bearing and easy to undo by accident:

- **`component.plist` sets `BundleIsRelocatable=false`.** pkgbuild treats `.app`
  bundles as relocatable by default, which makes Installer ask LaunchServices
  where `com.fanknob.app` already lives and install *there* — so on any machine
  that has ever opened a copy from `~/Downloads` or a build directory, the
  upgrade lands in that location and `/Applications` is left empty. This shipped
  in 1.4.0. CI now greps the built package for `relocatable="false"`.
- **`scripts/postinstall` is why this ships as a `.pkg` at all.** Installer is
  already root, so it loads the daemon itself and waits for the socket to appear
  before declaring success — fan control works the moment the install finishes,
  with no "now open a terminal and run this".

Signing note: if `codesign` fails with *"unable to build chain to self-signed
root"* and `security find-identity` shows 0 valid identities, the Developer ID G2
intermediate is missing from the keychain — the key itself is fine. The release
workflow imports it explicitly from Apple.

## Working with Claude Code

[CLAUDE.md](CLAUDE.md) holds the same ground rules in the form Claude Code reads
at the start of a session. If you change something structural — the daemon
protocol, the threading model, the release flow — update both.
