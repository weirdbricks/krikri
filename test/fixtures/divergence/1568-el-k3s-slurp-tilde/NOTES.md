# #1568 - jesperberth.el_k3s: krikri fails `File not found: ~/stable.txt`

- Issue: https://github.com/weirdbricks/krikri/issues/1568
- Role: `jesperberth.el_k3s` (rocky host, round `logs___1795043292`)
- Class: behavioural bug (ansible exit 0, krikri exit 2)

**What diverged.** The role's get_url writes `dest: "~/stable.txt"` and the
next task slurps `src: "~/stable.txt"`. Both are `type: path` argspec options,
so real expands `~` before the module body looks at the path; krikri handed the
literal `~/stable.txt` to the plugin and failed the task, aborting the play
(exit 2 against real's 0).

**Fixture.** The role's get_url -> slurp -> set_fact chain verbatim, with two
adaptations so it runs offline against localhost: the get_url URL is a
`file://` copy of the `stable.txt` shipped beside this case instead of
`https://storage.googleapis.com/...`, and the package/install tasks above and
below the chain (which mutate the host) are dropped. A final corpus-only
`debug:` surfaces the slurped value in the transcript.

`inventory.ini`'s `[local]` host pins `ansible_python_interpreter`, and
`HOME` is the case's own scratch `home/` directory in both the capture and the
replay, so `~` never resolves into the developer's real home.
