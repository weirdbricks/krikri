KRIKRI_LINT_VERSION = "0.6.0"

# The exact ansible-lint release every rule here was verified against,
# live, via testing/lint/parity.py. Debian ships it as
# 25.6.1+really25.2.1 (25.2.1 code with a 25.6.1 version stamp); pin
# 25.2.1 when installing from PyPI for parity runs.
PARITY_TARGET_ANSIBLE_LINT = "25.6.1+really25.2.1 (upstream 25.2.1)"
