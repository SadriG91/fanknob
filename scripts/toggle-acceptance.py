#!/usr/bin/env python3
"""UI acceptance test for the Fanknob menu-bar app's Auto/Manual toggle.

Regression test for the "sticky toggle" bug: the SMC reports the old fan mode
for tens of ms after a write, and a naive post-write refresh yanks the toggle
back (Auto -> Manual -> Auto -> Manual flicker). This drives REAL window-server
clicks (CGEvent, identical to a physical mouse) and samples the control state
continuously; the pass criterion is exactly ONE state transition per click.

Requirements:
  - Fanknob.app running (make run-app), fanknobd daemon installed
  - Terminal has Accessibility permission (System Settings -> Privacy)
  - The clicker built:  swiftc -O scripts/click.swift -o /tmp/fanknob-click

Usage:  python3 scripts/toggle-acceptance.py
"""

import shutil
import subprocess
import sys
import time

CLICKER = "/tmp/fanknob-click"
FANKNOB = shutil.which("fanknob") or "./.build/release/fanknob"
PROC = "FanknobApp"
TRIALS = 3
WATCH_SECONDS = 2.2


def ax(script: str) -> str:
    return subprocess.run(
        ["osascript", "-e", script], capture_output=True, text=True
    ).stdout.strip()


def app(cmd: str) -> str:
    return ax(f'tell application "System Events" to tell process "{PROC}" to {cmd}')


def click(x: int, y: int) -> None:
    subprocess.run([CLICKER, str(x), str(y)], capture_output=True)


def segment_center(button: int) -> tuple[int, int]:
    pos = app(f"get position of radio button {button} of radio group 1 of group 1 of window 1")
    size = app(f"get size of radio button {button} of radio group 1 of group 1 of window 1")
    px, py = (int(v) for v in pos.split(", "))
    sw, sh = (int(v) for v in size.split(", "))
    return px + sw // 2, py + sh // 2


def ensure_open() -> None:
    """The popover dismisses itself if it loses key status; reopen it rather
    than recording an empty sample (which used to make this test flaky)."""
    if app("count of windows") == "0":
        app("click menu bar item 1 of menu bar 2")
        time.sleep(1.2)


def manual_selected() -> str:
    ensure_open()
    return app("get value of radio button 2 of radio group 1 of group 1 of window 1")


def trial(target: tuple[int, int], expect: str, name: str) -> bool:
    click(*target)
    t0 = time.time()
    samples = []
    while time.time() - t0 < WATCH_SECONDS:
        value = manual_selected()
        if value:                      # ignore reads taken while reopening
            samples.append((round(time.time() - t0, 2), value))
    if not samples:
        print(f"  {name}: no readable samples -> FAIL")
        return False
    transitions = [
        (t, v) for i, (t, v) in enumerate(samples) if i == 0 or v != samples[i - 1][1]
    ]
    settled = all(v == expect for t, v in samples if t > 1.0)
    ok = len(transitions) == 1 and transitions[0][1] == expect and settled
    print(f"  {name}: transitions={transitions} settled={settled} -> {'PASS' if ok else 'FAIL'}")
    return ok


def main() -> int:
    # Make sure the fans start in auto and the popover is open.
    subprocess.run([FANKNOB, "auto"], capture_output=True)
    time.sleep(1)
    if app("count of windows") == "0":
        app("click menu bar item 1 of menu bar 2")
        time.sleep(1.2)
    if app("count of windows") == "0":
        print("FAIL: could not open the popover")
        return 1

    auto_c, manual_c = segment_center(1), segment_center(2)
    print(f"Auto segment at {auto_c}, Manual at {manual_c}")

    ok = True
    for i in range(1, TRIALS + 1):
        ok &= trial(manual_c, "1", f"trial {i}: -> Manual")
        time.sleep(0.8)
        ok &= trial(auto_c, "0", f"trial {i}: -> Auto")
        time.sleep(0.8)

    # Leave the fans under firmware control.
    subprocess.run([FANKNOB, "auto"], capture_output=True)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
