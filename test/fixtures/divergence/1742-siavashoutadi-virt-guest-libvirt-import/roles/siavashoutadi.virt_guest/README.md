Role Name
=========

An Ansible role to create virtual machines on KVM.

Requirements
------------

Libvirt should be installed.

Role Variables
--------------

```ansible

# Guest name
virt_guest_name: "vm1"

# CPU cores
virt_guest_vcpus: 1

# Memory unit. Valid values are GB or MB
virt_guest_memory_unit: "GB"

# Memory
virt_guest_memory: 2

# Disks to add
# The format is:
# - path: /var/lib/libvirt/images/
#   size: SIZE in MB
virt_guest_disks: []

# Owner and group of the disk files
virt_guest_disks_owner: qemu
virt_guest_disks_group: qemu

# Networks to add
# The format is:
# - NET_NAME
virt_guest_networks: []

# Path to iso file to attach to cdrom
virt_guest_iso: ""


```

Dependencies
------------

N/A

Example Playbook
----------------

```ansible
- name: Create virt guest
  hosts: hypervisor
  become: yes
  vars:
    virt_guest_name: vm1
    virt_guest_disks:
      - path: /var/kvm-images
        size: 20480
    virt_guest_networks:
      - virbr1
    virt_guest_iso: /tmp/iso/centos.iso
  roles:
    - role: siavashoutadi.virt_guest

```

License
-------

Apache
