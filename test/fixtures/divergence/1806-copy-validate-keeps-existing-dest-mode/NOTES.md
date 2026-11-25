# #1806 - copy: with validate: drops an existing destination's mode

- Issue: https://github.com/weirdbricks/krikri/issues/1806
- Playbook: krikri-playbook-generator `000012-multi-copy-chaos.yml`
  ("Copy #12.0"), kpg class `copy: state, chaos: Jinja on t0:src`
- Class: host state - identical stdout, different destination mode

**What diverged.** The task copies `inner.txt` (0644, 6 bytes) over the
generator's pre-seeded `/tmp/kpg-work/dest-0440.txt` (0440, 28 bytes) with
`validate: /bin/true %s`. Both engines printed the same `changed` result,
but real ansible left the destination at 0440 while krikri left it at
0644 (`0666 & ~umask`):

```
-file  changed  f 0 0 440 28 .../dest-0440.txt  f 0 0 440 6 .../dest-0440.txt
+file  changed  f 0 0 440 28 .../dest-0440.txt  f 0 0 644 6 .../dest-0440.txt
```

**Why krikri had it wrong.** With no `mode:`, copy.py hands its staged
source to `atomic_move`, which - for a non-`remote_src` copy - first
`shutil.copystat()`s an existing destination over that staged file, so the
overwrite keeps the mode of the file it replaces. krikri's non-`validate:`
path already preserved it (`staging_temp_mode`), but `validate:` stages
under `Dir.tempdir` with `preserve_dest_mode: false` and moves it in as a
fresh inode, so the destination fell back to the umask default. Confirmed
by the same playbook without `validate:`: both engines then kept 0440.

**Fix.** `plugins/copy.cr`'s `write_with_optional_validate` applies the
existing destination's owner/group (best effort) and mode to the staged
temp after a successful `validate:` and before the move - the order real
uses, so a validator still reads the task's mode or the umask default,
never the destination's.

**Fixture.** The failing task is copied verbatim except: `hosts:
kpg_targets` becomes localhost, the `kpg-bogus-connection` plus the
kpg-only `vars:` are dropped, and `dest:`/`src:` point into the scratch
directory; the first task recreates the generator's pre-seeded 0440
destination. The divergence is host state, not output, so the trailing
`command`/`debug` pair prints the destination's final mode into the
transcript - that is what pins 440 against krikri's 644.
`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
