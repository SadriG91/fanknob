#!/usr/bin/env python3
"""UI acceptance test for the per-fan mode badges.

Regression test for badge flicker on mode changes: the SMC reports a fan's
old `managed` flag for tens of ms after a write, and it can't distinguish a
curve from a fixed speed at all. Reading it directly made the badges flash a
bogus intermediate state (CURVE -> MANUAL -> AUTO). The pass criterion is that
each transition shows exactly ONE badge value: the target.

Requirements:
  - Fanknob.app running, fanknobd (>= 1.1.0) running, Accessibility permission

Usage:  python3 scripts/badge-acceptance.py
"""

import subprocess
import sys
import time

PROC = "FanknobApp"
SETTLE_SECONDS = 2.5

# (mode-picker radio button, label, expected badge)
SEQUENCE = [
    (2, "MANUAL", "MANUAL"),
    (3, "CURVE", "CURVE"),
    (1, "AUTO", "AUTO"),
    (3, "CURVE", "CURVE"),
    (2, "MANUAL", "MANUAL"),
    (1, "AUTO", "AUTO"),
]


def ax(script: str) -> str:
    return subprocess.run(
        ["osascript", "-e", f'tell application "System Events" to tell process "{PROC}" to {script}'],
        capture_output=True, text=True,
    ).stdout.strip()


def ensure_open() -> None:
    if ax("count of windows") == "0":
        ax("click menu bar item 1 of menu bar 2")
        time.sleep(1.5)


def badge() -> str | None:
    ensure_open()
    for value in (v.strip() for v in ax("get value of every static text of group 1 of window 1").split(",")):
        if value in ("AUTO", "MANUAL", "CURVE"):
            return value
    return None


def transition(button: int, name: str, expect: str) -> bool:
    ensure_open()
    ax(f"click radio button {button} of radio group 1 of group 1 of window 1")
    seen: list[str] = []
    start = time.time()
    while time.time() - start < SETTLE_SECONDS:
        current = badge()
        if current and (not seen or seen[-1] != current):
            seen.append(current)
    ok = seen == [expect]
    print(f"  -> {name:<6} saw={seen} {'PASS' if ok else 'FLICKER'}")
    return ok


def main() -> int:
    ensure_open()
    if ax("count of windows") == "0":
        print("FAIL: could not open the popover")
        return 1
    # Start from a known state.
    ax("click radio button 1 of radio group 1 of group 1 of window 1")
    time.sleep(3)

    ok = True
    for button, name, expect in SEQUENCE:
        ok &= transition(button, name, expect)
        time.sleep(1.5)

    ax("click radio button 1 of radio group 1 of group 1 of window 1")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
