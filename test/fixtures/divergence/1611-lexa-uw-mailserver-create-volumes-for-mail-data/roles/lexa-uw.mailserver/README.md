Role Name
=========

Role to run tvial/docker-mailserver in docker container.

Requirements
------------

Only for run with docker.

Role Variables
--------------

See [variables](defaults/main.yml).

Add role to project:
----------------
Add role into your requirements(_requirements.yml_ for example):
```yaml
- src: https://github.com/lexa-uw/ansible-role-mailserver
  version: v1.3.0
  name: mailserver
```

Install role: `ansible-galaxy install -r ./requirements.yml --roles-path ./roles/`

    
Playbook example:
----------------

```yaml
- hosts: all
  vars:
    mailserver_docker_env:
      OVERRIDE_HOSTNAME: "override.hostname"
    mailserver_users:
    - {user: "test@qwest", password: "qwest"}
  roles:
    - { role: mailserver }
```


License
-------

MIT
