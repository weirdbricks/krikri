Issue: https://github.com/weirdbricks/krikri/issues/1681

Issue #1681's repro: a task delegated to an unreachable ssh host. The
booking already matched at HEAD (UNREACHABLE on the origin, recap
`unreachable=1 failed=0`, exit 4); what still diverged was the msg. Real
ansible-core names the address it dialled -

    Data could not be sent to remote host "127.0.0.1"

- while krikri's report recomposed it off the ORIGIN host, printing the
origin's inventory name `good` instead (the same root cause #1688 fixed on
the looped path, still present on the non-looped `report_unreachable`
path).

The case is the issue's playbook verbatim. `always-fail` stands in for the
dead endpoint (stderr detail + exit 255), so no real host or port is
involved. The delegate pins `ansible_python_interpreter` because
interpreter discovery is its own ssh exec and its failure renders a
different block shape than the module exec's (the same note #1688's case
carries); `env.txt` pins `ANSIBLE_PIPELINING=True`, which is what selects
the "Data could not be sent" lead that embeds the connection host at all.
`ansible_connection=ssh` on the delegate keeps the corpus harness's
`-c local` from routing the delegated task through the controller.

Fix: `report_unreachable` takes the delegate host and composes the msg
(connection host + pipelining layer) off it, not off the origin. The
non-looped, until-retries and looped-report call sites pass the resolved
delegate host; the booked stats stay on the origin host.
