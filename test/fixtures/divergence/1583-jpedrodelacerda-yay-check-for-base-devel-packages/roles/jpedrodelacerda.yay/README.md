# Yay
Simple installation of [`yay`](https://github.com/Jguer/yay) on Arch Linux using Ansible.

## Requirements
None.

## Role Variables
`colored_output:` Whether the pacman config should display colored output. Can be `true` or `false`.

## Dependencies:
None.

## Example Playbook
```
- hosts: server
  roles:
    - { role: jpedrodelacerda.yay }
```

## License
MIT/BSD
