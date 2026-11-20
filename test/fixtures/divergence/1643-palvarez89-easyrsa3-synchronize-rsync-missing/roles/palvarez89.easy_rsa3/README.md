easy_rsa3
========

Installs and configures easy-rsa3

Requirements
------------

This role requires Ansible 1.9 or higher.

Role Variables
--------------

| Name                  | Default                | Description                                  |
|:----------------------|:-----------------------|:---------------------------------------------|
| easy_rsa_ca_expire    | 3650                   | Number of days that CA is valid for          |
| easy_rsa_clients      | []                     | List of client certificates/keys to generate |
| easy_rsa_key_city     | "SanFrancisco"         | City                                         |
| easy_rsa_key_country  | "US"                   | Country                                      |
| easy_rsa_key_email    | "me@myhost.mydomain"   | Email address                                |
| easy_rsa_key_expire   | 3650                   | Number of days that key is valid for         |
| easy_rsa_key_name     | "EasyRSA"              | Name of server key                           |
| easy_rsa_key_org      | "Fort-Funston"         | Organization                                 |
| easy_rsa_key_ou       | "MyOrganizationalUnit" | Organizational Unit                          |
| easy_rsa_key_province | "CA"                   | Province                                     |
| easy_rsa_key_size     | 2048                   | Diffie-Hellman key size                      |

Dependencies
------------

None

Example Playbook
----------------

Install easy-rsa3
```yaml
- hosts: all
  roles:
    - palvarez89.easy_rsa3
```

Install easy-rsa3 and generate a client cert/key
```yaml
- hosts: all
  vars:
    easy_rsa_clients:
      - client1
  roles:
    - palvarez89.easy_rsa3
```

Author Information
------------------

Pedro Alvarez
