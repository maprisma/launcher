#!/usr/bin/env python3
"""The reference's answer for the Dart core's tests: run with -I and the
fixture's environment. Usage: oracle.py scan"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "reference" / "gnome-launcher"
sys.path.insert(0, str(ROOT))
sys.dont_write_bytecode = True


def main(argv):
    if argv[1:] == ["scan"]:
        import launcher_core
        print(json.dumps(launcher_core.parse_desktop_files()))
        return 0
    print(__doc__.strip().splitlines()[-1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
