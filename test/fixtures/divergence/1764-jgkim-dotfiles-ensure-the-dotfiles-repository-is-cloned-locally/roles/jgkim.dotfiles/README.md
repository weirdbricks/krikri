Ansible Role: dotfiles
======================

[![Build Status](http://img.shields.io/travis/jgkim/ansible-role-dotfiles.svg?style=flat)](https://travis-ci.org/jgkim/ansible-role-dotfiles)

This role installs a set of dotfiles from a given git repository. By default, it will install my dotfiles, but you can use any set of dotfiles you'd like, as long as they follow a conventional format.


Requirements
------------

None.


Role Variables
--------------

Available variables are listed below, along with default values (see `defaults/main.yml`):

```
dotfiles_remote: "https://github.com/jgkim/dotfiles.git"
```

The git remote repository to use for retrieving dotfiles. Dotfiles should generally be laid out within the root directory of the repository.

```
dotfiles_local: "~/Workspace/dotfiles"
```

The local repository path where the dotfiles_remote will be cloned.

```
dotfiles_home: "~"
```

The home directory where dotfiles will be linked. Generally, the default should work, but in some circumstances, or when running the role as sudo on behalf of another user, you may want to specify the full path.

```
dotfiles_ignore:
  - .DS_Store
  - .git
  - .ansible
```

Which files from the dotfiles repository should be ignored when linking to the dotfiles_home.


Dependencies
------------

None.


Example Playbook
----------------

```
- hosts: localhost
  connection: local
  roles:
     - { role: jgkim.dotfiles }
```


License
-------

MIT


Author Information
------------------

This role has been forked from [Jeff Geerling](http://jeffgeerling.com/)'s [original work](https://github.com/geerlingguy/ansible-role-dotfiles), and was rewritten by [James G. Kim](http://jayg.org/).
