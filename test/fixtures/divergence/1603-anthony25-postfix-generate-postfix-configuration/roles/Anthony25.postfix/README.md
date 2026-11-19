Ansible Role: Postfix
=====================

This role installs and manages [Postfix](http://postfix.org/), an SMTP server.

This role is designed to manage Postfix on different hosts in a cluster, with
different "capabilities". At the moment the role can configure Postfix to act
as:

* a null client: Postfix sends all mail to another system specified
  either via DNS MX records or an Ansible variable, no local mail is enabled
  (this is the default configuration);
* a local SMTP server: local mail is delivered to local user accounts;
* a network SMTP server: network access is enabled separately from other
  capabilities, to avoid exposing misconfigured SMTP server by mistake and
  becoming an open relay;
* an incoming MX gateway: Postfix will listen on the port 25 (default SMTP
  port) and process connections using `postscreen` daemon with automatic
  greylisting and optional RBL checking;
* an outgoing SMTP client: Postfix will relay outgoing mail messages to
  specified remote MX hosts


### Documentation

This is a fork of `debops.postfix`. This is the same role, without all the
dependencies, and target ArchLinux.

More information about `debops.postfix` can be found in the
[official debops.postfix documentation](http://docs.debops.org/en/latest/ansible/roles/ansible-postfix/docs/).


### Authors and license

`postfix` role was written by:
- Anthony Ruhier | [e-mail](mailto:anthony.ruhier@gmail.com)
- TRINAPS, Anthony Ruhier | [e-mail](mailto:anthony.ruhier@trinaps.com)
- Maciej Delmanowski | [e-mail](mailto:drybjed@gmail.com) | [Twitter](https://twitter.com/drybjed) | [GitHub](https://github.com/drybjed)

License: [GPLv3](https://tldrlegal.com/license/gnu-general-public-license-v3-%28gpl-3%29)
