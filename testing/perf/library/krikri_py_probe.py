#!/usr/bin/python3
# (Shebang is a plain interpreter path, not /usr/bin/env - Ansible
# rewrites python-module shebangs to its discovered interpreter, and
# 2.19's validation rejects env-style shebangs outright.)
# krikri modules-misc2 py_module fixture (referenced as `krikri_py_probe:`
# from modules_misc2.yml, resolved from this playbook-dir library/ by BOTH
# Ansible and krikri-playbook). Probes importability of a module
# that is virtually always present (os, json) and one that is virtually
# never present, exercising both the found and the not-found path - the
# module itself always exits ok (failed is never set), so the probe can
# never fail the run.
from ansible.module_utils.basic import AnsibleModule

import importlib.util

ALWAYS_PRESENT = ["os", "json"]
ALWAYS_ABSENT = ["krikri_modmisc2_no_such_module_9x7"]


def main():
    module = AnsibleModule(argument_spec={}, supports_check_mode=True)
    found = []
    missing = []
    for name in ALWAYS_PRESENT + ALWAYS_ABSENT:
        if importlib.util.find_spec(name) is not None:
            found.append(name)
        else:
            missing.append(name)
    module.exit_json(changed=False, found=found, missing=missing)


if __name__ == "__main__":
    main()
