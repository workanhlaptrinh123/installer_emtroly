"""Run bundled helper scripts in either source or frozen builds."""

import sys


def command(script, *args):
    prefix = [sys.executable]
    if getattr(sys, "frozen", False):
        prefix.append("--run-python-script")
    return prefix + [str(script)] + [str(arg) for arg in args]


def restore_library_path(environment):
    if getattr(sys, "frozen", False):
        original = environment.get("LD_LIBRARY_PATH_ORIG")
        if original is None:
            environment.pop("LD_LIBRARY_PATH", None)
        else:
            environment["LD_LIBRARY_PATH"] = original
    return environment
