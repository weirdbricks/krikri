#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
module: docker
short_description: stub module so the deprecated name resolves for linting
description: stub
author: fixture
options:
  name:
    description: name
    type: str
  image:
    description: image
    type: str
  state:
    description: state
    type: str
"""


def main():
    module = AnsibleModule(
        argument_spec={
            "name": {"type": "str"},
            "image": {"type": "str"},
            "state": {"type": "str"},
        },
        supports_check_mode=True,
    )
    module.exit_json(changed=False)


if __name__ == "__main__":
    main()
