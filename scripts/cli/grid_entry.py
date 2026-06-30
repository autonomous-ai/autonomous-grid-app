"""Nuitka entry point for the bundled `grid` CLI sidecar.

grid-app compiles the grid CLI *source* (cloned separately) into a single binary so
the app can ship `grid` without the user installing Python. Nuitka compiles a *script
file*, so this mirrors the CLI's ``cli/__main__.py`` (``python -m cli``): it calls
``cli.main`` and exits with its return code, so the frozen binary dispatches exactly
like the installed console script — including the hidden internal subcommands
(``__server`` / ``__engine`` / ``__cloud-engine``) the CLI re-execs itself with.

This is grid-app's OWN copy (not the CLI repo's ``packaging/grid_entry.py``) so the
build driver stays self-contained — it only depends on the CLI's ``cli`` package being
importable, not on the CLI repo's packaging layout. Keep it tiny and import-light.
"""
from cli import main

if __name__ == "__main__":
    raise SystemExit(main())
