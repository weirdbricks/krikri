# markosamuli.nvm

[![Ansible Quality Score](https://img.shields.io/ansible/quality/38353.svg)](https://galaxy.ansible.com/markosamuli/nvm)
[![Ansible Role](https://img.shields.io/ansible/role/38353.svg)](https://galaxy.ansible.com/markosamuli/nvm)
[![GitHub release](https://img.shields.io/github/release/markosamuli/ansible-nvm.svg)](https://github.com/markosamuli/ansible-nvm/releases)
[![License](https://img.shields.io/github/license/markosamuli/ansible-nvm.svg)](https://github.com/markosamuli/ansible-nvm/blob/master/LICENSE)

| Branch  | Status |
|---------|--------|
| master  | [![Build Status](https://travis-ci.org/markosamuli/ansible-nvm.svg?branch=master)](https://travis-ci.org/markosamuli/ansible-nvm)
| develop | [![Build Status](https://travis-ci.org/markosamuli/ansible-nvm.svg?branch=develop)](https://travis-ci.org/markosamuli/ansible-nvm)

Ansible role to install [Node.js] with [NVM] on macOS or Ubuntu Developer
machines.

The role doesn't use [Homebrew] for installing nvm on macOS as
it's not a support method in the upstream repository.

Git and cURL are installed if missing on the target system.

[Homebrew]: https://brew.sh
[Node.js]: https://nodejs.org/en/
[NVM]: https://github.com/creationix/nvm

## Role Variables

```yaml
# We're installing stable Node.js version by default
nvm_default_node_version: stable
nvm_node_versions:
  - "{{ nvm_default_node_version }}"

# Initialize shell profile scripts
nvm_init_shell: yes

# Define the shell profile scripts to initialiaze
nvm_shell_profile_scripts:
  - .bashrc
  - .zshrc
```

## Example Playbook

```yaml
- hosts: localhost
  connection: local
  roles:
      - { role: markosamuli.nvm }
```

## Linux distribution support

I've used this for installing NVM and Node.js on [Pengwin] distribution
on WSL.

The configuration variables for bash and zsh profiles are missing for
untested distributions.

[Pengwin]: https://github.com/WhitewaterFoundry/Pengwin

## Changes

* [CHANGELOG.md](CHANGELOG.md)

## License

* [MIT](LICENSE)

## Author Information

* [@markosamuli](https://github.com/markosamuli)
