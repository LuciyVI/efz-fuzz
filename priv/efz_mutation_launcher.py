"""Fixed lifecycle bootstrap for OTP's erl_child_setup parent relationship.

The existing C owner receives its actual parent PID. C owns VM group killing
and descendant reaping; this process only forwards the stop byte/EOF and waits
for C. C stdout is inherited directly, so the port sees its reaping evidence.
"""

import os
import selectors
import signal
import subprocess
import sys


def main():
    child = subprocess.Popen(
        [sys.argv[1], str(os.getpid())] + sys.argv[2:],
        stdin=subprocess.PIPE,
        stdout=sys.stdout.buffer,
        stderr=sys.stdout.buffer,
    )
    selector = selectors.DefaultSelector()
    selector.register(0, selectors.EVENT_READ)
    stopped = False

    def stop(*_args):
        nonlocal stopped
        if not stopped:
            stopped = True
            try:
                child.stdin.write(b"\0")
                child.stdin.flush()
                child.stdin.close()
            except (BrokenPipeError, OSError):
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        while child.poll() is None:
            for _key, _events in selector.select(0.01):
                os.read(0, 1)
                selector.unregister(0)
                stop()
        return child.wait()
    finally:
        stop()
        selector.close()


if __name__ == "__main__":
    sys.exit(main())
