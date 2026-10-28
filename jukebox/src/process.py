#!/usr/bin/env python3
"""Tie an owned Linux child to its launching shell, then replace this process."""

import ctypes
import os
import signal
import sys


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("process.py requires a command")
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    # Linux PR_SET_PDEATHSIG: an OOM-killed/closed shell must not leave music
    # playing indefinitely. The second check closes the parent-exit race.
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot set parent-death signal")
    if parent == 1 or os.getppid() != parent:
        raise SystemExit(1)
    os.execvp(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
