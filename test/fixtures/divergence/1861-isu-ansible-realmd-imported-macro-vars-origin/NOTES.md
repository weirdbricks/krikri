# 1861 - ISU-Ansible.realmd: the imported macro's fact read lost its block

- Issue: https://github.com/weirdbricks/krikri/issues/1861
- Role: `ISU-Ansible.realmd` (rocky), round `logs___1795714389`
- Evidence: `logs___1795714389/ISU-Ansible_realmd/compare_cold.diff`

## What diverged

The role's `REALMD | Configure service` template task rendered
`templates/realmd_conf.j2`, which imports `body_option` from
`templates/macros/macros.j2`. That macro reads `realmd_defaults[key]`, and
`realmd_defaults` comes from `vars/RedHat.yml`, whose `os_name` value is
`{{ ansible_distribution }}`. Real printed the INJECT_FACTS_AS_VARS block once,
Origin'd at the vars-file value token; krikri printed no block at all:

```
+missing
 Origin: <WORK>/roles/ISU-Ansible.realmd/vars/RedHat.yml:22:12
```

The template's deprecation probe walks the files a render loaded, but it armed
the frame-entry gate from each file's OWN names. A macro body counts as entered
only when its name is read somewhere in the render, and a `{% from ... import %}`
puts the call in the outer file and the body in the imported one, so from
`macros.j2`'s point of view `body_option` was never called and its
`realmd_defaults[key]` read was skipped. The gate's name set now spans every
file the render loaded, which is the same over-approximation the outer-file
arming already documents.

## Case

`playbook.yml` runs the role with only its template task left (the package,
assert and service tasks need a real host), loading `vars/RedHat.yml` with
`vars_files` since the role's own `include_vars` `with_first_found` list only
matches its RedHat files. `dest` points into the run's own directory and
`owner`/`group` are dropped, or a non-root localhost cannot write it. The
templates, `vars/RedHat.yml` and `defaults/main.yml` are the role's files
verbatim. `expected.out` is `bin/krikri-capture-case`'s capture from
ansible-core 2.21.6.
