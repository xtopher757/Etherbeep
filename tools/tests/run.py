#!/usr/bin/env python3
"""Run the Etherbeep Lua test suite outside Project Zomboid.

harness.lua stubs the small slice of the PZ API the mod touches (Events, the
file reader/writer, sound emitters, key bindings) so the mod's own Lua can be
loaded and driven exactly as the game would drive it.

    pip install lupa
    python3 tools/tests/run.py

Exits non-zero if any check fails.
"""

import os
import sys

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(TESTS))
SUITES = ["test_core.lua", "test_modoptions.lua"]


def run(suite):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = ROOT
    lua.globals().TESTS = TESTS
    print("--- %s ---" % suite)
    try:
        with open(os.path.join(TESTS, suite)) as handle:
            lua.execute(handle.read())
    except lupa.LuaError as error:
        print("LUA ERROR in %s: %s" % (suite, error))
        return False
    except SystemExit:
        return False
    print("")
    return True


if __name__ == "__main__":
    sys.exit(0 if all([run(suite) for suite in SUITES]) else 1)
