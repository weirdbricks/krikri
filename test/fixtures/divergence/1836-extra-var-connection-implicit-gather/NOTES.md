https://github.com/weirdbricks/krikri/issues/1836

Repro from the issue (no role involved): a play with `gather_facts: true`
against an inventory host that says `ansible_connection=ssh` (on a
connection-refusing port, so any ssh attempt fails fast), with
`-e ansible_connection=local` on the command line (flags.txt). Extra vars are
ansible's highest-precedence var layer, so real ansible-core 2.21.5 runs BOTH
the implicit `Gathering Facts` task and the `ping` task locally: `ok=2`.

krikri honored the extra var for regular tasks but not for the implicit
gather - the gather kept the inventory's connection and UNREACHABLEd trying
to ssh to the refused port (`ok=0 unreachable=1`). The inventory's
`ansible_connection=ssh` var is what keeps the harness's own `-c local`
keyword from masking the bug: an inventory var outranks the keyword in both
engines, and the extra var must outrank the inventory var.

The same shape blocks overriding an unsupported inventory connection plugin
(e.g. an SSM plugin) with `-e ansible_connection=local` for any play that
gathers facts.
