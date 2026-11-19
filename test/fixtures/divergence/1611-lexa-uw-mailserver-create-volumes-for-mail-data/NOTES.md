# lexa-uw.mailserver: Create volumes for mail data

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1611
- role: lexa-uw.mailserver
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795085158/lexa-uw_mailserver
- phase: cold (block 4)
- task: Create volumes for mail data
- divergence: task results differ: ansible=[failed,failed,failed] krikri=[skipping,skipping,skipping,skipping]
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Module failed: Error connecting: Error while fetching server API version: ('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))
  krikri:  skipping: [localhost] => (item=mailserver_maildata) 
  ```

- round versions: krikri 0.9.2959, ansible-playbook [core 2.21.6]

## Corpus fit

The divergence is check-mode only, so `flags.txt` carries `--check`. `playbook.yml`
runs `roles/lexa-uw.mailserver/` itself (the role tree the round ran) rather than
inlining the lifted task, because the Origin ansible prints points into that
role's own `tasks/main.yml:3`.

`ansible.cfg` sets `deprecation_warnings = False`: executing real's
community.docker module makes ansible-core import its own deprecated
`ansible.module_utils.common._collections_compat`, whose warning krikri's native
`docker_volume` (no python module payload) can never emit.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`, from this directory:

    bin/krikri-capture-case test/fixtures/divergence/1611-lexa-uw-mailserver-create-volumes-for-mail-data

The play's `environment:` pins `DOCKER_HOST` to a unix socket that does not
exist, so both engines deterministically reach the daemon-unreachable path and
the recorded error is `FileNotFoundError(2, ...)`, the wording the round's own
host captured. (A bare `/var/run/docker.sock` is ambient: on the capture box it
points into `/run/podman`, which the test user cannot traverse, and gave
`PermissionError(13, ...)` instead - same SDK failure, different exception
wording.)

`inventory.ini` pins the interpreter on the `[local]` host, which is the only
spelling both engines read alike.

## Divergent block

### ansible

```
TASK [Create volumes for mail data] ********************************************
[ERROR]: Task failed: Module failed: Error connecting: Error while fetching server API version: ('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))
Origin: <WORK>/roles/lexa-uw.mailserver/tasks/main.yml:3:3

1 ---
2 # tasks file for mailserver
3 - name: Create volumes for mail data
    ^ column 3

failed: [localhost] (item=mailserver_maildata) => {"ansible_loop_var": "item", "changed": false, "item": "mailserver_maildata", "msg": "Error connecting: Error while fetching server API version: ('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))"}
failed: [localhost] (item=mailserver_mailstate) => {"ansible_loop_var": "item", "changed": false, "item": "mailserver_mailstate", "msg": "Error connecting: Error while fetching server API version: ('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))"}
failed: [localhost] (item=mailserver_config) => {"ansible_loop_var": "item", "changed": false, "item": "mailserver_config", "msg": "Error connecting: Error while fetching server API version: ('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))"}

```

### krikri

```
TASK [Create volumes for mail data] ********************************************
skipping: [localhost] => (item=mailserver_maildata) 
skipping: [localhost] => (item=mailserver_mailstate) 
skipping: [localhost] => (item=mailserver_config) 
skipping: [localhost]

```
