[![Actions Status - Master](https://github.com/juju4/ansible-lxdconfigure/workflows/AnsibleCI/badge.svg)](https://github.com/juju4/ansible-lxdconfigure/actions?query=branch%3Amaster)
[![Actions Status - Devel](https://github.com/juju4/ansible-adduser/workflows/AnsibleCI/badge.svg?branch=devel)](https://github.com/juju4/ansible-adduser/actions?query=branch%3Adevel)

# LXD containers pre-configuration ansible role

Ansible role to pre-copy images and eventually pre-configure some. Supports lxd and incus.

## Requirements & Dependencies

### Ansible
It was tested on the following versions:
 * 2.0
 * 2.2
 * 2.5
 * 2.21

### Operating systems

Tested on Ubuntu 22.04, 24.04.

## Example Playbook

Just include this role in your list.
For example

```
- host: all
  roles:
    - juju4.lxdconfigure
```

## Variables

Nothing specific for now.

## Continuous integration

This role has a travis test calling kitchen with lxd (for github), kitchen local with vagrant+virtualbox and also a Vagrantfile (test/vagrant).

Once you ensured all necessary roles are present, You can test with:
```
$ cd /path/to/roles/juju4.lxdconfigure
## lxd backend
$ kitchen verify
$ kitchen login
## vagrant+virtualbox backend
$ KITCHEN_YAML=".kitchen.vagrant.yml" kitchen verify
```
or
```
$ cd /path/to/roles/juju4.lxdconfigure/test/vagrant
$ vagrant up
$ vagrant ssh
```

## Troubleshooting & Known issues

* virtualization detection issue with ansible < 2.2.0
lxc might appears as kvm for example.
https://github.com/ansible/ansible/issues/17030
https://github.com/ansible/ansible/issues/17151

## License

BSD 2-clause
