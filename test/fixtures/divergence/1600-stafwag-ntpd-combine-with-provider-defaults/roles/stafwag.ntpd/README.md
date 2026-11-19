# Ansible Role: ntpd

An ansible role to configure ntpd/chrony/systemd-timesyncd

# Installation

## Ansible galaxy

The role is available on [Ansible Galaxy](https://galaxy.ansible.com/ui/standalone/roles/stafwag/ntpd/).

To install the role from Ansible Galaxy execute the command below. 

```bash
ansible-galaxy install stafwag.ntpd
```
## Source Code

If you want to use the source code directly.

Clone the role source code.

```bash
$ git clone https://github.com/stafwag/ansible-role-ntpd
```

and put into the [role search path](https://docs.ansible.com/ansible/2.4/playbooks_reuse_roles.html#role-search-path)

## Requirements

### Supported platforms

* Archlinux
* Debian
* FreeBSD
* NetBSD
* OpenBSD
* RedHat
* Suse

## Role Variables and templates

### defaults

The ```ntpd_defaults``` hash is used to define the default values.

* **ntpd_defaults**:
    * **servers**: An array with the default ntp servers. Default: ```- pool.ntp.org```.

### Input variables

The ```ntpd``` is used to define the input values to configure the role.

* **ntpd**: "namespace"

    * **provider** ntpd|chrony|systemd-timesyncd, the ntp provider. 
      * ***ntpd*** is used by default on Debian GNU/Linux 10 & 11 for historical reasons and all other operating systems (BSD, Solaris, etc)
      * ***chrony*** is the default on GNU/Linux besides Debian GNU/Linux and Archlinux.
      * ***systemd-timesyncd*** is used as the default on Debian GNU/Linux - as this is the default ntp client on Debian GNU/Linux - and Archlinux.

    * **packages_to_remove**: packages to remove. Packages that will be removed from the system during the ntp configuration.
        * On Debian GNU/Linux ```chrony``` and ```ntp``` are removed when the ```systemd-timesyncd``` provider is used. 
        * On Archlinux
            * ```chrony``` is removed when the ```ntpd``` provider is used. 
            * ```ntp``` is removed when the ```chrony``` provider is used. 

    * **packages**: packages that're installed during the setup of ntp. By default, the required packages for the ntp provider are installed.
    * **template**: the configuration template. By default, the template for the provider is used. See the template section for more details.
    * **conf_file**: The config file that is created with the defined ***template***. By default the configuration file based on the provider is used.
    * **driftfile**: the ntp driftfile. 
    * **servers**: A list with the ntp servers, by default the ntp ```servers``` defined in the ```ntpd_defaults``` hash are used. 
    * **service**: The ntp service that is started during the ntp configuration. By default, the service that is required by the ntp provider is used.
    * **services_to_disable**: A list of services that are stopped and disabled during the ntp configuration. By  default is used when the ```systemd-timesyncd``` is used to disable the ```ntp```, ```ntpd```, ```chrony`` and ```chronyd```` services if they exist on the target system.

### Return variables

The role returns the ```_ntpd``` hash with the defined values. The ```_ntpd``` is a copy of the ```ntpd``` input hash with the added values that are defined by the role for the target operation system.

The return hash ```_ntpd```` is used by the default templates.

### Templates

The role comes with a template for each provider to set up a basic ntp client. If you need something else you can define your own template.
    
## Dependencies

None

## Example Playbooks

```
- name: Configure ntp on the systems
  hosts: all
  become: true
  roles:
    - stafwag.ntpdate
    - stafwag.ntpd
  vars:
    ntpd:
      servers:
        - 0.be.pool.ntp.org
        - 1.be.pool.ntp.org
        - 2.be.pool.ntp.org
        - 3.be.pool.ntp.org
```

## License

MIT/BSD

## Author Information

Created by Staf Wagemakers, email: staf@wagemakers.be, website: https://www.wagemakers.be, my company https://mask27.dev
