Ansible role: Laravel tasks.
=========

Configures cron tasks.

Requirements
------------

None.

Role Variables
--------------

    laravel_cron: {}

Dependencies
------------

- shomatan.cron

Example Playbook
----------------

    - hosts: servers
      roles:
        - role: shomatan.laravel
          laravel_cron:
            my_app:
              php_bin_path: /usr/bin/php # default
              user: nginx
              path: /var/www/my_app

License
-------

MIT

Author Information
------------------
