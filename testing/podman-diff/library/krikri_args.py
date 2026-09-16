from ansible.module_utils.basic import AnsibleModule

module = AnsibleModule(argument_spec={"name": {"type": "str", "required": True}})
module.exit_json(changed=True, msg="hello %s" % module.params["name"])
