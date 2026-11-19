# Amtega gitlab_projects_fact role

This is an [Ansible](http://www.ansible.com) role get facts about GitLab projects.

## Role Variables

A list of all the default variables for this role is available in `defaults/main.yml`.

The role setups the following facts:

- `gitlab_projects_fact`: list of dicts with gitlab project facts

## Example Playbook

This is an example playbook:

``` yaml
---
- name: Get GitLab projects fact
  hosts: localhost
  roles:  
    - amtega.gitlab_projects_fact
  vars:    
    gitlab_projects_fact_server: https://gitlab.acme.com
    gitlab_projects_fact_api_version: 4
    gitlab_projects_fact_token: mytoken
    gitlab_projects_fact_owned: yes
    gitlab_projects_fact_validate_certs: yes
```

## Testing

Tests are based on [molecule with docker containers](https://molecule.readthedocs.io/en/latest/installation.html).

To run test you need provide the variables defined in `defaults/main.yml` and also the variables required by `amtega.gitlab_fork` role. One way to provide this information is calling the testing playbook passing an additional inventory using the following environment variables:

- `ANSIBLE_INVENTORY`: path to an inventory
- `ANSIBLE_VAULT_PASSWORD_FILE`: path to the file containing the vault password required for the previous inventory

```shell
cd amtega.gitlab_projects_fact

ANSIBLE_INVENTORY=~/myinventory ANSIBLE_VAULT_PASSWORD_FILE=~/myvaultpassword molecule test --all
```

## License

Copyright (C) 2022 AMTEGA - Xunta de Galicia

This role is free software: you can redistribute it and/or modify it under the terms of:

GNU General Public License version 3, or (at your option) any later version; or the European Union Public License, either Version 1.2 or – as soon they will be approved by the European Commission ­subsequent versions of the EUPL.

This role is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details or European Union Public License for more details.

## Author Information

- Juan Antonio Valiño García.
