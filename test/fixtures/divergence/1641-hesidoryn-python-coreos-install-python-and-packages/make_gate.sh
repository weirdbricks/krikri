#!/bin/bash
# The scaffold the case needs before its divergent task: the round's cold
# bootstrap left /opt/bin/python a DANGLING symlink (its ActivePython download
# is a 404, so the interpreter was never installed), and a symlink cannot be
# committed to the corpus (the case runners copy the case with a recursive copy
# that follows links), so the replayed play recreates it in its scratch
# directory instead. Target /opt/python/bin/python: the round's never-installed
# interpreter.
ln -sfn /opt/python/bin/python gate-dangling
