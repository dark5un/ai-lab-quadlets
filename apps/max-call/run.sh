#!/usr/bin/env bash
# max-call env wrapper — venv + browsers + rootless libs all live OUTSIDE the repo.
E=/home/px/.hermes/cache/scratch
export PLAYWRIGHT_BROWSERS_PATH=$E/pw-browsers
export LD_LIBRARY_PATH=$E/pwlibs/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
exec $E/max-call-venv/bin/python "$@"
