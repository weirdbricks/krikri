python-coreos
=========

This role installs python and some packages for using Ansible

# Configure your project

```
[coreos]
123.432.12.123

[coreos:vars]
ansible_ssh_user=core
ansible_python_interpreter=/opt/bin/python
```

This will configure ansible to use the python interpreter at `/home/core/bin/python` which will be created by the coreos-bootstrap role.

## Bootstrap Playbook

Now you can simply add the following to your playbook file and include it in your `site.yml` so that it runs on all hosts in the coreos group.

```yaml
- hosts: coreos
  gather_facts: False
  roles:
    - hesidoryn.python-coreos
```

Make sure that `gather_facts` is set to false, otherwise ansible will try to first gather system facts using python which is not yet installed!

## Example Playbook

After bootstrap, you can use ansible as usual to manage system services, install python modules (via pip), and run containers. Below is a basic example that starts the `etcd2` service and then uses the ansible `docker` module to pull and start a basic nginx container.

```yaml
- name: Nginx Example
  hosts: coreos
  sudo: true
  tasks:
    - name: Start etcd2
      service: name=etcd2.service state=started

    - name: pull container
      raw: docker pull nginx:latest

    - name: launch nginx container
      docker:
        image="nginx:latest"
        name="example-nginx"
        ports="8080:80"
        state=running
```
