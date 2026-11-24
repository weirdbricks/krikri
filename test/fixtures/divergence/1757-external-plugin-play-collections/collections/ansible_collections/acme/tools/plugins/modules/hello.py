#!/usr/bin/python3
from ansible.module_utils.basic import AnsibleModule

module = AnsibleModule(argument_spec={}, supports_check_mode=True)
module.exit_json(changed=False, msg="hello")
