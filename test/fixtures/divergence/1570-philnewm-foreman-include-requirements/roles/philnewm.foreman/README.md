# Ansible Foreman

[![AlmaLinux9-CI](https://github.com/philnewm/ansible-foreman/actions/workflows/almalinux9-ci-caller.yml/badge.svg)](https://github.com/philnewm/ansible-foreman/actions/workflows/alma9-ci-caller.yml)
[![Rocky9-CI](https://github.com/philnewm/ansible-foreman/actions/workflows/rocky9-ci-caller.yml/badge.svg)](https://github.com/philnewm/ansible-foreman/actions/workflows/rocky9-ci-caller.yml)
[![CentOSStream9-CI](https://github.com/philnewm/ansible-foreman/actions/workflows/centosstream9-ci-caller.yml/badge.svg)](https://github.com/philnewm/ansible-foreman/actions/workflows/centosstream9-ci-caller.yml)

Role description

This role includes a molecule testing setup as a submodule at `molecule/`

## Structure

```code
📦 ansible-foreman
 ┣ 📂 defaults
 ┃ ┗ 📜 main.yml
 ┣ 📂 files
 ┃ ┣ 📜 custom_playbook.yml
 ┃ ┣ 📜 default_users.yml
 ┃ ┣ 📜 pxegrub2_custom_local_boot
 ┃ ┗ 📜 requirements.yml
 ┣ 📂 handlers
 ┃ ┗ 📜 main.yml
 ┣ 📂 meta
 ┃ ┗ 📜 main.yml
 ┣ 📂 molecule
 ┃ ┗ 📂 default
 ┃   ┗ 📜, 📜, 📜, scenario_files
 ┣ 📂 tasks
 ┃ ┣ 📜 absent.yml
 ┃ ┣ 📜 ansible.yml
 ┃ ┣ 📜 config.yml
 ┃ ┣ 📜 debian_dependencies.yml
 ┃ ┣ 📜 install.yml
 ┃ ┣ 📜 main.yml
 ┃ ┣ 📜 present.yml
 ┃ ┣ 📜 requirements.yml
 ┃ ┗ 📜 tests.yml
 ┣ 📂 vars
 ┃ ┗ 📜 main.yml
 ┗ 🗒️ README.md
 ┗ 📜 requirements.yml

```

Describe and explain role structure.

## Requirements

Elaborate external dependencies and how to use them.

## Role Variables

* defaults/main.yml
  * first_var
  * sec_var
  * third_var
* vars/main.yml
  * first_var
  * sec_var
  * third_var

## Dependencies

* [`theforeman.foreman`](https://galaxy.ansible.com/ui/repo/published/theforeman/foreman/)
* [`theforeman.operations`](https://galaxy.ansible.com/ui/repo/published/theforeman/operations/)

## Example Playbook

Add an example playbook

```yaml
---

- name: Install and configure Foreman
  hosts: foreman
  vars_files:
    - foreman_custom_vars.yml
  roles:
    - philnewm.foreman

...
```

## License

MIT

## Notes

Includes special git configuration for submodule files that are most likely to get local overrides
`.git/info/attributes`

```code
molecule/default/cleanup.yml merge=ours
molecule/default/converge.yml merge=ours
molecule/default/verify.yml merge=ours
```

## Changes to role template

* Add GitHub action that flags empty directories on release creation
