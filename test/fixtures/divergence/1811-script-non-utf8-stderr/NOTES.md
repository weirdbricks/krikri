# #1811 - script: a non-UTF-8 byte in the captured stderr

- Issue: https://github.com/weirdbricks/krikri/issues/1811
- Playbook: `000028-multi-script-happy` (krikri-playbook-generator,
  seed 1795612723), play `multi-task #28.0`.
- Class: `kpg:script` happy path, stdout/stderr text.

## What diverged

The loop ran the round's `/opt/kpg-fixtures` files as scripts. The
`binary.bin` one is not text, so `/bin/sh` reported the file's first line
as an unknown command and captured stderr held a raw `0xff` byte:
`\x01kpgbinary<0xff>: not found`. Real ansible decodes a command's output
with `surrogateescape`, so the result carried a lone surrogate for that
byte, and its stdout/stderr TextIOWrappers (reconfigured with
`_replacing_warning_handler`) wrote it as `?` and printed

```
[WARNING]: Non UTF-8 encoded data replaced with "?" while displaying text to stdout/stderr.
```

on stderr. krikri printed U+FFFD there (and no warning), because the byte
was destroyed before display: the plugin's own JSON round trip of the
`stderr`/`stderr_lines` values parses the escaped string through a
`Char::Reader`, which turns each invalid byte into U+FFFD, and
`AnsibleSplitlines.split` did the same with `each_char`.

## What this case pins

Play #28.0 verbatim, adapted to run against localhost: the loop keeps
only the `binary.bin` entry that diverges (the other seven are valid UTF-8
scripts whose "not found" stderr names the random `ansible-tmp` directory,
which no recording can reproduce), pointed at this case's own script, whose
bytes are the fixture's (`\x01`, `kpgbinary`, `\xff`). Play #28.1 is
dropped - the handler's `/bin/false` failure ends the run at play #28.0, so
real never reaches it.

The script writes the fixture's bytes to stderr itself instead of letting
the shell name the staged copy: the shell's `<tmp path>: 1:` prefix carries
the per-run `ansible-tmp` name, while the divergence is only the byte in
the text. It exits 127, so the result is the same `non-zero return code`
failure real reported.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
