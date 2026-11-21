#!/usr/bin/python
# The issue's own class of deprecation: ansible-core 2.21 serves
# ansible.module_utils._text as a shim whose module-level __getattr__
# deprecates each name imported from it (the exact line #1660 quotes for
# amazon.aws.ec2_metadata_facts). A task that imports one must print
# nothing at all while DEPRECATION_WARNINGS is false, and both engines run
# this payload the same way.
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils._text import to_native, to_text


def main():
    module = AnsibleModule(argument_spec=dict(), supports_check_mode=True)
    module.exit_json(changed=False, msg=to_text(to_native("probe")))


if __name__ == '__main__':
    main()
