#!/usr/bin/env python3
"""Rebuild and reopen only the standalone UI preview when project sources change."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def snapshot():
    paths = [ROOT / "build.zig"]
    paths.extend(p for p in (ROOT / "src").rglob("*") if p.suffix in {".zig", ".m", ".h"})
    result = []
    for path in sorted(paths):
        try:
            stat = path.stat()
            result.append((str(path), stat.st_mtime_ns, stat.st_size))
        except FileNotFoundError:
            pass
    return tuple(result)


def stop(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def launch():
    print("Building UI preview… Save a source file to rebuild. Ctrl-C stops.", flush=True)
    return subprocess.Popen(["zig", "build", "preview"], cwd=ROOT, start_new_session=True)


def main():
    if sys.platform != "darwin":
        sys.exit("The native UI preview currently supports macOS.")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    previous = snapshot()
    process = launch()
    try:
        while True:
            time.sleep(0.25)
            current = snapshot()
            if current != previous:
                time.sleep(0.15)  # Let an editor finish saving related files.
                previous = snapshot()
                stop(process)
                process = launch()
    except KeyboardInterrupt:
        pass
    finally:
        stop(process)


if __name__ == "__main__":
    main()
