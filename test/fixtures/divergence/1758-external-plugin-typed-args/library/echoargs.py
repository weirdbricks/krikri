#!/usr/bin/python3
"""Real-ansible half of the issue #1758 corpus case.

The task YAML is an ordinary `echoargs:` call, so ansible-playbook runs
this module from the playbook-adjacent library/. krikri runs the external
plugin of the same name from plugins/ (KRIKRI_PLUGIN_PATH, see env.txt).
Both must report the arguments with the types the playbook wrote - real
ansible always does; krikri's protocol only does through `args` (issue
#1758), which the plugin reads with a `params` fallback so the unfixed
engine shows the flattened strings instead.
"""

import json

from ansible.module_utils.basic import AnsibleModule

KEYS = (
    "a_bool",
    "a_int",
    "a_float",
    "a_str",
    "a_none",
    "a_dict",
    "a_list_of_str",
    "a_list_of_int",
    "a_list_with_comma",
    "a_dict_text",
)


def main():
    module = AnsibleModule(argument_spec={key: {"type": "raw"} for key in KEYS})
    module.exit_json(changed=False, got={"params": {key: module.params[key] for key in KEYS}})


if __name__ == "__main__":
    main()
