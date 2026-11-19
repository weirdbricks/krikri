# atom-editor

This role installs and configures [Atom text editor](https://atom.io).

## Role Variables


|            Name              |  Default  | Required | Type | Description
|------------------------------|-----------|----------|------|------------------------------------------------
|    _atom_editor.packages_    |  _None_   |   Yes    | dict | Contains list of Atom packages to be installed


## Example Playbook

    ---
    - hosts: localhost
      roles:
        - atom-editor
      vars:
        atom_editor:
          packages:
            - package_name: atom-beautify
            - package_name: git-plus

## License

BSD

## Author Information

- Mailo Světel — http://mailo.svetel.cz
